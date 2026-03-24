module Echidna.Onchain
  ( etherscanApiKey
  , fetchChainIdFrom
  , rpcBlockEnv
  , rpcUrlEnv
  , safeFetchContractFrom
  , safeFetchSlotFrom
  , saveCoverageReport
  , saveRpcCache
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (SomeException, catch, try)
import Control.Monad (when, forM_)
import Data.ByteString qualified as BS
import Data.ByteString.UTF8 qualified as UTF8
import Data.Map qualified as Map
import Data.Maybe (isJust, fromJust, fromMaybe)
import Data.Sequence (Seq)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Network.Wreq.Session qualified as Session
import Optics (view)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Timeout qualified
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

rpcBlockEnv :: IO (Maybe Word64)
rpcBlockEnv = do
  val <- lookupEnv "ECHIDNA_RPC_BLOCK"
  pure (val >>= readMaybe)

etherscanApiKey :: IO (Maybe Text)
etherscanApiKey = do
  val <- lookupEnv "ETHERSCAN_API_KEY"
  pure (Text.pack <$> val)

safeFetchContractFrom
  :: EVM.Fetch.Session -> EVM.Fetch.BlockNumber -> Text -> [Text] -> Maybe Int
  -> Addr -> IO (EVM.Fetch.FetchResult Contract)
safeFetchContractFrom session rpcBlock rpcUrl fallbackRpcUrls rpcTimeout addr =
  retryForever (rpcUrl : fallbackRpcUrls) rpcTimeout $ \url -> do
    res <- EVM.Fetch.fetchContractWithSession defaultConfig session rpcBlock url addr
    pure $ case res of
      EVM.Fetch.FetchSuccess c status -> EVM.Fetch.FetchSuccess (EVM.Fetch.makeContractFromRPC c) status
      EVM.Fetch.FetchFailure status -> EVM.Fetch.FetchFailure status
      EVM.Fetch.FetchError e -> EVM.Fetch.FetchError e

safeFetchSlotFrom
  :: EVM.Fetch.Session -> EVM.Fetch.BlockNumber -> Text -> [Text] -> Maybe Int
  -> Addr -> W256 -> IO (EVM.Fetch.FetchResult W256)
safeFetchSlotFrom session rpcBlock rpcUrl fallbackRpcUrls rpcTimeout addr slot =
  retryForever (rpcUrl : fallbackRpcUrls) rpcTimeout $
    \url -> EVM.Fetch.fetchSlotWithCache defaultConfig session rpcBlock url addr slot

retryForever
  :: [Text]
  -> Maybe Int
  -> (Text -> IO (EVM.Fetch.FetchResult a))
  -> IO (EVM.Fetch.FetchResult a)
retryForever urls rpcTimeout action = go urls 1_000_000
  where
    maxDelay = 30_000_000
    tryAny :: IO b -> IO (Either SomeException b)
    tryAny = try

    tryFetch url = do
      let attempt = action url
      result <- case rpcTimeout of
        Nothing ->
          tryAny attempt
        Just timeoutMs -> do
          timed <- System.Timeout.timeout (timeoutMs * 1000) (tryAny attempt)
          pure $ case timed of
            Just fetchResult -> fetchResult
            Nothing ->
              Right $ EVM.Fetch.FetchError $ Text.pack $ "RPC timeout after " <> show timeoutMs <> "ms"
      pure $ case result of
        Right fetchResult -> fetchResult
        Left e -> EVM.Fetch.FetchError (Text.pack $ show e)

    go [] delay = do
      hPutStrLn stderr $
        "WARNING: All RPC URLs failed, waiting " <> show (delay `div` 1_000_000) <> "s before retrying..."
      threadDelay delay
      go urls (min maxDelay (delay * 2))
    go (url:rest) delay = do
      result <- tryFetch url
      case result of
        EVM.Fetch.FetchError e -> do
          hPutStrLn stderr $ "WARNING: RPC fetch failed on " <> Text.unpack url <> ": " <> Text.unpack e
          go rest delay
        _ ->
          pure result

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

fetchChainIdFrom :: Maybe Text -> IO (Maybe W256)
fetchChainIdFrom (Just url) = do
  sess <- Session.newAPISession
  res <- EVM.Fetch.fetchQuery
    EVM.Fetch.Latest -- this shouldn't matter
    (EVM.Fetch.fetchWithSession url sess)
    EVM.Fetch.QueryChainId
  pure $ either (const Nothing) Just res
fetchChainIdFrom Nothing = pure Nothing
