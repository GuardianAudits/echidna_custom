{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

{-# LANGUAGE GADTs #-}

module Echidna.MCP
  ( startMCPServer
  , recordTx
  , recordLogicalCoverage
  , mcpCheckpoint
  , setMCPPhase
  , recordTestState
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (dupChan, readChan)
import Control.Monad (forever, forM_, unless)
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
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (LocalTime, UTCTime, getCurrentTime)
import Data.Time.Clock (addUTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.String (fromString)
import Data.Ord (Down(..))
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
  ( MCPEvent(..)
  , MCPReproducerArtifact(..)
  , MCPReproducerEvent(..)
  , MCPReproducerJob(..)
  , MCPReproducerJobPriority(..)
  , MCPReproducerJobStatus(..)
  , MCPReproducerStatus(..)
  , MCPRevert(..)
  , MCPRunCounters(..)
  , MCPReproducerShrink(..)
  , MCPReproducerTxSet(..)
  , MCPTrace(..)
  , MCPTx(..)
  , HandlerStat(..)
  )
import Echidna.MCP.UI (mcpDashboardHtml)
import Echidna.Output.Source (coverageLineHits)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..), MCPConf(..), MCPTransport(..))
import Echidna.Types.Test (EchidnaTest(..), TestState(..), TestType(..))
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
      , resource "echidna://run/reproducers" "Reproducer snapshots"
      , resource "echidna://run/reproducer/<test-key>" "Single reproducer snapshot"
      , resource "echidna://run/reproducers?state=..." "Reproducer snapshots (filtered)"
      , resource "echidna://run/events" "Events"
      , resource "echidna://run/reverts" "Reverts"
      , resource "echidna://run/txs" "Transactions"
      , resource "echidna://run/handlers" "Handlers"
      , resource "echidna://run/traces" "Traces"
      , resource "echidna://run/trace" "Trace (by id)"
      , resource "echidna://run/shrink-job/<id>" "Shrink job status"
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
      , tool "get_reproducers" "List reproducer snapshots"
      , tool "get_reproducer" "Get a reproducer snapshot"
      , tool "request_shrunk_reproducer" "Request fully-shrunk reproducer job"
      , tool "get_shrink_job" "Get status of a shrink job"
      , tool "cancel_shrink_job" "Cancel a shrink job"
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
    "get_reproducers" -> runReproducers st (argsToQuery args)
    "get_reproducer" -> runGetReproducer st (argsToQuery args)
    "request_shrunk_reproducer" -> requestShrunkReproducer st (argsToQuery args)
    "get_shrink_job" -> runShrinkJob st (argsToQuery args)
    "cancel_shrink_job" -> cancelShrinkJob st (argsToQuery args)
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

readResource :: Env -> MCPState -> Text -> IO Value
readResource env st uri = do
  let (path, query) = splitUri uri
  case path of
    "echidna://run/status" -> runStatus env st
    "echidna://run/config" -> runConfig env
    "echidna://run/tests" -> runTests env
    "echidna://run/events" -> runEvents st query
    "echidna://run/reverts" -> runReverts st query
    "echidna://run/reproducers" -> runReproducers st query
    p | "echidna://run/reproducer/" `T.isPrefixOf` p -> do
      let key = T.drop (T.length "echidna://run/reproducer/") p
      runReproducerFromKey env st key query
    p | "echidna://run/shrink-job/" `T.isPrefixOf` p -> do
      let jobId = T.drop (T.length "echidna://run/shrink-job/") p
      runShrinkJob st (Map.singleton "jobId" jobId)
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
        , showShrinkingEvery = showShrinkingEvery'
        , saveEvery = saveEvery'
        , coverageFormats = coverageFormats'
        , coverageLineHits = coverageLineHits'
        , logicalCoverage = logicalCoverage'
        , logicalCoverageTopN = logicalCoverageTopN'
        } = c
  pure $ object
    [ "testLimit" .= testLimit'
    , "seqLen" .= seqLen'
    , "shrinkLimit" .= shrinkLimit'
    , "showShrinkingEvery" .= showShrinkingEvery'
    , "saveEvery" .= saveEvery'
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

data ReproducerLookup
  = ReproducerMissing
  | ReproducerStale Int
  | ReproducerFound MCPReproducerArtifact

recordTestState :: MCPState -> Int -> EchidnaTest -> IO ()
recordTestState st idx test = do
  now <- getCurrentTime
  purgeExpiredReproducers st now
  let key = mkTestKey st idx test
      artifact = MCPReproducerArtifact
        { testKey = key
        , testId = key
        , workerId = test.workerId
        , testType = renderTestType test.testType
        , testState = renderTestState test.state
        , campaignId = st.campaignId
        , reproducer = MCPReproducerTxSet
            { reproducerLatest = test.reproducer
            , reproducerBest = test.reproducer
            , reproducerCandidate = test.reproducer
            }
        , shrink = MCPReproducerShrink
            { shrinkStatus = inferShrinkStatus test.state
            , shrinkFullyShrunk = isFullyShrunk test.state
            , shrinkLastUpdatedAt = Just now
            , shrinkAttempts = 0
            , shrinkStableSince = Nothing
            , shrinkNoProgressCount = 0
            }
        , origin = Nothing
        , coverage = Nothing
        , updatedAt = now
        }
      artifact' = trimArtifactTxs st.maxReproducerTxs artifact
  atomicModifyIORef' st.reproducerArtifacts $ \artifacts ->
    (trimByUpdatedAt st.maxReproducerArtifacts artifactUpdatedAt (Map.insert key artifact' artifacts), ())
  emitReproducerEvent st "artifact_updated" key (toJSON artifact')
  syncJobsForTest st key artifact' now

runReproducers :: MCPState -> Map Text Text -> IO Value
runReproducers st query = do
  now <- getCurrentTime
  purgeExpiredReproducers st now
  artifacts <- readIORef st.reproducerArtifacts
  let offset = readQueryInt "offset" 0 query
      limit = readQueryInt "limit" 100 query
      filtered = applyReproducerFilters query $ Map.elems artifacts
      selected = take limit $ drop offset $ sortOn (Down . artifactUpdatedAt) filtered
      responseArtifacts = map (shapeArtifactForResponse st False) selected
  pure $ object
    [ "reproducers" .= responseArtifacts
    , "count" .= length filtered
    , "nextOffset" .= (offset + length responseArtifacts)
    ]

runReproducerFromKey :: Env -> MCPState -> Text -> Map Text Text -> IO Value
runReproducerFromKey _ st key query = do
  now <- getCurrentTime
  lookupResult <- getReproducerArtifact st now key
  case lookupResult of
    ReproducerMissing ->
      pure $ object ["error" .= ("reproducer not found" :: Text)]
    ReproducerStale ageSeconds ->
      pure $ object
        [ "error" .= ("reproducer not found" :: Text)
        , "lastKnownAge" .= ageSeconds
        ]
    ReproducerFound artifact -> do
      let includeCandidate = readQueryBool "includeCandidate" True query
          artifact' = shapeArtifactForResponse st includeCandidate artifact
      pure $ object
        [ "testKey" .= key
        , "artifact" .= artifact'
        ]

runGetReproducer :: MCPState -> Map Text Text -> IO Value
runGetReproducer st args = do
  resolveReproducerKey st args >>= \case
    Left err -> pure $ object ["error" .= err]
    Right key -> do
      now <- getCurrentTime
      getReproducerArtifact st now key >>= \case
        ReproducerMissing ->
          pure $ object ["error" .= ("reproducer not found" :: Text)]
        ReproducerStale ageSeconds ->
          pure $ object
            [ "error" .= ("reproducer not found" :: Text)
            , "lastKnownAge" .= ageSeconds
            ]
        ReproducerFound artifact ->
          let includeCandidate = readQueryBool "includeCandidate" True args
              artifact' = shapeArtifactForResponse st includeCandidate artifact
          in pure $ object ["testKey" .= key, "artifact" .= artifact']

runShrinkJob :: MCPState -> Map Text Text -> IO Value
runShrinkJob st args = do
  case Map.lookup "jobId" args of
    Nothing -> pure $ object ["error" .= ("missing jobId" :: Text)]
    Just jobId -> do
      jobs <- readIORef st.reproducerJobs
      pure $ maybe
        (object ["error" .= ("unknown job" :: Text)])
        (\job -> object ["job" .= job])
        (Map.lookup jobId jobs)

requestShrunkReproducer :: MCPState -> Map Text Text -> IO Value
requestShrunkReproducer st args = do
  now <- getCurrentTime
  keyResult <- resolveReproducerKey st args
  case keyResult of
    Left err -> pure $ object ["error" .= err]
    Right key -> do
      getReproducerArtifact st now key >>= \case
        ReproducerMissing -> pure $ object ["error" .= ("reproducer not found" :: Text)]
        ReproducerStale ageSeconds ->
          pure $ object
            [ "error" .= ("reproducer not found" :: Text)
            , "lastKnownAge" .= ageSeconds
            ]
        ReproducerFound artifact -> do
          let force = readQueryBool "force" False args
              priority = parseJobPriority $ Map.lookup "priority" args
              workerHint = Map.lookup "workerHint" args
          if not force && artifact.shrink.shrinkFullyShrunk
            then pure $
              object
                [ "accepted" .= False
                , "reason" .= ("already_complete" :: Text)
                , "testKey" .= key
                , "artifactUri" .= ("echidna://run/reproducer/" <> key)
                ]
            else do
              jobs <- readIORef st.reproducerJobs
              let activeJobs = Map.elems (Map.filter (\job -> job.testKey == key && job.status `elem` [MCPReproducerJobQueued, MCPReproducerJobActive]) jobs)
              case activeJobs of
                [] -> do
                  jobId <- createShrinkJob st key force priority workerHint now
                  emitReproducerEvent st "shrink_job_created" key (toJSON jobId)
                  pure $ object
                    [ "accepted" .= True
                    , "jobId" .= jobId
                    , "testKey" .= key
                    , "statusUri" .= ("echidna://run/shrink-job/" <> jobId)
                    , "artifactUri" .= ("echidna://run/reproducer/" <> key)
                    ]
                [existingJob] | force -> do
                  updateExistingJob st existingJob.testKey priority workerHint now
                  pure $ object
                    [ "accepted" .= True
                    , "jobId" .= existingJob.jobId
                    , "testKey" .= key
                    , "statusUri" .= ("echidna://run/shrink-job/" <> existingJob.jobId)
                    , "artifactUri" .= ("echidna://run/reproducer/" <> key)
                    ]
                _ -> pure $
                  object
                    [ "accepted" .= False
                    , "reason" .= ("already_queued" :: Text)
                    , "testKey" .= key
                    ]

cancelShrinkJob :: MCPState -> Map Text Text -> IO Value
cancelShrinkJob st args = do
  now <- getCurrentTime
  case Map.lookup "jobId" args of
    Nothing -> pure $ object ["error" .= ("missing jobId" :: Text)]
    Just jobId -> do
      status <- atomicModifyIORef' st.reproducerJobs $ \jobs ->
        case Map.lookup jobId jobs of
          Nothing -> (jobs, Left ())
          Just job ->
            let job' = if job.status `elem` [MCPReproducerJobComplete, MCPReproducerJobFailed, MCPReproducerJobCanceled]
                        then job
                        else job { status = MCPReproducerJobCanceled, reason = Just "canceled", updatedAt = now }
                jobs' = Map.insert jobId job' jobs
            in (jobs', Right job')
      case status of
        Left _ -> pure $ object ["error" .= ("unknown job" :: Text)]
        Right _ -> do
          emitReproducerEvent st "shrink_job_canceled" jobId (toJSON jobId)
          pure $ object ["ok" .= True, "jobId" .= jobId]

trimArtifactTxs :: Int -> MCPReproducerArtifact -> MCPReproducerArtifact
trimArtifactTxs limit artifact =
  if limit > 0
    then setArtifactReproducer artifact (trimTxSet limit (artifactReproducer artifact))
    else artifact

trimTxSet :: Int -> MCPReproducerTxSet -> MCPReproducerTxSet
trimTxSet limit txSet =
  if limit <= 0
    then txSet
    else txSet
      { reproducerLatest = take limit txSet.reproducerLatest
      , reproducerBest = take limit txSet.reproducerBest
      , reproducerCandidate = take limit txSet.reproducerCandidate
      }

artifactUpdatedAt :: MCPReproducerArtifact -> UTCTime
artifactUpdatedAt (MCPReproducerArtifact _ _ _ _ _ _ _ _ _ _ updatedAt) = updatedAt

artifactReproducer :: MCPReproducerArtifact -> MCPReproducerTxSet
artifactReproducer (MCPReproducerArtifact _ _ _ _ _ _ reproducer _ _ _ _) = reproducer

setArtifactReproducer :: MCPReproducerArtifact -> MCPReproducerTxSet -> MCPReproducerArtifact
setArtifactReproducer (MCPReproducerArtifact a b c d e f _ g h i j) txSet =
  MCPReproducerArtifact a b c d e f txSet g h i j

jobUpdatedAt :: MCPReproducerJob -> UTCTime
jobUpdatedAt (MCPReproducerJob _ _ _ _ _ _ _ updatedAt _ _ _) = updatedAt

shapeArtifactForResponse :: MCPState -> Bool -> MCPReproducerArtifact -> MCPReproducerArtifact
shapeArtifactForResponse st includeCandidate artifact =
  let artifact' =
        if includeCandidate
          then artifact
          else setArtifactReproducer artifact
            ((artifactReproducer artifact) { reproducerCandidate = [] })
      artifact'' = if st.includeCallData
        then artifact'
        else sanitizeReproducerPayload artifact'
      artifact''' = trimArtifactTxs st.maxReproducerTxs artifact''
  in enforceArtifactJsonLimit st.maxReproducerJsonBytes artifact'''

sanitizeReproducerPayload :: MCPReproducerArtifact -> MCPReproducerArtifact
sanitizeReproducerPayload artifact =
  let sanitizeTxSet txSet = txSet
        { reproducerLatest = map redactCallData txSet.reproducerLatest
        , reproducerBest = map redactCallData txSet.reproducerBest
        , reproducerCandidate = map redactCallData txSet.reproducerCandidate
        }
  in setArtifactReproducer artifact (sanitizeTxSet $ artifactReproducer artifact)

redactCallData :: Tx -> Tx
redactCallData tx = tx { call = NoCall }

enforceArtifactJsonLimit :: Int -> MCPReproducerArtifact -> MCPReproducerArtifact
enforceArtifactJsonLimit maxBytes artifact
  | maxBytes <= 0 = artifact
  | otherwise = trimUntilFits maxBytes artifact
  where
    trimUntilFits n current
      | artifactJsonBytes current <= fromIntegral n = current
      | otherwise =
        let shrunk = shrinkTxsByOne current
        in if artifactJsonBytes shrunk >= artifactJsonBytes current
           then current
           else trimUntilFits n shrunk

    artifactJsonBytes = LBS.length . encode . toJSON
    shrinkTxsByOne txs =
      let set = artifactReproducer txs
          set' = if not (null set.reproducerCandidate)
            then set { reproducerCandidate = drop 1 set.reproducerCandidate }
            else if not (null set.reproducerLatest)
            then set { reproducerLatest = drop 1 set.reproducerLatest }
            else if not (null set.reproducerBest)
            then set { reproducerBest = drop 1 set.reproducerBest }
            else set
      in setArtifactReproducer txs set'

mkTestKey :: MCPState -> Int -> EchidnaTest -> Text
mkTestKey st idx test =
  let worker = maybe "null" (T.pack . show) test.workerId
  in T.intercalate ":" [st.campaignId, worker, T.pack (show idx), renderTestType test.testType]

inferShrinkStatus :: TestState -> MCPReproducerStatus
inferShrinkStatus Open = MCPReproducerIdle
inferShrinkStatus (Large _) = MCPReproducerActive
inferShrinkStatus (Failed _) = MCPReproducerFailed
inferShrinkStatus _ = MCPReproducerComplete

isFullyShrunk :: TestState -> Bool
isFullyShrunk = \case
  Open -> False
  Large _ -> False
  _ -> True

renderTestState :: TestState -> Text
renderTestState Open = "open"
renderTestState (Large _) = "large"
renderTestState Passed = "passed"
renderTestState Unsolvable = "unsolvable"
renderTestState Solved = "solved"
renderTestState (Failed _) = "failed"

renderTestType :: TestType -> Text
renderTestType = \case
  PropertyTest{} -> "property"
  OptimizationTest{} -> "optimization"
  AssertionTest{} -> "assertion"
  CallTest{} -> "call"
  Exploration -> "exploration"

applyReproducerFilters :: Map Text Text -> [MCPReproducerArtifact] -> [MCPReproducerArtifact]
applyReproducerFilters query = filter passesFilters
  where
    passesFilters artifact =
      all (== True)
        [ matchesState artifact
        , matchesWorker artifact
        , matchesShrink artifact
        , matchesFullyShrunk artifact
        ]
    matchesState artifact =
      case Map.lookup "state" query of
        Nothing -> True
        Just "all" -> True
        Just "unsolved" -> artifact.testState == "unsolvable" || artifact.testState == "unsolved"
        Just "unsolvable" -> artifact.testState == "unsolvable"
        Just filterState' ->
          artifact.testState == T.toLower filterState'
    matchesWorker artifact =
      case Map.lookup "worker" query of
        Nothing -> True
        Just w -> case readMaybe (T.unpack w) of
          Nothing -> False
          Just wid -> artifact.workerId == Just wid
    matchesShrink artifact =
      case Map.lookup "shrink" query of
        Nothing -> True
        Just "all" -> True
        Just statusTxt ->
          case parseReproducerStatus statusTxt of
            Nothing -> False
            Just status -> artifact.shrink.shrinkStatus == status
    matchesFullyShrunk artifact =
      case Map.lookup "fullyShrunk" query of
        Nothing -> True
        Just "any" -> True
        Just b -> parseBool b == artifact.shrink.shrinkFullyShrunk

parseReproducerStatus :: Text -> Maybe MCPReproducerStatus
parseReproducerStatus status =
  case T.toLower status of
    "unknown" -> Just MCPReproducerUnknown
    "idle" -> Just MCPReproducerIdle
    "active" -> Just MCPReproducerActive
    "queued" -> Just MCPReproducerQueued
    "complete" -> Just MCPReproducerComplete
    "failed" -> Just MCPReproducerFailed
    _ -> Nothing

resolveReproducerKey :: MCPState -> Map Text Text -> IO (Either Text Text)
resolveReproducerKey st args = do
  case Map.lookup "testKey" args of
    Just key -> pure $ Right key
    Nothing -> do
      let idxTxt = Map.lookup "testIndex" args
      case idxTxt >>= parseInt of
        Nothing -> pure $ Left "missing testKey or testIndex"
        Just idx -> do
          artifacts <- readIORef st.reproducerArtifacts
          let matches = [ key
                        | (key, art) <- Map.toList artifacts
                        , parseReproducerKeyIndex key == Just idx
                        , maybe True (matchesWorker art) (parseWorkerId =<< Map.lookup "workerId" args)
                        , maybe True (matchesType art) (normalizeTestType . T.toLower <$> Map.lookup "testType" args)
                        ]
          pure $ case matches of
            [key] -> Right key
            [] -> Left "reproducer not found"
            _ -> Left "ambiguous arguments"
  where
    parseInt t = readMaybe (T.unpack t)
    parseWorkerId "null" = Just Nothing
    parseWorkerId "none" = Just Nothing
    parseWorkerId txt = Just <$> parseInt txt
    matchesWorker art = \case
      Just wid -> art.workerId == wid
      Nothing -> True
    matchesType art expected = normalizeTestType art.testType == expected
    normalizeTestType t = normalizeTestTypeText t

    normalizeTestTypeText t =
      case T.stripPrefix "test" t of
        Just rest | T.null rest -> t
        Just rest -> rest
        Nothing ->
          case t of
            "assertion_test" -> "assertion"
            "property_test" -> "property"
            "optimization_test" -> "optimization"
            "call_test" -> "call"
            "exploration_test" -> "exploration"
            _ -> t

trimByUpdatedAt :: Ord k => Int -> (v -> UTCTime) -> Map k v -> Map k v
trimByUpdatedAt limit extractUpdatedAt values
  | limit <= 0 = values
  | Map.size values <= limit = values
  | otherwise =
      let overflow = Map.size values - limit
          orderedByAge = sortOn (extractUpdatedAt . snd) (Map.toList values)
          kept = drop overflow orderedByAge
      in Map.fromList kept

createShrinkJob :: MCPState -> Text -> Bool -> MCPReproducerJobPriority -> Maybe Text -> UTCTime -> IO Text
createShrinkJob st testKey force priority workerHint now = do
  jobId <- atomicModifyIORef' st.reproducerNextJobId $ \n ->
    let idx = n + 1
    in (idx, T.pack (show idx))
  let job = MCPReproducerJob
        { jobId = "job-" <> jobId
        , testKey = testKey
        , status = MCPReproducerJobQueued
        , priority = priority
        , retries = 0
        , workerHint = workerHint
        , createdAt = now
        , updatedAt = now
        , force = force
        , reason = Nothing
        , lastError = Nothing
        }
  atomicModifyIORef' st.reproducerJobs $ \jobs ->
    let jobs' = trimByUpdatedAt st.maxReproducerArtifacts jobUpdatedAt (Map.insert job.jobId job jobs)
    in (jobs', ())
  pure job.jobId

updateExistingJob :: MCPState -> Text -> MCPReproducerJobPriority -> Maybe Text -> UTCTime -> IO ()
updateExistingJob MCPState{reproducerJobs = jobsRef, maxReproducerArtifacts = maxArtifacts} testKey priority workerHint now = do
  atomicModifyIORef' jobsRef $ \jobs ->
    let
      updateTestJob job
        | job.testKey /= testKey = job
        | job.status `elem` [MCPReproducerJobComplete, MCPReproducerJobFailed, MCPReproducerJobCanceled] = job
        | otherwise =
            job
              { status = MCPReproducerJobQueued
              , priority = max job.priority priority
              , workerHint = case workerHint of
                  Just hint -> Just hint
                  Nothing -> job.workerHint
              , updatedAt = now
              , reason = Nothing
              }
      jobs' = trimByUpdatedAt maxArtifacts jobUpdatedAt (Map.map updateTestJob jobs)
    in (jobs', ())

syncJobsForTest :: MCPState -> Text -> MCPReproducerArtifact -> UTCTime -> IO ()
syncJobsForTest st key artifact now = do
  atomicModifyIORef' st.reproducerJobs $ \jobs ->
    let jobs' = Map.mapWithKey (updateJobStatus key artifact now) jobs
        jobs'' = trimByUpdatedAt st.maxReproducerArtifacts jobUpdatedAt jobs'
    in (jobs'', ())

updateJobStatus :: Text -> MCPReproducerArtifact -> UTCTime -> Text -> MCPReproducerJob -> MCPReproducerJob
updateJobStatus key artifact now _ job =
  if job.testKey /= key
    then job
    else case (artifact.shrink.shrinkStatus, job.status) of
      (MCPReproducerComplete, MCPReproducerJobQueued) ->
        job { status = MCPReproducerJobComplete, updatedAt = now, reason = Just "complete" }
      (MCPReproducerComplete, MCPReproducerJobActive) ->
        job { status = MCPReproducerJobComplete, updatedAt = now, reason = Just "complete" }
      (MCPReproducerFailed, s)
        | s `elem` [MCPReproducerJobQueued, MCPReproducerJobActive] ->
          job { status = MCPReproducerJobFailed, updatedAt = now, reason = Just "failed" }
      (_, MCPReproducerJobQueued) | artifact.shrink.shrinkStatus == MCPReproducerActive ->
        job { status = MCPReproducerJobActive, updatedAt = now }
      _ -> job

purgeExpiredReproducers :: MCPState -> UTCTime -> IO ()
purgeExpiredReproducers st purgeNow =
  unless (st.reproducerResultTTLMinutes <= 0) $ do
    staleKeys <- atomicModifyIORef' st.reproducerArtifacts $ \artifacts ->
      let (artifacts', stale) = Map.partition (not . isExpired purgeNow) artifacts
          staleKeys = Map.keys stale
      in (artifacts', staleKeys)
    unless (null staleKeys) $
      atomicModifyIORef' st.reproducerJobs $ \jobs ->
        let staleSet = Map.fromList $ zip staleKeys (repeat ())
            jobs' = Map.filterWithKey (\_ job -> Map.notMember job.testKey staleSet) jobs
        in (jobs', ())
  where
    isExpired ts artifact = ts > addUTCTime (fromIntegral $ st.reproducerResultTTLMinutes * 60 * (-1)) artifact.updatedAt

getReproducerArtifact :: MCPState -> UTCTime -> Text -> IO ReproducerLookup
getReproducerArtifact st now key = do
  artifacts <- readIORef st.reproducerArtifacts
  case Map.lookup key artifacts of
    Nothing -> pure ReproducerMissing
    Just artifact | isExpired now artifact -> do
      _ <- atomicModifyIORef' st.reproducerArtifacts $ \as -> (Map.delete key as, ())
      pure $ ReproducerStale (truncate $ max 0 (diffUTCTime now artifact.updatedAt))
    Just artifact -> pure $ ReproducerFound artifact
  where
    isExpired ts artifact
      | st.reproducerResultTTLMinutes <= 0 = False
      | otherwise = addUTCTime (fromIntegral (st.reproducerResultTTLMinutes * 60 * (-1)) ) artifact.updatedAt < ts

emitReproducerEvent :: MCPState -> Text -> Text -> Value -> IO ()
emitReproducerEvent st etype key payload = do
  now <- getTimestamp
  _ <- pushRing st.reproducerEvents $ \eventId -> MCPReproducerEvent
    { reproducerEventId = eventId
    , reproducerEventTs = formatTimestamp now
    , reproducerEventType = etype
    , reproducerEventKey = key
    , reproducerEventTestKey = key
    , reproducerEventPayload = payload
    }
  pure ()

parseJobPriority :: Maybe Text -> MCPReproducerJobPriority
parseJobPriority = \case
  Just "low" -> MCPReproducerPriorityLow
  Just "high" -> MCPReproducerPriorityHigh
  Just "normal" -> MCPReproducerPriorityNormal
  _ -> MCPReproducerPriorityNormal

readQueryBool :: Text -> Bool -> Map Text Text -> Bool
readQueryBool key def q =
  maybe def parseBool (Map.lookup key q)

parseBool :: Text -> Bool
parseBool t =
  case T.toLower t of
    "true" -> True
    "1" -> True
    "yes" -> True
    _ -> False

argsToQuery :: Maybe Value -> Map Text Text
argsToQuery = \case
  Just (Object o) ->
    Map.fromList $ map toPair $ KM.toList o
  _ -> mempty
  where
    toPair (k,v) = (K.toText k, queryValueText v)

queryValueText :: Value -> Text
queryValueText = \case
  String t -> t
  Number n -> T.pack (show n)
  Bool b -> if b then "true" else "false"
  Null -> "null"
  _ -> ""

parseReproducerKeyIndex :: Text -> Maybe Int
parseReproducerKeyIndex key = do
  let parts = T.splitOn ":" key
  idxPart <- case parts of
    (_ : _ : idx : _) -> Just idx
    _ -> Nothing
  parseInt idxPart
  where
    parseInt t = readMaybe (T.unpack t)

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
