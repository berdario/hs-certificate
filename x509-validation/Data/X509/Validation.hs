-- |
-- Module      : Data.X509.Validation
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- X.509 Certificate checks and validations routines
--
-- Follows RFC5280 / RFC6818
--
module Data.X509.Validation
    ( FQHN
    , FailedReason(..)
    , SignatureFailure(..)
    , Parameters(..)
    , Checks(..)
    , Hooks(..)
    , defaultChecks
    , defaultHooks
    , validate
    , validateWith
    , getFingerprint
    ) where

import Control.Applicative
import Data.ASN1.Types
import Data.X509
import Data.X509.CertificateStore
import Data.X509.Validation.Signature
import Data.X509.Validation.Fingerprint
import Data.Time.Clock
import Data.Maybe
import Data.List

-- | a Fully Qualified Host Name, e.g. www.example.com
type FQHN = String

-- | Possible reason of certificate and chain failure
data FailedReason =
      UnknownCriticalExtension -- ^ certificate contains an unknown critical extension
    | Expired                  -- ^ validity ends before checking time
    | InFuture                 -- ^ validity starts after checking time
    | SelfSigned               -- ^ certificate is self signed
    | UnknownCA                -- ^ unknown Certificate Authority (CA)
    | NotAllowedToSign         -- ^ certificate is not allowed to sign
    | NotAnAuthority           -- ^ not a CA
    | AuthorityTooDeep         -- ^ Violation of the optional Basic constraint's path length
    | NoCommonName             -- ^ Certificate doesn't have any common name (CN)
    | InvalidName String       -- ^ Invalid name in certificate
    | NameMismatch String      -- ^ connection name and certificate do not match
    | InvalidWildcard          -- ^ invalid wildcard in certificate
    | LeafKeyUsageNotAllowed   -- ^ the requested key usage is not compatible with the leaf certificate's key usage
    | LeafKeyPurposeNotAllowed -- ^ the requested key purpose is not compatible with the leaf certificate's extended key usage
    | LeafNotV3                -- ^ Only authorized an X509.V3 certificate as leaf certificate.
    | EmptyChain               -- ^ empty chain of certificate
    | InvalidSignature SignatureFailure -- ^ signature failed
    deriving (Show,Eq)

-- | A set of checks to activate or parametrize to perform on certificates.
--
-- It's recommended to use 'defaultChecks' to create the structure,
-- to better cope with future changes or expansion of the structure.
data Checks = Checks
    {
    -- | check time validity of every certificate in the chain.
    -- the make sure that current time is between each validity bounds
    -- in the certificate
      checkTimeValidity   :: Bool
    -- | Check that no certificate is included that shouldn't be included.
    -- unfortunately despite the specification violation, a lots of
    -- real world server serves useless and usually old certificates
    -- that are not relevant to the certificate sent, in their chain.
    , checkStrictOrdering :: Bool
    -- | Check that signing certificate got the CA basic constraint.
    -- this is absolutely not recommended to turn it off.
    , checkCAConstraints  :: Bool
    -- | Check the whole certificate chain without stopping at the first failure.
    -- Allow gathering a exhaustive list of failure reasons. if this is
    -- turn off, it's absolutely not safe to ignore a failed reason even it doesn't look serious
    -- (e.g. Expired) as other more serious checks would not have been performed.
    , checkExhaustive     :: Bool
    -- | Check that the leaf certificate is version 3. If disable, version 2 certificate
    -- is authorized in leaf position and key usage cannot be checked.
    , checkLeafV3         :: Bool
    -- | Check that the leaf certificate is authorized to be used for certain usage.
    -- If set to empty list no check are performed, otherwise all the flags is the list
    -- need to exists in the key usage extension. If the extension is not present,
    -- the check will pass and behave as if the certificate key is not restricted to
    -- any specific usage.
    , checkLeafKeyUsage   :: [ExtKeyUsageFlag]
    -- | Check that the leaf certificate is authorized to be used for certain purpose.
    -- If set to empty list no check are performed, otherwise all the flags is the list
    -- need to exists in the extended key usage extension if present. If the extension is not
    -- present, then the check will pass and behave as if the certificate is not restricted
    -- to any specific purpose.
    , checkLeafKeyPurpose :: [ExtKeyUsagePurpose]
    -- | Check the top certificate names matching the fully qualified hostname (FQHN).
    -- it's not recommended to turn this check off, if no other name checks are performed.
    , checkFQHN           :: Bool
    } deriving (Show,Eq)

-- | A set of hooks to manipulate the way the verification works.
--
-- BEWARE, it's easy to change behavior leading to compromised security.
data Hooks = Hooks
    {
    -- | check the the issuer 'DistinguishedName' match the subject 'DistinguishedName'
    -- of a certificate.
      hookMatchSubjectIssuer :: DistinguishedName -> Certificate -> Bool
    -- | validate that the parametrized time valide with the certificate in argument
    , hookValidateTime       :: UTCTime -> Certificate -> [FailedReason]
    -- | validate the certificate leaf name with the DNS named used to connect
    , hookValidateName       :: FQHN -> Certificate -> [FailedReason]
    }

-- | Validation parameters. List all the conditions where/when we want the certificate checks
-- to happen.
data Parameters = Parameters
    { parameterTime :: UTCTime -- ^ the time when we want the certificate check to happen.
                               -- usually should be the time as of now.
    , parameterFQHN :: FQHN    -- ^ fqhn to match
    } deriving (Show,Eq)

-- | Default checks to perform
--
-- The default checks are:
-- * Each certificate time is valid
-- * CA constraints is enforced for signing certificate
-- * Leaf certificate is X.509 v3
-- * Check that the FQHN match
defaultChecks :: Checks
defaultChecks = Checks
    { checkTimeValidity   = True
    , checkStrictOrdering = False
    , checkCAConstraints  = True
    , checkExhaustive     = False
    , checkLeafV3         = True
    , checkLeafKeyUsage   = []
    , checkLeafKeyPurpose = []
    , checkFQHN           = True
    }

-- | Default hooks in the validation process
defaultHooks :: Hooks
defaultHooks = Hooks
    { hookMatchSubjectIssuer = matchSI
    , hookValidateTime       = validateTime
    , hookValidateName       = validateCertificateName
    }

-- | validate a certificate chain.
validate :: Hooks -> Checks -> CertificateStore -> FQHN -> CertificateChain -> IO [FailedReason]
validate _     _      _     _    (CertificateChain [])       = return [EmptyChain]
validate hooks checks store fqhn cc@(CertificateChain (_:_)) = do
    params <- Parameters <$> getCurrentTime <*> pure fqhn
    validateWith params hooks checks store cc

-- | Validate a certificate chain with explicit parameters
validateWith :: Parameters -> Hooks -> Checks -> CertificateStore -> CertificateChain -> IO [FailedReason]
validateWith _      _     _      _     (CertificateChain [])           = return [EmptyChain]
validateWith params hooks checks store (CertificateChain (top:rchain)) =
    doLeafChecks |> doCheckChain 0 top rchain
  where isExhaustive = checkExhaustive checks
        a |> b = exhaustive isExhaustive a b

        doLeafChecks = doNameCheck top |> doV3Check topCert |> doKeyUsageCheck topCert
            where topCert = getCertificate top

        doCheckChain :: Int -> SignedCertificate -> [SignedCertificate] -> IO [FailedReason]
        doCheckChain level current chain = do
            r <- doCheckCertificate (getCertificate current)
            -- check if we have a trusted certificate in the store belonging to this issuer.
            return r |> (case findCertificate (certIssuerDN cert) store of
                Just trustedSignedCert      -> return $ checkSignature current trustedSignedCert
                Nothing | isSelfSigned cert -> return [SelfSigned] |> return (checkSignature current current)
                        | null chain        -> return [UnknownCA]
                        | otherwise         ->
                            case findIssuer (certIssuerDN cert) chain of
                                Nothing                  -> return [UnknownCA]
                                Just (issuer, remaining) ->
                                    return (checkCA level $ getCertificate issuer)
                                    |> return (checkSignature current issuer)
                                    |> doCheckChain (level+1) issuer remaining)
          where cert = getCertificate current
        -- in a strict ordering check the next certificate has to be the issuer.
        -- otherwise we dynamically reorder the chain to have the necessary certificate
        findIssuer issuerDN chain
            | checkStrictOrdering checks =
                case chain of
                    []     -> error "not possible"
                    (c:cs) | matchSubjectIdentifier issuerDN (getCertificate c) -> Just (c, cs)
                           | otherwise                                          -> Nothing
            | otherwise =
                (\x -> (x, filter (/= x) chain)) `fmap` find (matchSubjectIdentifier issuerDN . getCertificate) chain
        matchSubjectIdentifier = hookMatchSubjectIssuer hooks

        -- we check here that the certificate is allowed to be a certificate
        -- authority, by checking the BasicConstraint extension. We also check,
        -- if present the key usage extension for ability to cert sign. If this
        -- extension is not present, then according to RFC 5280, it's safe to
        -- assume that only cert sign (and crl sign) are allowed by this certificate.
        checkCA :: Int -> Certificate -> [FailedReason]
        checkCA level cert
            | not (checkCAConstraints checks)          = []
            | and [allowedSign,allowedCA,allowedDepth] = []
            | otherwise = (if allowedSign then [] else [NotAllowedToSign])
                       ++ (if allowedCA   then [] else [NotAnAuthority])
                       ++ (if allowedDepth then [] else [AuthorityTooDeep])
          where extensions  = certExtensions cert
                allowedSign = case extensionGet extensions of
                                Just (ExtKeyUsage flags) -> KeyUsage_keyCertSign `elem` flags
                                Nothing                  -> True
                (allowedCA,pathLen) = case extensionGet extensions of
                                Just (ExtBasicConstraints True pl) -> (True, pl)
                                _                                  -> (False, Nothing)
                allowedDepth = case pathLen of
                                    Nothing                            -> True
                                    Just pl | fromIntegral pl >= level -> True
                                            | otherwise                -> False

        doNameCheck cert
            | not (checkFQHN checks) = return []
            | otherwise              = return $ (hookValidateName hooks) fqhn (getCertificate cert)
          where fqhn = parameterFQHN params

        doV3Check cert
            | checkLeafV3 checks = case certVersion cert of
                                        2 {- confusingly it means X509.V3 -} -> return []
                                        _ -> return [LeafNotV3]
            | otherwise = return []

        doKeyUsageCheck cert = return $
               compareListIfExistAndNotNull mflags (checkLeafKeyUsage checks) LeafKeyUsageNotAllowed
            ++ compareListIfExistAndNotNull mpurposes (checkLeafKeyPurpose checks) LeafKeyPurposeNotAllowed
          where mflags = case extensionGet $ certExtensions cert of
                            Just (ExtKeyUsage keyflags) -> Just keyflags
                            Nothing                     -> Nothing
                mpurposes = case extensionGet $ certExtensions cert of
                            Just (ExtExtendedKeyUsage keyPurposes) -> Just keyPurposes
                            Nothing                                -> Nothing
                -- compare a list of things to an expected list. the expected list
                -- need to be a subset of the list (if not Nothing), and is not will
                -- return [err]
                compareListIfExistAndNotNull Nothing     _        _   = []
                compareListIfExistAndNotNull (Just list) expected err
                    | null expected                       = []
                    | intersect expected list == expected = []
                    | otherwise                           = [err]

        doCheckCertificate cert =
            exhaustiveList (checkExhaustive checks)
                [ (checkTimeValidity checks, return ((hookValidateTime hooks) (parameterTime params) cert))
                ]
        isSelfSigned :: Certificate -> Bool
        isSelfSigned cert = certSubjectDN cert == certIssuerDN cert

        -- check signature of 'signedCert' against the 'signingCert'
        checkSignature signedCert signingCert =
            case verifySignedSignature signedCert (certPubKey $ getCertificate signingCert) of
                SignaturePass     -> []
                SignatureFailed r -> [InvalidSignature r]

-- | Validate that the current time is between validity bounds
validateTime :: UTCTime -> Certificate -> [FailedReason]
validateTime currentTime cert
    | currentTime < before = [InFuture]
    | currentTime > after  = [Expired]
    | otherwise            = []
  where (before, after) = certValidity cert

getNames :: Certificate -> (Maybe String, [String])
getNames cert = (commonName >>= asn1CharacterToString, altNames)
  where commonName = getDnElement DnCommonName $ certSubjectDN cert
        altNames   = maybe [] toAltName $ extensionGet $ certExtensions cert
        toAltName (ExtSubjectAltName names) = catMaybes $ map unAltName names
            where unAltName (AltNameDNS s) = Just s
                  unAltName _              = Nothing

-- | Validate that the fqhn is matched by at least one name in the certificate.
-- The name can be either the common name or one of the alternative names if
-- the SubjectAltName extension is present.
validateCertificateName :: FQHN -> Certificate -> [FailedReason]
validateCertificateName fqhn cert =
    case commonName of
        Nothing -> [NoCommonName]
        Just cn -> findMatch [] $ map (matchDomain . splitDot) (cn : altNames)
  where (commonName, altNames) = getNames cert

        findMatch :: [FailedReason] -> [[FailedReason]] -> [FailedReason]
        findMatch _   []      = [NameMismatch fqhn]
        findMatch _   ([]:_)  = []
        findMatch acc (_ :xs) = findMatch acc xs

        matchDomain :: [String] -> [FailedReason]
        matchDomain l
            | length (filter (== "") l) > 0 = [InvalidName (intercalate "." l)]
            | head l == "*"                 = wildcardMatch (reverse $ drop 1 l)
            | l == splitDot fqhn            = [] -- success: we got a match
            | otherwise                     = [NameMismatch fqhn]

        -- only 1 wildcard is valid, and if multiples are present
        -- they won't have a wildcard meaning but will be match as normal star
        -- character to the fqhn and inevitably will fail.
        --
        -- e.g. *.*.server.com will try to litteraly match the '*' subdomain of server.com
        wildcardMatch l
            -- <star>.com or <star> is always invalid
            | length l < 2 = [InvalidWildcard]
            -- some TLD like .uk got small subTLS like (.co.uk), and we don't want to accept *.co.uk
            | length (head l) <= 2 && length (head $ drop 1 l) <= 3 && length l < 3 = [InvalidWildcard]
            | l == take (length l) (reverse $ splitDot fqhn) = [] -- success: we got a match
            | otherwise                                      = [NameMismatch fqhn]

        splitDot :: String -> [String]
        splitDot [] = [""]
        splitDot x  =
            let (y, z) = break (== '.') x in
            y : (if z == "" then [] else splitDot $ drop 1 z)


-- | return true if the 'subject' certificate's issuer match
-- the 'issuer' certificate's subject
matchSI :: DistinguishedName -> Certificate -> Bool
matchSI issuerDN issuer = certSubjectDN issuer == issuerDN

exhaustive :: Monad m => Bool -> m [FailedReason] -> m [FailedReason] -> m [FailedReason]
exhaustive isExhaustive f1 f2 = f1 >>= cont
  where cont l1
            | null l1      = f2
            | isExhaustive = f2 >>= \l2 -> return (l1 ++ l2)
            | otherwise    = return l1

exhaustiveList :: Monad m => Bool -> [(Bool, m [FailedReason])] -> m [FailedReason]
exhaustiveList _            []                    = return []
exhaustiveList isExhaustive ((performCheck,c):cs)
    | performCheck = exhaustive isExhaustive c (exhaustiveList isExhaustive cs)
    | otherwise    = exhaustiveList isExhaustive cs
