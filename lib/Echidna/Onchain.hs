module Echidna.Onchain
  ( etherscanApiKey
  , fetchChainIdFrom
  , fetchWithFallbacks
  , rpcBlockEnv
  , rpcFallbackUrlsEnv
  , rpcUrlEnv
  , safeFetchContractFrom
  , safeFetchSlotFrom
  , saveCoverageReport
  , saveRpcCache
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (catch, SomeException)
import Control.Monad (when, forM_)
import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.ByteString.UTF8 qualified as UTF8
import Data.Char (ord)
import Data.List (elemIndex)
import Data.Map qualified as Map
import Data.Maybe (isJust, fromJust, fromMaybe)
import Data.Sequence (Seq)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Data.Word (Word32, Word64)
import Network.Connection qualified as Connection
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP_TLS
import Network.TLS qualified as TLS
import Network.Wreq.Session qualified as Session
import Numeric (showHex)
import Optics (view)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.X509 (getSystemCertificateStore)
import Text.Read (readMaybe)

import EVM (bytecode)
import EVM.Effects (defaultConfig)
import EVM.Fetch qualified
import EVM.Solidity (SourceCache(..), SolcContract(..), SrcMap, makeSrcMaps)
import EVM.Types hiding (Env)

import Echidna.Onchain.Etherscan qualified as Etherscan
import Echidna.Onchain.Sourcify qualified as Sourcify
import Echidna.Onchain.Types (SourceData(..))
import Echidna.Output.Source (saveCoverages)
import Echidna.SymExec.Symbolic (forceBuf)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..))

saveRpcCache :: Env -> IO ()
saveRpcCache env = do
  case (env.fetchSession.cacheDir, env.cfg.rpcBlock) of
    (Just dir, Just n) -> do
      cache <- readMVar (env.fetchSession.sharedCache)
      EVM.Fetch.saveCache dir (fromIntegral n) cache
    (_, Nothing) -> when (isJust (env.cfg.rpcUrl))
      $ putStrLn "Warning: cannot save RPC cache without a specified block number."
    (Nothing, _) -> pure ()

rpcUrlEnv :: IO (Maybe Text)
rpcUrlEnv = do
  val <- lookupEnv "ECHIDNA_RPC_URL"
  pure (Text.pack <$> val)

rpcFallbackUrlsEnv :: IO [Text]
rpcFallbackUrlsEnv = do
  single <- lookupEnv "ECHIDNA_RPC_FALLBACK_URL"
  many <- lookupEnv "ECHIDNA_RPC_FALLBACK_URLS"
  pure $ concatMap splitRpcUrls [single, many]
  where
    splitRpcUrls Nothing = []
    splitRpcUrls (Just raw) =
      filter (not . Text.null) . fmap Text.strip . Text.splitOn "," $ Text.pack raw

rpcBlockEnv :: IO (Maybe Word64)
rpcBlockEnv = do
  val <- lookupEnv "ECHIDNA_RPC_BLOCK"
  pure (val >>= readMaybe)

etherscanApiKey :: IO (Maybe Text)
etherscanApiKey = do
  val <- lookupEnv "ETHERSCAN_API_KEY"
  pure (Text.pack <$> val)

safeFetchContractFrom :: EVM.Fetch.Session -> EVM.Fetch.BlockNumber -> [Text] -> Addr -> IO (EVM.Fetch.FetchResult Contract)
safeFetchContractFrom session rpcBlock rpcUrls addr =
  fetchWithFallbacks rpcUrls $ \rpcUrl -> do
    res <- EVM.Fetch.fetchContractWithSession defaultConfig session rpcBlock rpcUrl addr
    pure $ case res of
      EVM.Fetch.FetchSuccess c status -> EVM.Fetch.FetchSuccess (EVM.Fetch.makeContractFromRPC c) status
      EVM.Fetch.FetchFailure status -> EVM.Fetch.FetchFailure status
      EVM.Fetch.FetchError e -> EVM.Fetch.FetchError e

safeFetchSlotFrom :: EVM.Fetch.Session -> EVM.Fetch.BlockNumber -> [Text] -> Addr -> W256 -> IO (EVM.Fetch.FetchResult W256)
safeFetchSlotFrom session rpcBlock rpcUrls addr slot =
  fetchWithFallbacks rpcUrls $ \rpcUrl ->
    EVM.Fetch.fetchSlotWithCache defaultConfig session rpcBlock rpcUrl addr slot

rpcFailureCooldowns :: MVar (Map.Map Text UTCTime)
rpcFailureCooldowns = unsafePerformIO (newMVar Map.empty)
{-# NOINLINE rpcFailureCooldowns #-}

fetchWithFallbacks :: [Text] -> (Text -> IO (EVM.Fetch.FetchResult a)) -> IO (EVM.Fetch.FetchResult a)
fetchWithFallbacks [] _ = pure $ EVM.Fetch.FetchError "No RPC URL configured"
fetchWithFallbacks urls action = go 1_000_000
  where
    maxDelay = 30_000_000

    go delay = do
      orderedUrls <- activeRpcUrls urls
      result <- tryUrls orderedUrls [] 0
      case result of
        Right value -> pure value
        Left errors -> do
          hPutStrLn stderr $
            "WARNING: all RPC URLs failed; retrying in " <> show (delay `div` 1_000_000) <>
            "s: " <> Text.unpack (Text.intercalate "; " (reverse errors))
          threadDelay delay
          go (min maxDelay (delay * 2))

    tryUrls [] errors _failedCount = pure $ Left errors
    tryUrls (rpcUrl:rest) errors failedCount = do
      result <- catch
        (action rpcUrl)
        (\(e :: SomeException) -> pure $ EVM.Fetch.FetchError (Text.pack $ show e))
      case result of
        EVM.Fetch.FetchError e -> do
          cooldown <- coolRpcUrl rpcUrl e
          hPutStrLn stderr $
            "WARNING: RPC fetch failed via " <> Text.unpack (rpcEndpointLabel urls rpcUrl) <>
            "; cooling for " <> show (round cooldown :: Integer) <> "s and trying fallback: " <>
            Text.unpack e
          tryUrls rest (("RPC fetch failed via " <> rpcEndpointLabel urls rpcUrl <> ": " <> e) : errors) (failedCount + 1)
        _ -> do
          clearRpcCooldown rpcUrl
          when (failedCount > 0) $
            hPutStrLn stderr $
              "WARNING: RPC request succeeded after " <> show failedCount <>
              " failed upstream(s) via " <> Text.unpack (rpcEndpointLabel urls rpcUrl)
          pure $ Right result

activeRpcUrls :: [Text] -> IO [Text]
activeRpcUrls urls = do
  now <- getCurrentTime
  modifyMVar rpcFailureCooldowns $ \cooldowns -> do
    let currentCooldowns = Map.filter (> now) cooldowns
        isActive url = not (Map.member url currentCooldowns)
        active = filter isActive urls
    pure (currentCooldowns, if null active then urls else active)

coolRpcUrl :: Text -> Text -> IO NominalDiffTime
coolRpcUrl rpcUrl reason = do
  now <- getCurrentTime
  let cooldown = rpcFailureCooldown reason
      untilTime = addUTCTime cooldown now
  modifyMVar rpcFailureCooldowns $ \cooldowns ->
    pure (Map.insert rpcUrl untilTime cooldowns, cooldown)

clearRpcCooldown :: Text -> IO ()
clearRpcCooldown rpcUrl =
  modifyMVar rpcFailureCooldowns $ \cooldowns ->
    pure (Map.delete rpcUrl cooldowns, ())

rpcFailureCooldown :: Text -> NominalDiffTime
rpcFailureCooldown reason
  | any (`Text.isInfixOf` lower) ["monthly capacity", "capacity limit", "billing", "quota"] = 86_400
  | any (`Text.isInfixOf` lower) ["429", "rate limit", "ratelimit", "too many", "limit exceeded"] = 600
  | otherwise = 30
  where
    lower = Text.toLower reason

redactRpcUrl :: Text -> Text
redactRpcUrl rpcUrl =
  case Text.breakOn "://" rpcUrl of
    (_, "") -> rpcUrl
    (scheme, rest) ->
      let afterScheme = Text.drop 3 rest
          (host, path') = Text.breakOn "/" afterScheme
       in scheme <> "://" <> host <> if Text.null path' then "" else "/<redacted>"

rpcEndpointLabel :: [Text] -> Text -> Text
rpcEndpointLabel urls rpcUrl =
  "upstream #" <> indexLabel <> " id=rpc-" <> shortRpcId rpcUrl <> " " <> redactRpcUrl rpcUrl
  where
    indexLabel = maybe "?" (Text.pack . show . (+ 1)) (elemIndex rpcUrl urls)

shortRpcId :: Text -> Text
shortRpcId rpcUrl =
  Text.pack . leftPad 8 '0' $ showHex (fnv1a32 rpcUrl) ""
  where
    leftPad n c s = replicate (max 0 (n - length s)) c <> s

fnv1a32 :: Text -> Word32
fnv1a32 = Text.foldl' step 2166136261
  where
    step hashValue char = (hashValue `xor` fromIntegral (ord char)) * 16777619

-- | "Reverse engineer" the SolcContract and SourceCache structures for the
-- code fetched from the outside
externalSolcContract :: Env -> String -> Addr -> Contract -> IO (Maybe (SourceCache, SolcContract))
externalSolcContract env explorerUrl addr c = do
  let runtimeCode = forceBuf $ fromJust $ view bytecode c

  -- Try Sourcify first (if chainId available)
  sourcifyResult <- case env.chainId of
    Just chainId -> do
      putStr $ "Fetching source for " <> show addr <> " from Sourcify... "
      Sourcify.fetchContractSource chainId addr
    Nothing -> pure Nothing

  -- If Sourcify fails, try Etherscan (only if API key exists)
  sourceData <- case sourcifyResult of
    Just sd -> do
      putStrLn "Success!"
      pure (Just sd)
    Nothing -> do
      putStrLn "Failed!"
      case env.cfg.etherscanApiKey of
        Nothing -> do
          putStrLn "Skipping Etherscan (no API key configured)"
          pure Nothing
        Just _ -> do
          putStr $ "Fetching source for " <> show addr <> " from Etherscan... "
          result <- Etherscan.fetchContractSourceData
            env.chainId
            env.cfg.etherscanApiKey
            explorerUrl
            addr
          maybe (putStrLn "Failed!") (const $ putStrLn "Success!") result
          pure result

  -- Convert to SolcContract
  case sourceData of
    Just sd -> buildSolcContract runtimeCode sd
    Nothing -> pure Nothing

-- | Build SolcContract and SourceCache from SourceData
buildSolcContract :: BS.ByteString -> SourceData -> IO (Maybe (SourceCache, SolcContract))
buildSolcContract runtimeCode sd = do
  -- Build SourceCache from multiple source files
  let sourcesList = Map.toList sd.sourceFiles
      filesMap = Map.fromList $ zip [0..]
        (fmap (\(path, content) -> (Text.unpack path, UTF8.fromString $ Text.unpack content)) sourcesList)
      sourceCache = SourceCache
        { files = filesMap
        , lines = Vector.fromList . BS.split 0xa . snd <$> filesMap
        , asts = mempty
        }

  -- Parse source maps safely
  runtimeSrcmap <- case sd.runtimeSrcMap of
    Just sm -> makeSrcMapsSafe sm
    Nothing -> pure mempty

  creationSrcmap <- case sd.creationSrcMap of
    Just sm -> makeSrcMapsSafe sm
    Nothing -> pure mempty

  -- Build ABI maps
  -- TODO: Need mkAbiMap, mkEventMap, mkErrorMap to be exported from hevm
  -- For now, we keep them as mempty but at least we have the ABI data available
  let (abiMap', eventMap', errorMap') = (mempty, mempty, mempty)

  let solcContract = SolcContract
        { runtimeCode = runtimeCode
        , creationCode = mempty
        , runtimeCodehash = keccak' runtimeCode
        , creationCodehash = keccak' mempty
        , runtimeSrcmap = runtimeSrcmap
        , creationSrcmap = creationSrcmap
        , contractName = sd.contractName
        , constructorInputs = []
        , abiMap = abiMap'
        , eventMap = eventMap'
        , errorMap = errorMap'
        , storageLayout = Nothing
        , immutableReferences = fromMaybe mempty sd.immutableRefs
        }

  pure $ Just (sourceCache, solcContract)

-- | Safe wrapper for makeSrcMaps to prevent crashes
makeSrcMapsSafe :: Text.Text -> IO (Seq SrcMap)
makeSrcMapsSafe txt =
  catch (pure $ fromMaybe mempty $! makeSrcMaps txt)
        (\(_ :: SomeException) -> pure mempty)


saveCoverageReport :: Env -> Int -> IO ()
saveCoverageReport env runId = do
  case env.cfg.campaignConf.corpusDir of
    Nothing -> pure ()
    Just dir -> do
      -- coverage reports for external contracts
      -- Get contracts from hevm session cache
      sessionCache <- readMVar env.fetchSession.sharedCache
      explorerUrl <- Etherscan.getBlockExplorerUrl env.chainId
      let contractsCache = EVM.Fetch.makeContractFromRPC <$> sessionCache.contractCache
      forM_ (Map.toList contractsCache) $ \(addr, contract) -> do
        r <- externalSolcContract env explorerUrl addr contract
        case r of
          Just (externalSourceCache, solcContract) -> do
            let dir' = dir </> show addr
            saveCoverages env
                          runId
                          dir'
                          externalSourceCache
                          [solcContract]
          Nothing -> pure ()

fetchChainIdFrom :: [Text] -> IO (Maybe W256)
fetchChainIdFrom [] = pure Nothing
fetchChainIdFrom urls = do
  sess <- newRpcSession
  res <- fetchWithFallbacks urls $ \url -> do
    chainId <- EVM.Fetch.fetchQuery
      EVM.Fetch.Latest -- this shouldn't matter
      (EVM.Fetch.fetchWithSession url sess)
      EVM.Fetch.QueryChainId
    pure $ either (EVM.Fetch.FetchError . Text.pack . show) (`EVM.Fetch.FetchSuccess` EVM.Fetch.Fresh) chainId
  pure $ case res of
    EVM.Fetch.FetchSuccess chainId _ -> Just chainId
    _ -> Nothing

newRpcSession :: IO Session.Session
newRpcSession = do
  caStore <- getSystemCertificateStore
  Session.newSessionControl Nothing (rpcManagerSettings caStore)

rpcManagerSettings caStore =
  HTTP_TLS.mkManagerSettings (Connection.TLSSettings (tls12ClientParams caStore)) Nothing

tls12ClientParams caStore =
  let params = TLS.defaultParamsClient "" BS.empty
      shared = (TLS.clientShared params)
        { TLS.sharedCAStore = caStore
        }
      supported = (TLS.clientSupported params)
        { TLS.supportedVersions = [TLS.TLS12]
        }
  in params
    { TLS.clientSupported = supported
    , TLS.clientShared = shared
    }
