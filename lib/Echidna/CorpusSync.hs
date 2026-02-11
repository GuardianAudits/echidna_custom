{-# LANGUAGE RecordWildCards #-}

module Echidna.CorpusSync
  ( CorpusSyncHandle(..)
  , startCorpusSync
  ) where

import Control.Concurrent (forkFinally, threadDelay)
import Control.Concurrent.Chan (Chan, dupChan, readChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TBQueue
  ( TBQueue
  , isFullTBQueue
  , newTBQueueIO
  , writeTBQueue
  , tryReadTBQueue
  )
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, replicateM_, unless, void, when)
import Data.Aeson (FromJSON(..), Value(..), encode, object, withObject, (.:?), (.!=), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), (<.>))
import Data.Word (Word32)

import Network.WebSockets (ClientApp, receiveData, sendClose, sendTextData)
import Network.WebSockets qualified as WS
import Network.Socket (PortNumber)
import Wuss qualified

import EVM.Types hiding (Env, Origin, Failure)

import Echidna.CorpusSync.Hash (computeCampaignFingerprint, entryIdForTxs, sha256Hex)
import Echidna.CorpusSync.Protocol
  ( Envelope(..)
  , decodeEnvelope
  , encodeEnvelope
  , mkCorpusGet
  , mkCorpusPublish
  , mkCorpusPublishBatch
  , mkCorpusSinceRequest
  , mkFailurePublish
  , mkHello
  , newMsgId
  , CorpusAnnounce(..)
  , CorpusEntry(..)
  , CorpusSince(..)
  , CorpusSinceItem(..)
  , EntryMeta(..)
  , EntryType(..)
  , FleetStop(..)
  , Origin(..)
  )
import Echidna.Worker (getNWorkers)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config
  ( CorpusSyncConf(..)
  , CorpusSyncBehaviorConf(..)
  , CorpusSyncIngestConf(..)
  , CorpusSyncPublishConf(..)
  , CorpusSyncValidate(..)
  , CorpusSyncWeightPolicy(..)
  , EConfig(..)
  , Env(..)
  )
import Echidna.Types.Test (EchidnaTest(..), TestType(..), TestState(..))
import Echidna.Types.Tx (Tx(..), TxCall(..))
import Echidna.Types.Worker
  ( CampaignEvent(..)
  , WorkerEvent(..)
  , WorkerType(..)
  )
import Echidna.Worker (pushCampaignEvent)

data CorpusSyncHandle = CorpusSyncHandle
  { stop :: IO ()
  , wait :: IO ()
  }

-- stm's TBQueue doesn't expose a tryWrite helper in all versions.
tryWriteTBQueue :: TBQueue a -> a -> STM Bool
tryWriteTBQueue q a = do
  full <- isFullTBQueue q
  if full
    then pure False
    else writeTBQueue q a >> pure True

data Outbound
  = OutHello
  | OutCorpusPublish EntryMeta [Tx]
  | OutCorpusSinceRequest Int Int -- since_seq, limit
  | OutCorpusGet Text
  | OutFailurePublish Text Text EntryMeta [Tx] -- failure_id, test_name, repro meta, repro txs

-- | Start distributed corpus sync (if enabled).
--
-- The callback is used to stop local workers when the hub broadcasts `fleet_stop`.
startCorpusSync
  :: Env
  -> VM Concrete
  -> Maybe Text -- ^ selected contract
  -> IO () -- ^ stopWorkers callback (graceful enough for v1)
  -> IO (Maybe CorpusSyncHandle)
startCorpusSync env vm selectedContract stopWorkers = do
  let csConf = env.cfg.corpusSyncConf
  if not csConf.enabled
    then pure Nothing
    else do
      instanceId <- newMsgId

      let campaign =
            case csConf.campaignOverride of
              Just v -> v
              Nothing -> computeCampaignFingerprint env selectedContract

      stopFlag <- newIORef False
      lastSeqRef <- newIORef (0 :: Int)
      publishedFailureRef <- newIORef False

      -- Entry ID dedup and in-flight tracking.
      knownIdsRef <- newIORef Set.empty
      pendingGetsRef <- newIORef Set.empty
      publishedIdsRef <- newIORef Set.empty

      -- Outbound queue is bounded to avoid stalling the campaign.
      let maxPending :: Natural
          maxPending = fromIntegral (max 100 csConf.ingest.maxPending)
      outQ <- newTBQueueIO maxPending

      -- Signal when threads exit.
      listenerDone <- newEmptyMVar
      connDone <- newEmptyMVar

      -- Event listener: publish achievements and stop when all workers stop.
      _listenerTid <- forkFinally
        (campaignEventLoop env stopFlag outQ instanceId campaign publishedIdsRef publishedFailureRef)
        (const $ putMVar listenerDone ())

      -- Connection manager: reconnect loop + inbound ingestion.
      _connTid <- forkFinally
        (connectionLoop env vm stopWorkers stopFlag lastSeqRef publishedFailureRef knownIdsRef pendingGetsRef outQ instanceId campaign)
        (const $ putMVar connDone ())

      let stopAction = do
            writeIORef stopFlag True
            pure ()

          waitAction = do
            takeMVar listenerDone
            takeMVar connDone

      pure $ Just CorpusSyncHandle { stop = stopAction, wait = waitAction }

-- | Read campaign events and enqueue outbound sync messages.
campaignEventLoop
  :: Env
  -> IORef Bool
  -> TBQueue Outbound
  -> Text -- ^ instance_id
  -> Text -- ^ campaign fingerprint
  -> IORef (Set.Set Text) -- ^ published entry ids
  -> IORef Bool -- ^ published failure
  -> IO ()
campaignEventLoop env stopFlag outQ instanceId _campaign publishedIdsRef publishedFailureRef = do
  let nworkers = getNWorkers env.cfg.campaignConf
  chan <- dupChan env.eventQueue
  loop chan nworkers
  where
    loop :: Chan (a, CampaignEvent) -> Int -> IO ()
    loop _ 0 = writeIORef stopFlag True
    loop chan alive = do
      shouldStop <- readIORef stopFlag
      unless shouldStop $ do
        (_ts, ev) <- readChan chan
        case ev of
          WorkerEvent wid wtype wev -> do
            handleWorkerEvent wid wtype wev
            case wev of
              WorkerStopped _ -> loop chan (alive - 1)
              _ -> loop chan alive
          _ -> loop chan alive

    handleWorkerEvent wid wtype = \case
      NewCoverage{..} -> do
        when env.cfg.corpusSyncConf.publish.coverage $ do
          let txs = transactions
          unless (null txs) $ do
            let entryId = entryIdForTxs txs
            shouldPublish <- atomicModifyIORef' publishedIdsRef $ \s ->
              if Set.member entryId s then (s, False) else (Set.insert entryId s, True)
            when shouldPublish $ do
              let encodedTxs = encode txs
                  bytesLen :: Int
                  bytesLen = fromIntegral (LBS.length encodedTxs)
                  maxBytes = env.cfg.corpusSyncConf.publish.maxEntryBytes
              when (bytesLen <= maxBytes) $ do
                let meta = EntryMeta
                      { entryId = entryId
                      , entryType = EntryCoverage
                      , encoding = "json"
                      , compressed = "none"
                      , txCount = length txs
                      , bytes = bytesLen
                      , origin = Origin
                          { instanceId = instanceId
                          , workerId = Just wid
                          , workerType = Just $ case wtype of
                              FuzzWorker -> "fuzz"
                              SymbolicWorker -> "symbolic"
                          }
                      , hints = Just $ object
                          [ "coverage_points_total" .= points
                          , "num_codehashes" .= numCodehashes
                          , "corpus_size" .= corpusSize
                          ]
                      }
                enqueueLowPriority outQ (OutCorpusPublish meta txs)

      TestFalsified test -> do
        when env.cfg.corpusSyncConf.publish.failures $ do
          let txs = test.reproducer
          unless (null txs) $ do
            let entryId = entryIdForTxs txs
            let encodedTxs = encode txs
                bytesLen :: Int
                bytesLen = fromIntegral (LBS.length encodedTxs)
                maxBytes = env.cfg.corpusSyncConf.publish.maxEntryBytes
            when (bytesLen <= maxBytes) $ do
              let testName = testNameText test
                  failureId = sha256Hex (encode (testName <> ":" <> entryId))
                  meta = EntryMeta
                    { entryId = entryId
                    , entryType = EntryReproducer
                    , encoding = "json"
                    , compressed = "none"
                    , txCount = length txs
                    , bytes = bytesLen
                    , origin = Origin { instanceId = instanceId, workerId = Just wid, workerType = Just "fuzz" }
                    , hints = Just $ object ["test_name" .= testName]
                    }
              writeIORef publishedFailureRef True
              enqueueHighPriority outQ (OutFailurePublish failureId testName meta txs)

      _ -> pure ()

    testNameText :: EchidnaTest -> Text
    testNameText EchidnaTest{testType} =
      case testType of
        PropertyTest n _ -> n
        OptimizationTest n _ -> n
        AssertionTest _ sig _ -> T.pack (show sig)
        CallTest n _ -> n
        Exploration -> "exploration"

    enqueueLowPriority q msg = do
      -- Drop if full.
      atomically $ void $ tryWriteTBQueue q msg

    enqueueHighPriority q msg = atomically $ do
      full <- isFullTBQueue q
      when full $ do
        _ <- tryReadTBQueue q
        pure ()
      void $ tryWriteTBQueue q msg

-- | Connection lifecycle and inbound ingestion.
connectionLoop
  :: Env
  -> VM Concrete
  -> IO ()
  -> IORef Bool
  -> IORef Int
  -> IORef Bool
  -> IORef (Set.Set Text)
  -> IORef (Set.Set Text)
  -> TBQueue Outbound
  -> Text
  -> Text
  -> IO ()
connectionLoop env vm stopWorkers stopFlag lastSeqRef publishedFailureRef knownIdsRef pendingGetsRef outQ instanceId campaign = do
  -- Backoff is configurable; if empty, fall back to a sensible default.
  let backoffs = case env.cfg.corpusSyncConf.behavior.reconnectBackoffMs of
        [] -> [250, 500, 1000, 2000, 5000, 10000]
        xs -> xs
  go 0 backoffs
  where
    go :: Int -> [Int] -> IO ()
    go _ [] = go 0 [10000]
    go n (ms:rest) = do
      shouldStop <- readIORef stopFlag
      unless shouldStop $ do
        let url = env.cfg.corpusSyncConf.url
        case parseWsUrl url of
          Left err -> do
            pushCampaignEvent env (Failure $ "corpusSync: invalid url: " <> err)
            writeIORef stopFlag True
          Right (secure, host, port, path) -> do
            let clientApp :: ClientApp ()
                clientApp conn = do
                  runSession conn
            let runClient =
                  if secure
                    then Wuss.runSecureClient host (fromIntegral port :: PortNumber) path clientApp
                    else WS.runClient host port path clientApp
            runClient `catch` \(e :: SomeException) -> do
              pushCampaignEvent env (Failure $ "corpusSync: connection error: " <> show e)
              pure ()
            -- If we get here without stopFlag, connection ended; reconnect.
            shouldStopAfter <- readIORef stopFlag
            unless shouldStopAfter $ do
              threadDelay (ms * 1000)
              go (n + 1) rest

    runSession conn = do
      -- Hub feature flags (filled on welcome).
      supportsBatchRef <- newIORef False
      resumeSentRef <- newIORef False

      -- Token bucket for inbound coverage ingestion.
      ingestTokensRef <- newIORef (max 0 env.cfg.corpusSyncConf.ingest.maxPerMinute)
      ingestLastRefillRef <- newIORef =<< getPOSIXTime

      let takeIngestToken :: IO Bool
          takeIngestToken = do
            let perMinute = env.cfg.corpusSyncConf.ingest.maxPerMinute
            if perMinute <= 0
              then pure False
              else do
                now <- getPOSIXTime
                lastT <- readIORef ingestLastRefillRef
                tok <- readIORef ingestTokensRef
                let dt = realToFrac (now - lastT) :: Double
                    refillRate = (fromIntegral perMinute :: Double) / 60.0
                    add = floor (dt * refillRate)
                    tok' = min perMinute (tok + add)
                when (add > 0) $ do
                  writeIORef ingestTokensRef tok'
                  writeIORef ingestLastRefillRef now
                tok2 <- readIORef ingestTokensRef
                if tok2 > 0
                  then writeIORef ingestTokensRef (tok2 - 1) >> pure True
                  else pure False

      -- Send hello.
      sinceSeq <- if env.cfg.corpusSyncConf.behavior.resume
        then Just <$> readIORef lastSeqRef
        else pure Nothing
      hello <- mkHello campaign instanceId "unknown" sinceSeq env.cfg.corpusSyncConf.token
      sendTextData conn (encodeEnvelope hello)

      -- If we reconnect mid-flight, re-request any entries that were pending.
      -- The hub is content-addressed so duplicate GETs are cheap and idempotent.
      pending <- readIORef pendingGetsRef
      forM_ (Set.toList pending) $ \eid ->
        atomically $ void $ tryWriteTBQueue outQ (OutCorpusGet eid)

      -- Spawn writer thread. Reader loop runs on this thread.
      writerStop <- newIORef False
      _writerTid <- forkFinally (writerLoop conn writerStop supportsBatchRef) (const $ writeIORef writerStop True)

      let cleanup = do
            writeIORef writerStop True
            -- best-effort close
            (sendClose conn ("bye" :: Text)) `catch` \(_ :: SomeException) -> pure ()

      readerLoop conn cleanup supportsBatchRef resumeSentRef takeIngestToken `catch` \(e :: SomeException) -> do
        cleanup
        pushCampaignEvent env (Failure $ "corpusSync: reader error: " <> show e)
        -- bubble up to reconnect
        fail (show e)

    writerLoop conn writerStop supportsBatchRef = do
      -- Token bucket for coverage publishes.
      let rate = max 1 env.cfg.corpusSyncConf.publish.maxPerSecond
      let burst = max 1 env.cfg.corpusSyncConf.publish.burst
      tokensRef <- newIORef burst
      lastRefillRef <- newIORef =<< getPOSIXTime

      let waitToken = do
            now <- getPOSIXTime
            lastT <- readIORef lastRefillRef
            tok <- readIORef tokensRef
            let dt = realToFrac (now - lastT) :: Double
                add = floor (dt * fromIntegral rate)
                tok' = min burst (tok + add)
            when (add > 0) $ do
              writeIORef tokensRef tok'
              writeIORef lastRefillRef now
            tok2 <- readIORef tokensRef
            if tok2 > 0
              then writeIORef tokensRef (tok2 - 1)
              else threadDelay 100_000 >> waitToken

      let sendOutbound = \case
            OutHello -> pure ()
            OutCorpusPublish meta txs -> do
              -- Rate limit coverage publishes only.
              waitToken
              msg <- mkCorpusPublish campaign meta txs
              sendTextData conn (encodeEnvelope msg)
            OutCorpusSinceRequest sinceSeq limit -> do
              msg <- mkCorpusSinceRequest campaign sinceSeq limit
              sendTextData conn (encodeEnvelope msg)
            OutCorpusGet eid -> do
              msg <- mkCorpusGet campaign eid
              sendTextData conn (encodeEnvelope msg)
            OutFailurePublish failureId testName reproMeta reproTxs -> do
              msg <- mkFailurePublish campaign instanceId failureId testName reproMeta reproTxs
              sendTextData conn (encodeEnvelope msg)

      let loop = do
            stopped <- readIORef writerStop
            shouldStop <- readIORef stopFlag
            if stopped
              then pure ()
              else if shouldStop
                then (sendClose conn ("bye" :: Text)) `catch` \(_ :: SomeException) -> pure ()
                else do
                  m <- atomically (tryReadTBQueue outQ)
                  case m of
                    Nothing -> threadDelay 100_000 >> loop
                    Just msg0 ->
                      case msg0 of
                        OutCorpusPublish meta0 txs0 -> do
                          let batchSize = max 1 env.cfg.corpusSyncConf.publish.batchSize
                          supportsBatch <- readIORef supportsBatchRef
                          if (not supportsBatch) || batchSize <= 1
                            then sendOutbound msg0 >> loop
                            else do
                              (more, leftover) <- atomically $ drainBatch (batchSize - 1) []
                              let items = reverse ((meta0, txs0) : more)
                              -- Consume rate tokens per entry.
                              replicateM_ (length items) waitToken
                              msg <- mkCorpusPublishBatch campaign items
                              sendTextData conn (encodeEnvelope msg)

                              -- Preserve ordering if we consumed a non-publish message.
                              forM_ leftover sendOutbound
                              loop

                        _ -> sendOutbound msg0 >> loop
      loop
      where
        -- Drain up to n additional OutCorpusPublish messages. If we read a non-publish
        -- message, keep it as a leftover to be sent after the batch.
        drainBatch :: Int -> [(EntryMeta, [Tx])] -> STM ([(EntryMeta, [Tx])], Maybe Outbound)
        drainBatch 0 acc = pure (acc, Nothing)
        drainBatch n acc = do
          m <- tryReadTBQueue outQ
          case m of
            Nothing -> pure (acc, Nothing)
            Just (OutCorpusPublish m' txs') -> drainBatch (n - 1) ((m', txs') : acc)
            Just other -> pure (acc, Just other)

    readerLoop conn cleanup supportsBatchRef resumeSentRef takeIngestToken = do
      shouldStop <- readIORef stopFlag
      unless shouldStop $ do
        raw <- receiveData conn
        case decodeEnvelope raw of
          Left _err ->
            readerLoop conn cleanup supportsBatchRef resumeSentRef takeIngestToken
          Right Envelope{msgType, msgId, payload} -> do
            handleInbound msgType msgId payload
            readerLoop conn cleanup supportsBatchRef resumeSentRef takeIngestToken
      where
        enqueueHighPriority :: Outbound -> IO ()
        enqueueHighPriority msg = atomically $ do
          full <- isFullTBQueue outQ
          when full $ do
            _ <- tryReadTBQueue outQ
            pure ()
          void $ tryWriteTBQueue outQ msg

        handleInbound :: Text -> Maybe Text -> Value -> IO ()
        handleInbound typ _msgId payload = case typ of
          "welcome" -> do
            -- Feature discovery (best-effort).
            case parseEither parseWelcome payload of
              Left _ -> pure ()
              Right supportsBatch -> writeIORef supportsBatchRef supportsBatch

            -- Kick off resume paging once per connection.
            when env.cfg.corpusSyncConf.behavior.resume $ do
              already <- readIORef resumeSentRef
              unless already $ do
                since <- readIORef lastSeqRef
                let limit = 1000
                enqueueHighPriority (OutCorpusSinceRequest since limit)
                writeIORef resumeSentRef True

          "corpus_announce" -> do
            case parseEither parseJSON payload of
              Left _ -> pure ()
              Right CorpusAnnounce{..} -> do
                writeIORef lastSeqRef seqNum
                handleAnnounce entry

          "corpus_since" -> do
            case parseEither parseJSON payload of
              Left _ -> pure ()
              Right CorpusSince{toSeq, entries, truncated} -> do
                writeIORef lastSeqRef toSeq
                forM_ entries $ \CorpusSinceItem{sinceEntry} -> handleAnnounce sinceEntry
                when truncated $ do
                  let limit = 1000
                  enqueueHighPriority (OutCorpusSinceRequest toSeq limit)

          "corpus_entry" -> do
            case parseEither parseJSON payload of
              Left _ -> pure ()
              Right CorpusEntry{..} -> do
                atomicModifyIORef' pendingGetsRef (\s -> (Set.delete entryMeta.entryId s, ()))
                ingestEntry entryMeta txs

          "fleet_stop" -> do
            case parseEither parseJSON payload of
              Left _ -> pure ()
              Right FleetStop{} -> do
                when env.cfg.corpusSyncConf.behavior.stopOnFleetStop $ do
                  origin <- readIORef publishedFailureRef
                  if origin
                    then void $ forkFinally (waitForShrinkThenStop env stopWorkers stopFlag) (const $ pure ())
                    else stopWorkers

          _ -> pure ()

        parseWelcome = withObject "welcome.payload" $ \o -> do
          feat <- o .:? "features"
          case feat of
            Nothing -> pure False
            Just v -> withObject "features" (\f -> f .:? "supports_batch" .!= False) v

        handleAnnounce :: EntryMeta -> IO ()
        handleAnnounce meta = do
          let maxBytes = env.cfg.corpusSyncConf.publish.maxEntryBytes
              maxPending = max 1 env.cfg.corpusSyncConf.ingest.maxPending
          when (env.cfg.corpusSyncConf.ingest.enabled && meta.bytes <= maxBytes) $ do
            allowType <- case meta.entryType of
              EntryReproducer -> pure True
              EntryCoverage -> takeIngestToken
            when allowType $ do
              shouldIngest <- shouldIngestMeta env.cfg.corpusSyncConf.ingest instanceId meta
              when shouldIngest $ do
                alreadyKnown <- atomicModifyIORef' knownIdsRef $ \s ->
                  if Set.member meta.entryId s then (s, True) else (s, False)
                unless alreadyKnown $ do
                  pendingSz <- Set.size <$> readIORef pendingGetsRef
                  when (meta.entryType == EntryReproducer || pendingSz < maxPending) $ do
                    alreadyPending <- atomicModifyIORef' pendingGetsRef $ \s ->
                      if Set.member meta.entryId s then (s, True) else (Set.insert meta.entryId s, False)
                    unless alreadyPending $ do
                      let msg = OutCorpusGet meta.entryId
                      case meta.entryType of
                        EntryReproducer -> enqueueHighPriority msg
                        EntryCoverage -> atomically $ void $ tryWriteTBQueue outQ msg

    shouldIngestMeta :: CorpusSyncIngestConf -> Text -> EntryMeta -> IO Bool
    shouldIngestMeta CorpusSyncIngestConf{sampleRate} inst meta =
      case meta.entryType of
        EntryReproducer -> pure True
        EntryCoverage ->
          if sampleRate >= 1.0 then pure True
          else if sampleRate <= 0.0 then pure False
          else do
            let h = sha256Hex (encode (inst <> ":" <> meta.entryId))
            pure $ (hexToUnit h) < sampleRate

    hexToUnit :: Text -> Double
    hexToUnit h =
      -- Take 8 hex chars for a 32-bit bucket.
      let s = T.take 8 h
          n = foldl (\acc c -> acc * 16 + fromIntegral (hexDigit c)) (0 :: Int) (T.unpack s)
      in fromIntegral n / fromIntegral (maxBound :: Word32)
      where
        hexDigit c
          | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
          | c >= 'a' && c <= 'f' = 10 + (fromEnum c - fromEnum 'a')
          | c >= 'A' && c <= 'F' = 10 + (fromEnum c - fromEnum 'A')
          | otherwise = 0

    ingestEntry :: EntryMeta -> [Tx] -> IO ()
    ingestEntry meta txs = do
      -- Verify hash matches.
      let computed = entryIdForTxs txs
      if computed /= meta.entryId
        then pushCampaignEvent env (Failure "corpusSync: entry_id mismatch (dropped)")
        else do
          let maxBytes = env.cfg.corpusSyncConf.publish.maxEntryBytes
          let bytesLen :: Int
              bytesLen = fromIntegral (LBS.length (encode txs))
          if bytesLen > maxBytes
            then pure ()
            else do
              ok <- validateIngest env.cfg.corpusSyncConf.ingest.validate vm txs
              when ok $ do
                inserted <- atomicModifyIORef' knownIdsRef $ \s ->
                  if Set.member meta.entryId s then (s, False) else (Set.insert meta.entryId s, True)
                when inserted $ do
                  admitToCorpus env meta txs

-- | Admission validation for inbound entries.
validateIngest :: CorpusSyncValidate -> VM Concrete -> [Tx] -> IO Bool
validateIngest mode vm txs =
  case mode of
    CorpusSyncValidateNone -> pure True
    CorpusSyncValidateReplay -> pure (replayValidate vm txs)
    CorpusSyncValidateExecute -> pure (replayValidate vm txs) -- v1: same as replay
  where
    replayValidate vm0 txs0 =
      let deployed = Map.keys vm0.env.contracts
          isRelevant Tx{call=NoCall} = False
          isRelevant _ = True
      in all (\tx -> not (isRelevant tx) || LitAddr tx.dst `elem` deployed) txs0

-- | Insert into the in-memory corpus and persist to disk if corpusDir is set.
admitToCorpus :: Env -> EntryMeta -> [Tx] -> IO ()
admitToCorpus env meta txs = do
  let w = case env.cfg.corpusSyncConf.ingest.weightPolicy of
        CorpusSyncWeightConstant -> env.cfg.corpusSyncConf.ingest.constantWeight
        _ -> env.cfg.corpusSyncConf.ingest.constantWeight

  atomicModifyIORef' env.corpusRef $ \corp ->
    let corp' = Set.insert (w, txs) corp
    in (corp', ())

  case env.cfg.campaignConf.corpusDir of
    Nothing -> pure ()
    Just dir -> do
      let outDir = dir </> "coverage"
      createDirectoryIfMissing True outDir
      let file = outDir </> T.unpack meta.entryId <.> "txt"
      exists <- doesFileExist file
      unless exists $ do
        LBS.writeFile file (encode txs)
        pushCampaignEvent env (ReproducerSaved file)

-- | Origin instances delay stop until shrink is done.
waitForShrinkThenStop :: Env -> IO () -> IORef Bool -> IO ()
waitForShrinkThenStop env stopWorkers stopFlag = do
  let loop = do
        shouldStop <- readIORef stopFlag
        unless shouldStop $ do
          tests <- traverse readIORef env.testRefs
          let shrinking = any (\t -> case t.state of Large _ -> True; _ -> False) tests
          if shrinking
            then threadDelay 250_000 >> loop
            else stopWorkers
  loop

-- | Parse ws:// or wss:// URL into (secure, host, port, path).
parseWsUrl :: Text -> Either String (Bool, String, Int, String)
parseWsUrl t =
  case () of
    _ | Just rest <- T.stripPrefix "ws://" t -> parse False rest 80
      | Just rest <- T.stripPrefix "wss://" t -> parse True rest 443
      | otherwise -> Left "expected ws:// or wss://"
  where
    parse secure rest defaultPort =
      let (hostPort, path0) = T.breakOn "/" rest
          path = if T.null path0 then "/" else T.unpack path0
          (host, port) =
            case T.breakOn ":" hostPort of
              (h, p) | T.null p -> (T.unpack h, defaultPort)
              (h, p) ->
                case reads (T.unpack (T.drop 1 p)) of
                  [(n, "")] -> (T.unpack h, n)
                  _ -> (T.unpack h, defaultPort)
      in if null host then Left "missing host" else Right (secure, host, port, path)
