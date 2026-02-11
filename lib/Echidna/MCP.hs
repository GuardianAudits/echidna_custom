{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Echidna.MCP
  ( startMCPServer
  , recordTx
  , recordLogicalCoverage
  , mcpCheckpoint
  , setMCPPhase
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (dupChan, readChan)
import Control.Monad (forever, forM_)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Reader (MonadReader, ask)
import Data.Aeson (FromJSON(..), Value(..), object, (.=), encode, eitherDecode, withObject, (.:), (.:?), toJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as BS16
import Data.IORef (atomicModifyIORef', readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (LocalTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.String (fromString)
import System.IO (hPutStrLn, stderr)
import Network.HTTP.Types (status200, status400, status404)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS, strictRequestBody, Response, ResponseReceived)
import Network.Wai.Handler.Warp (runSettings, setHost, setPort, defaultSettings)
import Text.Read (readMaybe)

import EVM.Format (showTraceTree)
import EVM.Types
  ( VM(..)
  , VMResult(..)
  , VMType(Concrete)
  , EvmError(..)
  , Expr(ConcreteBuf)
  )

import Echidna.ABI (encodeSigWithName, encodeSig, ppAbiValue, signatureCall)
import Echidna.ContractName (contractNameForAddr)
import Echidna.LogicalCoverage (mergeLogicalCoverage)
import Echidna.Events (decodeRevertMsg)
import Echidna.MCP.Store
import Echidna.MCP.Types
import Echidna.MCP.UI (mcpDashboardHtml)
import Echidna.Output.Source (coverageLineHits)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..), MCPConf(..), MCPTransport(..))
import Echidna.Types.Test (EchidnaTest)
import Echidna.Types.Tx (Tx(..), TxCall(..))
import Echidna.Types.Worker (CampaignEvent, WorkerEvent(..), WorkerType(..))
import Echidna.Worker ()
import qualified Echidna.Types.Worker as Worker
import Echidna.Types.Coverage (coverageStats, mergeCoverageMaps)
import Echidna.LogicalCoverage.Types (LogicalCoverage)
import Echidna.Utility (getTimestamp)
import EVM.Dapp (DappInfo(..))

-- | Start MCP server if enabled.
startMCPServer :: Env -> IO ()
startMCPServer env@Env{mcpState, eventQueue, cfg} =
  case mcpState of
    Nothing -> pure ()
    Just st -> do
      let EConfig{mcpConf = MCPConf{transport, host, port}} = cfg
      -- listener for campaign events
      chan <- dupChan eventQueue
      _ <- forkIO $ forever $ do
        (ts, ev) <- readChan chan
        recordEvent st ts ev
      -- start transport
      case transport of
        MCPHttp -> do
          let hostStr = T.unpack host
              settings = setHost (fromString hostStr) $ setPort port defaultSettings
          _ <- forkIO $ runSettings settings (mcpApp env st)
          pure ()
        other -> do
          hPutStrLn stderr $ "MCP transport not supported: " <> show other <> " (server disabled)"
          writeIORef st.phase "disabled"

setMCPPhase :: Env -> Text -> IO ()
setMCPPhase Env{mcpState} phaseName =
  forM_ mcpState $ \st -> writeIORef st.phase phaseName

-- | Pause/stop checkpoint for worker loops.
mcpCheckpoint :: Env -> IO Bool
mcpCheckpoint Env{mcpState} =
  case mcpState of
    Nothing -> pure False
    Just st -> waitIfPaused st

recordLogicalCoverage :: (MonadIO m) => MCPState -> Int -> LogicalCoverage -> m ()
recordLogicalCoverage st wid cov =
  liftIO $ atomicModifyIORef' st.logicalByWorker $ \m -> (Map.insert wid cov m, ())

-- | Record a transaction, handler stats, and reverts/traces if applicable.
recordTx
  :: (MonadReader Env m, MonadIO m)
  => MCPState
  -> VM Concrete
  -> Tx
  -> VMResult Concrete
  -> m ()
recordTx st vm tx result = do
  Env{dapp} <- ask
  let success = isSuccessResult result
  let reason = failureReasonText result
  nowTime <- liftIO getTimestamp
  let now = formatTimestamp nowTime
  methodName <- case tx.call of
    SolCall solCall -> do
      contractName <- contractNameForAddr vm tx.dst
      let sig = signatureCall solCall
      pure $ Just (encodeSigWithName contractName sig)
    _ -> pure Nothing

  -- update counters
  liftIO $ atomicModifyIORef' st.counters $ \c ->
    let MCPRunCounters { totalCalls = t, successCalls = s, failedCalls = f } = c
        c' = MCPRunCounters
          { totalCalls = t + 1
          , successCalls = s + if success then 1 else 0
          , failedCalls = f + if success then 0 else 1
          }
    in (c', ())

  -- push tx stream
  let txEntry = MCPTx 0 now methodName success reason tx
  _ <- liftIO $ pushRing st.txs (\idVal -> txEntry { txId = idVal })

  -- update handler stats
  case tx.call of
    SolCall solCall -> do
      let args = map (T.pack . ppAbiValue vm.labels) (snd solCall)
      let updateStat stat =
            stat
              { totalCalls = stat.totalCalls + 1
              , successCalls = stat.successCalls + if success then 1 else 0
              , failedCalls = stat.failedCalls + if success then 0 else 1
              , lastArgs = args
              , lastSeen = now
              }
      liftIO $ atomicModifyIORef' st.handlers $ \m ->
        let stat = Map.findWithDefault (HandlerStat 0 0 0 [] now) (fromMaybe "unknown" methodName) m
            m' = Map.insert (fromMaybe "unknown" methodName) (updateStat stat) m
        in (m', ())
    _ -> pure ()

  -- if revert, capture trace
  case reason of
    Nothing -> pure ()
    Just r -> do
      let selector = case tx.call of
            SolCall solCall -> Just (encodeSig (signatureCall solCall))
            _ -> Nothing
      let traceText = showTraceTree dapp vm
      traceId <- liftIO $ pushRing st.traces (\idVal ->
        MCPTrace { traceId = idVal, timestamp = now, selector = selector, reason = r, trace = traceText }
        )
      let revertEntry = MCPRevert
            { revertId = 0
            , timestamp = now
            , contract = T.pack (show tx.dst)
            , selector = selector
            , reason = r
            , sender = T.pack (show tx.src)
            , recipient = T.pack (show tx.dst)
            , tx = tx
            , traceId = Just traceId
            }
      _ <- liftIO $ pushRing st.reverts (\idVal -> revertEntry { revertId = idVal })
      pure ()

-- | MCP HTTP application.
mcpApp :: Env -> MCPState -> Application
mcpApp env st req respond = do
  case (requestMethod req, pathInfo req) of
    ("GET", []) ->
      respond $ responseLBS status200 [("Content-Type", "text/html; charset=utf-8")] mcpDashboardHtml
    ("GET", ["ui"]) ->
      respond $ responseLBS status200 [("Content-Type", "text/html; charset=utf-8")] mcpDashboardHtml
    ("GET", ["health"]) ->
      respond $ responseLBS status200 [("Content-Type", "text/plain")] "ok"
    ("POST", ["mcp"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> respond $ responseLBS status400 [("Content-Type", "application/json")] (encode $ mcpError Null (-32700) (T.pack err))
        Right rpc -> handleRPC env st rpc respond
    _ ->
      respond $ responseLBS status404 [("Content-Type", "text/plain")] "not found"

data RPCRequest = RPCRequest
  { jsonrpc :: Text
  , method  :: Text
  , params  :: Maybe Value
  , reqId   :: Value
  }

instance FromJSON RPCRequest where
  parseJSON = withObject "RPCRequest" $ \o ->
    RPCRequest <$> o .: "jsonrpc"
               <*> o .: "method"
               <*> o .:? "params"
               <*> o .: "id"

handleRPC :: Env -> MCPState -> RPCRequest -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleRPC env st RPCRequest{..} respond = do
  result <- case method of
    "resources/list" -> pure $ Right (resourcesListResult)
    "resources/read" -> resourcesReadResult env st params
    "tools/list" -> pure $ Right toolsListResult
    "tools/call" -> toolsCallResult env st params
    _ -> pure $ Left $ mcpError reqId (-32601) "Method not found"
  case result of
    Left err -> respond $ responseLBS status200 [("Content-Type", "application/json")] (encode err)
    Right res -> respond $ responseLBS status200 [("Content-Type", "application/json")] (encode $ mcpResult reqId res)

resourcesListResult :: Value
resourcesListResult = object
  [ "resources" .=
      [ resource "echidna://run/status" "Run status"
      , resource "echidna://run/config" "Run config"
      , resource "echidna://run/tests" "Tests"
      , resource "echidna://run/events" "Events"
      , resource "echidna://run/reverts" "Reverts"
      , resource "echidna://run/txs" "Transactions"
      , resource "echidna://run/handlers" "Handlers"
      , resource "echidna://run/traces" "Traces"
      , resource "echidna://run/trace" "Trace (by id)"
      , resource "echidna://coverage/summary" "Coverage summary"
      , resource "echidna://coverage/lines" "Coverage line hits"
      , resource "echidna://stats/logical-coverage" "Logical coverage"
      ]
  ]
  where
    resource :: Text -> Text -> Value
    resource uri name = object
      [ "uri" .= uri
      , "name" .= name
      , "mimeType" .= ("application/json" :: Text)
      ]

resourcesReadResult :: Env -> MCPState -> Maybe Value -> IO (Either Value Value)
resourcesReadResult env st paramsVal =
  case paramsVal of
    Just (Object o) -> case lookupKey "uri" o of
      Just (String uri) -> do
        val <- readResource env st uri
        let content = object
              [ "uri" .= uri
              , "mimeType" .= ("application/json" :: Text)
              , "text" .= (decodeUtf8 $ LBS.toStrict $ encode val)
              ]
        pure $ Right (object ["contents" .= [content]])
      _ -> pure $ Left $ mcpError Null (-32602) "Missing uri"
    _ -> pure $ Left $ mcpError Null (-32602) "Missing params"

toolsListResult :: Value
toolsListResult = object
  [ "tools" .=
      [ tool "get_status" "Get run status"
      , tool "get_events" "Get events"
      , tool "get_reverts" "Get reverts"
      , tool "get_handlers" "Get handlers"
      , tool "get_traces" "Get traces"
      , tool "get_logical_coverage" "Get logical coverage"
      , tool "get_coverage_hits" "Get coverage line hits"
      , tool "pause" "Pause run"
      , tool "resume" "Resume run"
      , tool "stop" "Stop run"
      ]
  ]
  where
    tool :: Text -> Text -> Value
    tool name desc = object
      [ "name" .= name
      , "description" .= desc
      , "inputSchema" .= object []
      ]

toolsCallResult :: Env -> MCPState -> Maybe Value -> IO (Either Value Value)
toolsCallResult env st paramsVal =
  case paramsVal of
    Just (Object o) ->
      case lookupKey "name" o of
        Just (String name) -> do
          let args = case lookupKey "arguments" o of
                Just (Object a) -> Just (Object a)
                _ -> Nothing
          res <- runTool env st name args
          let content = object [ "type" .= ("text" :: Text), "text" .= (decodeUtf8 $ LBS.toStrict $ encode res) ]
          pure $ Right (object ["content" .= [content]])
        _ -> pure $ Left $ mcpError Null (-32602) "Missing tool name"
    _ -> pure $ Left $ mcpError Null (-32602) "Missing params"

runTool :: Env -> MCPState -> Text -> Maybe Value -> IO Value
runTool env st name args =
  case name of
    "pause" -> pauseMCP st >> setMCPPhase env "paused" >> pure (object ["ok" .= True])
    "resume" -> resumeMCP st >> setMCPPhase env "running" >> pure (object ["ok" .= True])
    "stop" -> requestStopMCP st >> setMCPPhase env "stopped" >> pure (object ["ok" .= True])
    "get_status" -> readResource env st "echidna://run/status"
    "get_events" -> readResource env st (resourceWithArgs "echidna://run/events" args)
    "get_reverts" -> readResource env st (resourceWithArgs "echidna://run/reverts" args)
    "get_handlers" -> readResource env st "echidna://run/handlers"
    "get_traces" -> readResource env st (resourceWithArgs "echidna://run/traces" args)
    "get_logical_coverage" -> readResource env st "echidna://stats/logical-coverage"
    "get_coverage_hits" -> readResource env st "echidna://coverage/lines"
    _ -> pure (object ["error" .= ("unknown tool" :: Text)])

resourceWithArgs :: Text -> Maybe Value -> Text
resourceWithArgs base args =
  case args of
    Just (Object o) ->
      let params = KM.toList o
          q = T.intercalate "&" $ map (\(k,v) -> K.toText k <> "=" <> renderValue v) params
      in if T.null q then base else base <> "?" <> q
    _ -> base
  where
    renderValue = \case
      String t -> t
      Number n -> T.pack (show n)
      Bool b -> if b then "true" else "false"
      _ -> ""

readResource :: Env -> MCPState -> Text -> IO Value
readResource env st uri = do
  let (path, query) = splitUri uri
  case path of
    "echidna://run/status" -> runStatus env st
    "echidna://run/config" -> runConfig env
    "echidna://run/tests" -> runTests env
    "echidna://run/events" -> runEvents st query
    "echidna://run/reverts" -> runReverts st query
    "echidna://run/txs" -> runTxs st query
    "echidna://run/handlers" -> runHandlers st
    "echidna://run/traces" -> runTraces st query
    "echidna://run/trace" -> runTrace st query
    "echidna://coverage/summary" -> coverageSummary env
    "echidna://coverage/lines" -> coverageLines env
    "echidna://stats/logical-coverage" -> logicalCoverage env st
    _ -> pure (object ["error" .= ("unknown resource" :: Text)])

runStatus :: Env -> MCPState -> IO Value
runStatus Env{coverageRefInit, coverageRefRuntime, corpusRef} st = do
  counters <- readIORef st.counters
  phase <- readIORef st.phase
  (points, codehashes) <- coverageStats coverageRefInit coverageRefRuntime
  corpus <- readIORef corpusRef
  pure $ object
    [ "phase" .= phase
    , "counters" .= counters
    , "coveragePoints" .= points
    , "uniqueCodehashes" .= codehashes
    , "corpusSize" .= length corpus
    ]

runConfig :: Env -> IO Value
runConfig Env{cfg = EConfig{campaignConf = c}} = do
  let CampaignConf
        { testLimit = testLimit'
        , seqLen = seqLen'
        , shrinkLimit = shrinkLimit'
        , coverageFormats = coverageFormats'
        , coverageLineHits = coverageLineHits'
        , logicalCoverage = logicalCoverage'
        , logicalCoverageTopN = logicalCoverageTopN'
        } = c
  pure $ object
    [ "testLimit" .= testLimit'
    , "seqLen" .= seqLen'
    , "shrinkLimit" .= shrinkLimit'
    , "coverageFormats" .= coverageFormats'
    , "coverageLineHits" .= coverageLineHits'
    , "logicalCoverage" .= logicalCoverage'
    , "logicalCoverageTopN" .= logicalCoverageTopN'
    ]

runTests :: Env -> IO Value
runTests Env{testRefs} = do
  tests <- traverse readIORef testRefs
  pure $ object ["tests" .= (tests :: [EchidnaTest])]

runEvents :: MCPState -> Map Text Text -> IO Value
runEvents st query = do
  let since = readQueryInt "since" 0 query
      limit = readQueryInt "limit" 200 query
  entries <- readSince st.events since limit
  pure $ object ["events" .= map (\(_, e) -> e) entries]

runReverts :: MCPState -> Map Text Text -> IO Value
runReverts st query = do
  let since = readQueryInt "since" 0 query
      limit = readQueryInt "limit" 200 query
  entries <- readSince st.reverts since limit
  pure $ object ["reverts" .= map (\(_, r) -> r) entries]

runTxs :: MCPState -> Map Text Text -> IO Value
runTxs st query = do
  let since = readQueryInt "since" 0 query
      limit = readQueryInt "limit" 200 query
  entries <- readSince st.txs since limit
  pure $ object ["txs" .= map (\(_, r) -> r) entries]

runHandlers :: MCPState -> IO Value
runHandlers st = do
  handlers <- readIORef st.handlers
  pure $ object ["handlers" .= handlers]

runTraces :: MCPState -> Map Text Text -> IO Value
runTraces st query = do
  let since = readQueryInt "since" 0 query
      limit = readQueryInt "limit" 200 query
  entries <- readSince st.traces since limit
  pure $ object ["traces" .= map (\(_, r) -> r) entries]

runTrace :: MCPState -> Map Text Text -> IO Value
runTrace st query = do
  let tid = readQueryInt "id" (-1) query
  if tid < 0
    then pure $ object ["trace" .= Null]
    else do
      m <- readById st.traces tid
      pure $ object ["trace" .= m]

coverageSummary :: Env -> IO Value
coverageSummary Env{coverageRefInit, coverageRefRuntime} = do
  (points, codehashes) <- coverageStats coverageRefInit coverageRefRuntime
  pure $ object ["points" .= points, "uniqueCodehashes" .= codehashes]

coverageLines :: Env -> IO Value
coverageLines Env{dapp = dappInfo, coverageRefInit, coverageRefRuntime, cfg = EConfig{campaignConf = c}} = do
  let CampaignConf{coverageExcludes = coverageExcludes'} = c
      DappInfo{solcByName = solcByName', sources = sources'} = dappInfo
  covMap <- mergeCoverageMaps dappInfo coverageRefInit coverageRefRuntime
  let contracts = Map.elems solcByName'
      hits = coverageLineHits sources' covMap contracts coverageExcludes'
  pure $ toJSON hits

logicalCoverage :: Env -> MCPState -> IO Value
logicalCoverage Env{cfg = EConfig{campaignConf = c}} st = do
  let CampaignConf{logicalCoverageMaxReasons = maxReasons} = c
  m <- readIORef st.logicalByWorker
  let merged = mergeLogicalCoverage maxReasons (Map.elems m)
  pure $ toJSON merged

recordEvent :: MCPState -> LocalTime -> CampaignEvent -> IO ()
recordEvent st ts ev = do
  let (wid, wtype, etype, payload) = case ev of
        Worker.WorkerEvent wid' wtype' e ->
          (Just wid', Just (workerTypeText wtype'), workerEventType e, toJSON e)
        Worker.Failure msg -> (Nothing, Nothing, "Failure", toJSON msg)
        Worker.ReproducerSaved f -> (Nothing, Nothing, "ReproducerSaved", toJSON f)
      event = MCPEvent 0 (formatTimestamp ts) wid wtype etype payload
  _ <- pushRing st.events (\idVal -> event { eventId = idVal })
  pure ()

workerTypeText :: WorkerType -> Text
workerTypeText = \case
  FuzzWorker -> "fuzz"
  SymbolicWorker -> "symbolic"

workerEventType :: WorkerEvent -> Text
workerEventType = \case
  TestFalsified _ -> "TestFalsified"
  TestOptimized _ -> "TestOptimized"
  NewCoverage {} -> "NewCoverage"
  SymExecError _ -> "SymExecError"
  SymExecLog _ -> "SymExecLog"
  TxSequenceReplayed {} -> "TxSequenceReplayed"
  TxSequenceReplayFailed {} -> "TxSequenceReplayFailed"
  WorkerStopped {} -> "WorkerStopped"

isSuccessResult :: VMResult Concrete -> Bool
isSuccessResult = \case
  VMSuccess _ -> True
  _ -> False

failureReasonText :: VMResult Concrete -> Maybe Text
failureReasonText = \case
  VMFailure (Revert (ConcreteBuf bs)) -> Just $ decodeRevertReason bs
  VMFailure err -> Just $ "Error(" <> T.pack (show err) <> ")"
  _ -> Nothing

decodeRevertReason :: BS.ByteString -> Text
decodeRevertReason bs =
  fromMaybe fallback (decodeRevertMsg True bs)
  where
    fallback =
      if BS.length bs >= 4
        then "CustomError(" <> selectorHex bs <> ")"
        else "UnknownRevert(" <> T.pack (show (BS.length bs)) <> ")"
    selectorHex bytes =
      let hex = decodeUtf8 (BS16.encode (BS.take 4 bytes))
      in "0x" <> hex

formatTimestamp :: LocalTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S"

mcpError :: Value -> Int -> Text -> Value
mcpError rid code msg = object
  [ "jsonrpc" .= ("2.0" :: Text)
  , "id" .= rid
  , "error" .= object ["code" .= code, "message" .= msg]
  ]

mcpResult :: Value -> Value -> Value
mcpResult rid res = object
  [ "jsonrpc" .= ("2.0" :: Text)
  , "id" .= rid
  , "result" .= res
  ]

splitUri :: Text -> (Text, Map Text Text)
splitUri uri =
  case T.breakOn "?" uri of
    (path, qs) -> (path, parseQuery (T.drop 1 qs))

parseQuery :: Text -> Map Text Text
parseQuery qs =
  let parts = filter (not . T.null) (T.splitOn "&" qs)
  in Map.fromList $ map parsePair parts
  where
    parsePair p =
      case T.splitOn "=" p of
        (k:v:_) -> (k, v)
        (k:_) -> (k, "")
        _ -> ("", "")

readQueryInt :: Text -> Int -> Map Text Text -> Int
readQueryInt key def q =
  case Map.lookup key q of
    Just v -> fromMaybe def (readMaybe (T.unpack v))
    Nothing -> def

lookupKey :: Text -> KM.KeyMap Value -> Maybe Value
lookupKey key = KM.lookup (K.fromText key)
