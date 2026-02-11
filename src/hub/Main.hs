{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Concurrent (forkFinally, forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  , orElse
  )
import Control.Concurrent.STM.TBQueue
  ( TBQueue
  , isFullTBQueue
  , newTBQueueIO
  , readTBQueue
  , tryReadTBQueue
  , writeTBQueue
  )
import Control.Exception (SomeException, catch, displayException)
import Control.Monad (forM, forM_, forever, unless, void, when)
import Control.Applicative (optional)
import Data.Aeson
  ( FromJSON(..)
  , Value(..)
  , eitherDecode
  , eitherDecodeStrict'
  , encode
  , object
  , toJSON
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  , (.=)
  )
import Data.Aeson.Types (parseEither)
import Data.Aeson.Key (fromText)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Char (toLower)
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Options.Applicative
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath ((</>), (<.>), takeFileName)
import System.IO (IOMode(ReadMode), hIsEOF, withFile)
import System.IO qualified as IO

import Network.WebSockets
  ( Connection
  , PendingConnection
  , acceptRequest
  , receiveData
  , runServer
  , sendClose
  , sendTextData
  )

import Echidna.CorpusSync.Hash (entryIdForTxs)
import Echidna.CorpusSync.Protocol
  ( Envelope(..)
  , decodeEnvelope
  , encodeEnvelope
  , EntryMeta(..)
  , EntryType(..)
  )
import Echidna.Types.Tx (Tx)

data LogFormat = LogText | LogJson deriving (Show, Eq)

instance Read LogFormat where
  readsPrec _ s =
    let norm = map toLower s
    in case norm of
      "text" -> [(LogText, "")]
      "json" -> [(LogJson, "")]
      _ -> []

data HubOptions = HubOptions
  { host :: String
  , port :: Int
  , dataDir :: FilePath
  , tokens :: [Text]
  , noAuth :: Bool
  , maxMsgBytes :: Int
  , maxEntryBytes :: Int
  , broadcastFleetStopOnFailure :: Bool
  , statsIntervalMs :: Int
  , logFormat :: LogFormat
  , statsFile :: Maybe FilePath
  , payloadCacheMb :: Int
  , maxInflightGets :: Int
  , maxPublishesPerMinute :: Int
  , maxCoverageEntries :: Int
  } deriving (Show, Eq)

optsParser :: ParserInfo HubOptions
optsParser = info (helper <*> options) $ fullDesc
  <> progDesc "Echidna distributed corpus sync hub (WebSocket server)"
  <> header "echidna-corpus-hub"

options :: Parser HubOptions
options =
  HubOptions
    <$> strOption
          ( long "host"
         <> metavar "HOST"
         <> value "0.0.0.0"
         <> help "Listen host (default: 0.0.0.0)"
          )
    <*> option auto
          ( long "port"
         <> metavar "PORT"
         <> value 9010
         <> help "Listen port (default: 9010)"
          )
    <*> strOption
          ( long "data-dir"
         <> metavar "PATH"
         <> value "./hub_data"
         <> help "Hub data directory (default: ./hub_data)"
          )
    <*> many
          ( option (T.pack <$> str)
              ( long "token"
             <> metavar "TOKEN"
             <> help "Allowed bearer token (can be repeated)."
              )
          )
    <*> switch (long "no-auth" <> help "Disable auth (accept all clients).")
    <*> option auto
          ( long "max-msg-bytes"
         <> metavar "N"
         <> value 1048576
         <> help "Max incoming message size (bytes)."
          )
    <*> option auto
          ( long "max-entry-bytes"
         <> metavar "N"
         <> value 262144
         <> help "Max corpus entry size (bytes)."
          )
    <*> switch
          ( long "broadcast-fleet-stop"
         <> help "Broadcast fleet_stop on first failure_publish (default: false)."
          )
    <*> option auto
          ( long "stats-interval-ms"
         <> metavar "N"
         <> value 10000
         <> help "Periodic stats log interval in ms (0 disables)."
          )
    <*> option auto
          ( long "log-format"
         <> metavar "text|json"
         <> value LogText
         <> help "Log format for stdout (default: text)."
          )
    <*> optional
          ( strOption
              ( long "stats-file"
             <> metavar "PATH"
             <> help "Write periodic stats JSON to this file."
              )
          )
    <*> option auto
          ( long "payload-cache-mb"
         <> metavar "N"
         <> value 128
         <> help "Payload cache size in MB (0 disables)."
          )
    <*> option auto
          ( long "max-inflight-gets"
         <> metavar "N"
         <> value 2000
         <> help "Per-connection max queued corpus_get requests (backpressure)."
          )
    <*> option auto
          ( long "max-publishes-per-minute"
         <> metavar "N"
         <> value 0
         <> help "Per-connection max corpus_publish items/minute (0 disables)."
          )
    <*> option auto
          ( long "max-coverage-entries"
         <> metavar "N"
         <> value 0
         <> help "Cap coverage entries per campaign (0 disables). Reproducers are always accepted."
          )

data Counters = Counters
  { inMsgs :: !Int
  , outMsgs :: !Int
  , inBytes :: !Int
  , outBytes :: !Int
  , errs :: !Int
  , accepted :: !Int
  , deduped :: !Int
  , rejected :: !Int
  , getsReq :: !Int
  , getsServed :: !Int
  , notFound :: !Int
  , truncatedSince :: !Int
  , failures :: !Int
  , fleetStops :: !Int
  , droppedBroadcast :: !Int
  , publishRateLimited :: !Int
  } deriving (Show, Eq)

emptyCounters :: Counters
emptyCounters = Counters 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

data PayloadCache = PayloadCache
  { maxCacheBytes :: !Int
  , curCacheBytes :: !Int
  , cacheMap :: !(Map.Map (Text, Text) (Int, Value)) -- (campaign, entry_id) -> (bytes, txsValue)
  , cacheOrder :: !(Seq (Text, Text))
  } deriving (Show)

emptyCache :: Int -> PayloadCache
emptyCache maxB = PayloadCache { maxCacheBytes = maxB, curCacheBytes = 0, cacheMap = mempty, cacheOrder = Seq.empty }

data GetReq = GetReq
  { reqMsgId :: !(Maybe Text)
  , reqEntryId :: !Text
  } deriving (Show, Eq)

data HelloInfo = HelloInfo
  { helloInstanceId :: !(Maybe Text)
  , helloClientName :: !(Maybe Text)
  , helloClientVersion :: !(Maybe Text)
  , helloResumeSince :: !(Maybe Int)
  } deriving (Show, Eq)

data PubBucket = PubBucket
  { pubCap :: !Int
  , pubTok :: !Int
  , pubLast :: !Double
  } deriving (Show, Eq)

mkPubBucket :: Int -> IO PubBucket
mkPubBucket cap
  | cap <= 0 = do
      now <- realToFrac <$> getPOSIXTime
      pure $ PubBucket 0 0 now
  | otherwise = do
      now <- realToFrac <$> getPOSIXTime
      pure $ PubBucket cap cap now

consumePubTokens :: PubBucket -> Int -> IO (Bool, PubBucket)
consumePubTokens b cost = do
  if b.pubCap <= 0
    then pure (True, b)
    else do
      now <- realToFrac <$> getPOSIXTime
      let dt = now - b.pubLast
          refillRate = (fromIntegral b.pubCap :: Double) / 60.0
          add = floor (dt * refillRate)
          tok' = min b.pubCap (b.pubTok + add)
          b' = b { pubTok = tok', pubLast = if add > 0 then now else b.pubLast }
      if cost <= 0
        then pure (True, b')
        else if b'.pubTok >= cost
          then pure (True, b' { pubTok = b'.pubTok - cost })
          else pure (False, b')

-- A bounded queue doesn't expose tryWrite in all stm versions.
tryWriteTBQueue :: TBQueue a -> a -> STM Bool
tryWriteTBQueue q a = do
  full <- isFullTBQueue q
  if full then pure False else writeTBQueue q a >> pure True

data ConnState = ConnState
  { connId :: !Int
  , connStartedAt :: !UTCTime
  , connHello :: !HelloInfo
  , connDirectQ :: !(TBQueue (Maybe LBS.ByteString))
  , connBcastQ :: !(TBQueue (Maybe LBS.ByteString))
  , connGetQ :: !(TBQueue (Maybe GetReq))
  , connCounters :: !(TVar Counters)
  , connPubBucket :: !(TVar PubBucket)
  }

data CampaignState = CampaignState
  { nextSeq :: !(TVar Int)
  , entries :: !(TVar (Map.Map Text EntryMeta)) -- entry_id -> meta
  , index :: !(TVar [(Int, EntryMeta)])         -- (seq, meta), append-only
  , coverageCount :: !(TVar Int)
  , failuresSeen :: !(TVar (Set.Set Text))
  , nextConnId :: !(TVar Int)
  , conns :: !(TVar (Map.Map Int ConnState))
  , campInterval :: !(TVar Counters)
  , campTotals :: !(TVar Counters)
  }

data HubState = HubState
  { opts :: !HubOptions
  , campaigns :: !(TVar (Map.Map Text CampaignState))
  , globalInterval :: !(TVar Counters)
  , globalTotals :: !(TVar Counters)
  , payloadCache :: !(TVar PayloadCache)
  , lastError :: !(TVar (Maybe Text))
  , logLock :: !(MVar ())
  }

data LogLevel = LInfo | LWarn | LError deriving (Show, Eq)

main :: IO ()
main = do
  -- When stdout is redirected to a file, Haskell defaults to block buffering.
  -- That makes hub.log look "empty" for long stretches. Force line buffering.
  IO.hSetBuffering IO.stdout IO.LineBuffering
  IO.hSetBuffering IO.stderr IO.LineBuffering

  opts@HubOptions{..} <- execParser optsParser

  when (noAuth && (host == "0.0.0.0" || host == "::")) $ do
    putStrLn "WARNING: --no-auth with --host 0.0.0.0/:: exposes the hub publicly. Use only on trusted networks."

  createDirectoryIfMissing True dataDir

  logLock <- newMVar ()
  campaignsVar <- newTVarIO mempty
  globalIntervalVar <- newTVarIO emptyCounters
  globalTotalsVar <- newTVarIO emptyCounters
  lastErrVar <- newTVarIO Nothing
  let maxCacheBytes = max 0 payloadCacheMb * 1024 * 1024
  cacheVar <- newTVarIO (emptyCache maxCacheBytes)

  let st = HubState
        { opts
        , campaigns = campaignsVar
        , globalInterval = globalIntervalVar
        , globalTotals = globalTotalsVar
        , payloadCache = cacheVar
        , lastError = lastErrVar
        , logLock = logLock
        }

  loadFromDisk st

  logEvent st LInfo "hub_listen"
    [ ("host", String (T.pack host))
    , ("port", toJSON port)
    , ("data_dir", String (T.pack dataDir))
    ]

  when (statsIntervalMs > 0) $ do
    _ <- forkIO (statsLoop st)
    pure ()

  runServer host port (serverApp st)

serverApp :: HubState -> PendingConnection -> IO ()
serverApp st pending = do
  conn <- acceptRequest pending

  -- Expect hello first.
  helloRaw <- (receiveData conn :: IO LBS.ByteString)
  bumpIn st Nothing (fromIntegral (LBS.length helloRaw))

  if LBS.length helloRaw > fromIntegral st.opts.maxMsgBytes
    then sendClose conn ("message too large" :: Text)
    else case decodeEnvelope helloRaw of
      Left _ -> sendClose conn ("bad hello" :: Text)
      Right Envelope{msgType, campaign, payload} ->
        if msgType /= "hello"
          then sendClose conn ("expected hello" :: Text)
          else do
            authOk <- authorize st payload
            if not authOk
              then do
                bumpErr st Nothing
                sendClose conn ("unauthorized" :: Text)
              else do
                helloInfo <- parseHello payload
                cs <- getOrCreateCampaign st campaign
                connState <- newConnState st cs helloInfo
                registerConn cs connState

                logEvent st LInfo "client_connect"
                  [ ("campaign", String campaign)
                  , ("conn_id", toJSON connState.connId)
                  , ("instance_id", maybe Null String helloInfo.helloInstanceId)
                  , ("client_name", maybe Null String helloInfo.helloClientName)
                  , ("client_version", maybe Null String helloInfo.helloClientVersion)
                  , ("resume_since", maybe Null toJSON helloInfo.helloResumeSince)
                  ]

                -- Ensure per-connection cleanup runs once.
                cleanupOnce <- newTVarIO False

                let doCleanup :: Text -> Maybe SomeException -> IO ()
                    doCleanup reason mex = do
                      first <- atomically $ do
                        already <- readTVar cleanupOnce
                        if already then pure False else writeTVar cleanupOnce True >> pure True
                      when first $ do
                        unregisterConn cs connState.connId
                        stopConnQueues connState
                        (sendClose conn ("bye" :: Text)) `catch` \(_ :: SomeException) -> pure ()
                        now <- getCurrentTime
                        let dur = realToFrac (diffUTCTime now connState.connStartedAt) :: Double
                        cc <- readTVarIO connState.connCounters
                        logEvent st LInfo "client_disconnect"
                          [ ("campaign", String campaign)
                          , ("conn_id", toJSON connState.connId)
                          , ("duration_s", toJSON dur)
                          , ("reason", String reason)
                          , ("exception", maybe Null (String . T.pack . displayException) mex)
                          , ("in_msgs", toJSON cc.inMsgs)
                          , ("out_msgs", toJSON cc.outMsgs)
                          , ("in_bytes", toJSON cc.inBytes)
                          , ("out_bytes", toJSON cc.outBytes)
                          , ("errs", toJSON cc.errs)
                          ]

                -- Enqueue welcome (direct).
                welcome <- mkWelcome st campaign cs
                atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope welcome))

                -- Writer + GET server threads.
                _ <- forkFinally (writerLoop st cs conn connState) $ \case
                  Left e -> doCleanup "writer_exception" (Just e)
                  Right () -> doCleanup "writer_closed" Nothing
                _ <- forkFinally (getServeLoop st campaign cs connState) $ \case
                  Left e -> doCleanup "get_exception" (Just e)
                  Right () -> doCleanup "get_closed" Nothing

                -- Reader loop on current thread.
                (readerLoop st campaign cs connState conn)
                  `catch` \(e :: SomeException) -> doCleanup "reader_exception" (Just e)

authorize :: HubState -> Value -> IO Bool
authorize HubState{opts=HubOptions{..}} payloadVal
  | noAuth = pure True
  | null tokens = pure False
  | otherwise =
      case parseEither parseAuth payloadVal of
        Left _ -> pure False
        Right tok -> pure (tok `elem` tokens)
  where
    parseAuth = withObject "hello.payload" $ \o ->
      o .:? "auth" >>= \case
        Nothing -> fail "missing auth"
        Just Null -> fail "missing auth"
        Just v -> withObject "auth" (\a -> do
          typ <- a .: "type"
          if (typ :: Text) /= "bearer" then fail "bad auth type" else a .: "token"
          ) v

parseHello :: Value -> IO HelloInfo
parseHello payloadVal =
  case parseEither parseInfo payloadVal of
    Left _ -> pure (HelloInfo Nothing Nothing Nothing Nothing)
    Right i -> pure i
  where
    parseInfo = withObject "hello.payload" $ \o -> do
      iid <- o .:? "instance_id"
      cli <- o .:? "client"
      (cname, cver) <-
        case cli of
          Nothing -> pure (Nothing, Nothing)
          Just v -> withObject "client" (\c -> (,) <$> c .:? "name" <*> c .:? "version") v
      resumeVal <- o .:? "resume"
      sinceSeq <-
        case resumeVal of
          Nothing -> pure Nothing
          Just v -> withObject "resume" (\r -> r .:? "since_seq") v
      pure (HelloInfo iid cname cver sinceSeq)

newConnState :: HubState -> CampaignState -> HelloInfo -> IO ConnState
newConnState HubState{opts=HubOptions{..}} cs helloInfo = do
  startedAt <- getCurrentTime
  cid <- atomically $ do
    n <- readTVar cs.nextConnId
    let n' = n + 1
    writeTVar cs.nextConnId n'
    pure n'

  -- Direct messages must not be dropped. Keep this comfortably > maxInflightGets
  -- so corpus_since/corpus_entry can drain even under announce spam.
  let directCap = max 1024 (maxInflightGets + 256)
      bcastCap = max 1024 (maxInflightGets `div` 2)
      getCap = max 1 maxInflightGets

  directQ <- newTBQueueIO (fromIntegral directCap)
  bcastQ <- newTBQueueIO (fromIntegral bcastCap)
  getQ <- newTBQueueIO (fromIntegral getCap)

  cntVar <- newTVarIO emptyCounters
  bucket0 <- mkPubBucket maxPublishesPerMinute
  bucketVar <- newTVarIO bucket0

  pure ConnState
    { connId = cid
    , connStartedAt = startedAt
    , connHello = helloInfo
    , connDirectQ = directQ
    , connBcastQ = bcastQ
    , connGetQ = getQ
    , connCounters = cntVar
    , connPubBucket = bucketVar
    }

registerConn :: CampaignState -> ConnState -> IO ()
registerConn cs c =
  atomically $ modifyTVar' cs.conns (Map.insert c.connId c)

unregisterConn :: CampaignState -> Int -> IO ()
unregisterConn cs cid =
  atomically $ modifyTVar' cs.conns (Map.delete cid)

stopConnQueues :: ConnState -> IO ()
stopConnQueues ConnState{..} = atomically $ do
  let stopQ q = do
        ok <- tryWriteTBQueue q Nothing
        unless ok $ do
          _ <- tryReadTBQueue q
          void $ tryWriteTBQueue q Nothing
  stopQ connDirectQ
  stopQ connBcastQ
  stopQ connGetQ

getOrCreateCampaign :: HubState -> Text -> IO CampaignState
getOrCreateCampaign HubState{campaigns, opts=HubOptions{..}} camp = do
  existing <- readTVarIO campaigns
  case Map.lookup camp existing of
    Just cs -> pure cs
    Nothing -> do
      csNew <- newCampaignState
      atomically $ do
        mp <- readTVar campaigns
        case Map.lookup camp mp of
          Just cs -> pure cs
          Nothing -> writeTVar campaigns (Map.insert camp csNew mp) >> pure csNew
  where
    newCampaignState = do
      nextSeqVar <- newTVarIO 0
      entriesVar <- newTVarIO mempty
      indexVar <- newTVarIO []
      covVar <- newTVarIO 0
      failuresVar <- newTVarIO Set.empty
      nextConnVar <- newTVarIO 0
      connsVar <- newTVarIO mempty
      intervalVar <- newTVarIO emptyCounters
      totalsVar <- newTVarIO emptyCounters
      pure CampaignState
        { nextSeq = nextSeqVar
        , entries = entriesVar
        , index = indexVar
        , coverageCount = covVar
        , failuresSeen = failuresVar
        , nextConnId = nextConnVar
        , conns = connsVar
        , campInterval = intervalVar
        , campTotals = totalsVar
        }

mkEnvelope :: Text -> Text -> Maybe Text -> Value -> IO Envelope
mkEnvelope camp typ mid payload = do
  now <- getCurrentTime
  pure Envelope
    { v = 1
    , msgType = typ
    , msgId = mid
    , ts = now
    , campaign = camp
    , payload = payload
    }

mkWelcome :: HubState -> Text -> CampaignState -> IO Envelope
mkWelcome _st camp cs = do
  latest <- readTVarIO cs.nextSeq
  nEntries <- Map.size <$> readTVarIO cs.entries
  mkEnvelope camp "welcome" Nothing $
    object
      [ "session_id" .= ("hub" :: Text)
      , "hub" .= object ["name" .= ("echidna-corpus-hub" :: Text), "version" .= ("0.2.0" :: Text)]
      , "features" .= object
          [ "supports_get" .= True
          , "supports_batch" .= True
          , "supports_since_request" .= True
          , "supports_stop_broadcast" .= True
          ]
      , "state" .= object
          [ "latest_seq" .= latest
          , "corpus_entries" .= nEntries
          ]
      ]

writerLoop :: HubState -> CampaignState -> Connection -> ConnState -> IO ()
writerLoop st cs conn ConnState{..} = go
  where
    go = do
      m <- atomically $ (readTBQueue connDirectQ) `orElse` (readTBQueue connBcastQ)
      case m of
        Nothing -> pure () -- stop sentinel
        Just bs -> do
          bumpOut st (Just cs) (Just connCounters) (fromIntegral (LBS.length bs))
          sendTextData conn bs
          go

readerLoop :: HubState -> Text -> CampaignState -> ConnState -> Connection -> IO ()
readerLoop st camp cs connState conn =
  forever $ do
    raw <- (receiveData conn :: IO LBS.ByteString)
    bumpIn st (Just connState.connCounters) (fromIntegral (LBS.length raw))

    if LBS.length raw > fromIntegral st.opts.maxMsgBytes
      then do
        bumpErr st (Just connState.connCounters)
        sendClose conn ("message too large" :: Text)
      else case decodeEnvelope raw of
        Left _ -> bumpErr st (Just connState.connCounters)
        Right Envelope{msgType, msgId, payload} ->
          case msgType of
            "corpus_publish" -> handlePublish st camp cs connState msgId payload
            "corpus_publish_batch" -> handlePublishBatch st camp cs connState msgId payload
            "corpus_get" -> handleGet st camp cs connState msgId payload
            "corpus_since_request" -> handleSinceRequest st camp cs connState msgId payload
            "failure_publish" -> handleFailure st camp cs connState msgId payload
            _ -> pure ()

handleGet :: HubState -> Text -> CampaignState -> ConnState -> Maybe Text -> Value -> IO ()
handleGet st camp cs ConnState{..} mid payloadVal =
  case parseEither parseReq payloadVal of
    Left err -> do
      bumpErr st (Just connCounters)
      env <- mkError camp mid "bad_request" (T.pack err)
      atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
    Right eid -> do
      bumpGetReq st cs connCounters
      atomically $ writeTBQueue connGetQ (Just (GetReq mid eid))
  where
    parseReq = withObject "corpus_get.payload" (\o -> o .: "entry_id")

getServeLoop :: HubState -> Text -> CampaignState -> ConnState -> IO ()
getServeLoop st camp cs ConnState{..} = go
  where
    go = do
      mreq <- atomically $ readTBQueue connGetQ
      case mreq of
        Nothing -> pure ()
        Just GetReq{..} -> do
          metas <- readTVarIO cs.entries
          case Map.lookup reqEntryId metas of
            Nothing -> do
              bumpNotFound st cs connCounters
              env <- mkError camp reqMsgId "not_found" "unknown entry_id"
              atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
            Just meta -> do
              mtxs <- readPayloadCached st camp reqEntryId
              case mtxs of
                Left err -> do
                  bumpNotFound st cs connCounters
                  env <- mkError camp reqMsgId "not_found" err
                  atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
                Right txsVal -> do
                  bumpGetServed st cs connCounters
                  env <- mkEnvelope camp "corpus_entry" reqMsgId (object ["entry" .= meta, "txs" .= txsVal])
                  atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
          go

readPayloadCached :: HubState -> Text -> Text -> IO (Either Text Value)
readPayloadCached st@HubState{opts=HubOptions{dataDir}, payloadCache, lastError} camp eid = do
  let key = (camp, eid)
  let file = dataDir </> T.unpack camp </> "corpus" </> T.unpack eid <.> "txt"

  cached <- atomically $ cacheLookup payloadCache key
  case cached of
    Just v -> pure (Right v)
    Nothing -> do
      exists <- doesFileExist file
      if not exists
        then do
          let msg = "missing payload: " <> camp <> "/" <> eid
          atomically $ writeTVar lastError (Just msg)
          logEvent st LWarn "payload_missing" [("campaign", String camp), ("entry_id", String eid)]
          pure (Left "missing payload")
        else do
          bs <- LBS.readFile file
          case eitherDecode bs :: Either String Value of
            Left _ -> do
              let msg = "corrupt payload: " <> camp <> "/" <> eid
              atomically $ writeTVar lastError (Just msg)
              logEvent st LError "payload_corrupt" [("campaign", String camp), ("entry_id", String eid)]
              pure (Left "corrupt payload")
            Right v -> do
              atomically $ cacheInsert payloadCache key (fromIntegral (LBS.length bs)) v
              pure (Right v)

cacheLookup :: TVar PayloadCache -> (Text, Text) -> STM (Maybe Value)
cacheLookup cacheVar key = do
  c <- readTVar cacheVar
  case Map.lookup key c.cacheMap of
    Nothing -> pure Nothing
    Just (_sz, v) -> do
      let order' = Seq.filter (/= key) c.cacheOrder Seq.|> key
      writeTVar cacheVar (c { cacheOrder = order' })
      pure (Just v)

cacheInsert :: TVar PayloadCache -> (Text, Text) -> Int -> Value -> STM ()
cacheInsert cacheVar key sz v = do
  c0 <- readTVar cacheVar
  if c0.maxCacheBytes <= 0 || sz > c0.maxCacheBytes
    then pure ()
    else do
      let (c1, removedSz) =
            case Map.lookup key c0.cacheMap of
              Nothing -> (c0, 0)
              Just (oldSz, _) -> (c0 { cacheMap = Map.delete key c0.cacheMap, cacheOrder = Seq.filter (/= key) c0.cacheOrder }, oldSz)
          c2 = c1 { curCacheBytes = c1.curCacheBytes - removedSz }
      c3 <- evictUntilFit c2
      let mp' = Map.insert key (sz, v) c3.cacheMap
          ord' = c3.cacheOrder Seq.|> key
      writeTVar cacheVar (c3 { cacheMap = mp', cacheOrder = ord', curCacheBytes = c3.curCacheBytes + sz })
  where
    evictUntilFit c
      | c.curCacheBytes + sz <= c.maxCacheBytes = pure c
      | otherwise =
          case Seq.viewl c.cacheOrder of
            Seq.EmptyL -> pure c
            k Seq.:< rest ->
              case Map.lookup k c.cacheMap of
                Nothing -> evictUntilFit (c { cacheOrder = rest })
                Just (kSz, _) ->
                  evictUntilFit (c { cacheOrder = rest, cacheMap = Map.delete k c.cacheMap, curCacheBytes = c.curCacheBytes - kSz })

handleSinceRequest :: HubState -> Text -> CampaignState -> ConnState -> Maybe Text -> Value -> IO ()
handleSinceRequest st camp cs ConnState{..} mid payloadVal =
  case parseEither parseReq payloadVal of
    Left err -> do
      bumpErr st (Just connCounters)
      env <- mkError camp mid "bad_request" (T.pack err)
      atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
    Right (sinceSeq, limit0) -> do
      items <- readTVarIO cs.index
      let newer = dropWhile (\(s, _) -> s <= sinceSeq) items
          limit = max 1 (min 5000 limit0)
          (chunk, rest) = splitAt limit newer
          truncated = not (null rest)
          toSeq = if null chunk then sinceSeq else fst (last chunk)
      when truncated $ bumpTruncated st cs connCounters
      env <- mkEnvelope camp "corpus_since" mid $
        object
          [ "from_seq" .= sinceSeq
          , "to_seq" .= toSeq
          , "entries" .= fmap (\(seqNum, meta) -> object ["seq" .= seqNum, "entry" .= meta]) chunk
          , "truncated" .= truncated
          ]
      atomically $ writeTBQueue connDirectQ (Just (encodeEnvelope env))
  where
    parseReq = withObject "corpus_since_request.payload" $ \o -> do
      sinceSeq <- o .:? "since_seq" .!= 0
      limit <- o .:? "limit" .!= 1000
      pure (sinceSeq, limit)

handlePublish :: HubState -> Text -> CampaignState -> ConnState -> Maybe Text -> Value -> IO ()
handlePublish st camp cs connState mid payloadVal =
  case parseEither parsePayload payloadVal of
    Left err -> do
      bumpErr st (Just connState.connCounters)
      env <- mkError camp mid "bad_request" (T.pack err)
      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
    Right (meta, txs) -> do
      ok <- checkPublishRate st cs connState 1
      if not ok
        then do
          env <- mkError camp mid "rate_limited" "publish rate limited"
          atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
        else do
          let encodedTxs = encode txs
              bytesLen = fromIntegral (LBS.length encodedTxs) :: Int
          if bytesLen > st.opts.maxEntryBytes
            then do
              bumpRejected st cs connState.connCounters
              env <- mkError camp mid "too_large" "entry too large"
              atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
            else do
              let computed = entryIdForTxs txs
              if computed /= meta.entryId
                then do
                  bumpRejected st cs connState.connCounters
                  env <- mkError camp mid "id_mismatch" "entry_id mismatch"
                  atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
                else do
                  decision <- atomically $ decideInsert st cs meta
                  case decision of
                    Left "deduped" -> do
                      bumpDeduped st cs connState.connCounters
                      env <- mkAck camp mid "deduped"
                      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
                    Left reason -> do
                      bumpRejected st cs connState.connCounters
                      env <- mkAck camp mid ("rejected:" <> reason)
                      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
                    Right seqNum -> do
                      bumpAccepted st cs connState.connCounters
                      persistEntry st camp seqNum meta encodedTxs
                      broadcastAnnounce st camp cs seqNum meta
                      env <- mkAck camp mid "accepted"
                      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
  where
    parsePayload = withObject "corpus_publish.payload" $ \o -> do
      meta <- o .: "entry"
      txs <- o .: "txs"
      pure (meta, txs)

handlePublishBatch :: HubState -> Text -> CampaignState -> ConnState -> Maybe Text -> Value -> IO ()
handlePublishBatch st camp cs connState mid payloadVal =
  case parseEither parsePayload payloadVal of
    Left err -> do
      bumpErr st (Just connState.connCounters)
      env <- mkError camp mid "bad_request" (T.pack err)
      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
    Right items -> do
      let cost = length items
      ok <- checkPublishRate st cs connState cost
      if not ok
        then do
          env <- mkError camp mid "rate_limited" "publish rate limited"
          atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
        else do
          (acc, ded, rej) <- foldlM (step cs) (0 :: Int, 0 :: Int, 0 :: Int) items
          env <- mkEnvelope camp "ack" mid (object ["ok" .= True, "status" .= ("batch" :: Text), "accepted" .= acc, "deduped" .= ded, "rejected" .= rej])
          atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
  where
    parsePayload = withObject "corpus_publish_batch.payload" $ \o -> do
      xs <- o .: "items"
      forM xs $ withObject "batch_item" $ \i -> do
        meta <- i .: "entry"
        txs <- i .: "txs"
        pure (meta, txs)

    foldlM f z xs = go z xs
      where
        go acc [] = pure acc
        go acc (y:ys) = f acc y >>= \acc' -> go acc' ys

    step cs0 (acc, ded, rej) (meta, txs) = do
      let encodedTxs = encode txs
          bytesLen = fromIntegral (LBS.length encodedTxs) :: Int
      if bytesLen > st.opts.maxEntryBytes
        then bumpRejected st cs0 connState.connCounters >> pure (acc, ded, rej + 1)
        else do
          let computed = entryIdForTxs txs
          if computed /= meta.entryId
            then bumpRejected st cs0 connState.connCounters >> pure (acc, ded, rej + 1)
            else do
              decision <- atomically $ decideInsert st cs0 meta
              case decision of
                Left "deduped" -> bumpDeduped st cs0 connState.connCounters >> pure (acc, ded + 1, rej)
                Left _reason -> bumpRejected st cs0 connState.connCounters >> pure (acc, ded, rej + 1)
                Right seqNum -> do
                  bumpAccepted st cs0 connState.connCounters
                  persistEntry st camp seqNum meta encodedTxs
                  broadcastAnnounce st camp cs0 seqNum meta
                  pure (acc + 1, ded, rej)

handleFailure :: HubState -> Text -> CampaignState -> ConnState -> Maybe Text -> Value -> IO ()
handleFailure st camp cs connState mid payloadVal =
  case parseEither parseReq payloadVal of
    Left err -> do
      bumpErr st (Just connState.connCounters)
      env <- mkError camp mid "bad_request" (T.pack err)
      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope env))
    Right (failureId, testName) -> do
      bumpFailure st cs connState.connCounters
      envAck <- mkAck camp mid "accepted"
      atomically $ writeTBQueue connState.connDirectQ (Just (encodeEnvelope envAck))

      logEvent st LInfo "failure_publish"
        [ ("campaign", String camp)
        , ("failure_id", String failureId)
        , ("test_name", String testName)
        ]

      first <- atomically $ do
        seen <- readTVar cs.failuresSeen
        if Set.member failureId seen
          then pure False
          else writeTVar cs.failuresSeen (Set.insert failureId seen) >> pure True
      when (first && st.opts.broadcastFleetStopOnFailure) $ do
        bumpFleetStop st cs connState.connCounters
        envStop <- mkEnvelope camp "fleet_stop" Nothing $
          object
            [ "reason" .= ("failure" :: Text)
            , "failure_id" .= failureId
            , "test_name" .= (testName :: Text)
            ]
        logEvent st LWarn "fleet_stop_broadcast"
          [ ("campaign", String camp)
          , ("reason", String ("failure" :: Text))
          , ("failure_id", String failureId)
          ]
        broadcastBytes st cs (encodeEnvelope envStop)
  where
    parseReq = withObject "failure_publish.payload" $ \o -> do
      f <- o .: "failure"
      fid <- withObject "failure" (\fo -> fo .: "failure_id") f
      tn <- withObject "failure" (\fo -> fo .: "test_name") f
      pure (fid, tn)

checkPublishRate :: HubState -> CampaignState -> ConnState -> Int -> IO Bool
checkPublishRate st cs ConnState{..} cost = do
  let cap = st.opts.maxPublishesPerMinute
  if cap <= 0
    then pure True
    else do
      b <- readTVarIO connPubBucket
      (ok, b') <- consumePubTokens b cost
      atomically $ writeTVar connPubBucket b'
      unless ok $ bumpRateLimited st cs connCounters
      pure ok

decideInsert :: HubState -> CampaignState -> EntryMeta -> STM (Either Text Int)
decideInsert HubState{opts=HubOptions{maxCoverageEntries}} cs meta = do
  mp <- readTVar cs.entries
  if Map.member meta.entryId mp
    then pure (Left "deduped")
    else do
      covN <- readTVar cs.coverageCount
      let isCoverage = meta.entryType == EntryCoverage
      if isCoverage && maxCoverageEntries > 0 && covN >= maxCoverageEntries
        then pure (Left "cap")
        else do
          n <- readTVar cs.nextSeq
          let n' = n + 1
          writeTVar cs.nextSeq n'
          modifyTVar' cs.entries (Map.insert meta.entryId meta)
          modifyTVar' cs.index (\xs -> xs ++ [(n', meta)])
          when isCoverage $ writeTVar cs.coverageCount (covN + 1)
          pure (Right n')

persistEntry :: HubState -> Text -> Int -> EntryMeta -> LBS.ByteString -> IO ()
persistEntry st@HubState{opts=HubOptions{dataDir}, lastError} camp seqNum meta encodedTxs = do
  let dir = dataDir </> T.unpack camp
      corpusDir = dir </> "corpus"
      idxFile = dir </> "index.jsonl"
  createDirectoryIfMissing True corpusDir
  let file = corpusDir </> T.unpack meta.entryId <.> "txt"
  (do
      exists <- doesFileExist file
      unless exists $ LBS.writeFile file encodedTxs
    ) `catch` \(e :: SomeException) ->
        do
          bumpErr st Nothing
          let msg = "persist payload error: " <> T.pack (displayException e)
          atomically $ writeTVar lastError (Just msg)
          logEvent st LError "persist_error"
            [ ("campaign", String camp)
            , ("entry_id", String meta.entryId)
            , ("stage", String ("payload" :: Text))
            , ("exception", String (T.pack (displayException e)))
            ]
  -- Append index line (best-effort).
  (do
      now <- getCurrentTime
      let line = encode (object ["seq" .= seqNum, "ts" .= now, "entry" .= meta]) <> "\n"
      LBS.appendFile idxFile line
    ) `catch` \(e :: SomeException) ->
        do
          bumpErr st Nothing
          let msg = "persist index error: " <> T.pack (displayException e)
          atomically $ writeTVar lastError (Just msg)
          logEvent st LError "persist_error"
            [ ("campaign", String camp)
            , ("entry_id", String meta.entryId)
            , ("stage", String ("index" :: Text))
            , ("exception", String (T.pack (displayException e)))
            ]

broadcastAnnounce :: HubState -> Text -> CampaignState -> Int -> EntryMeta -> IO ()
broadcastAnnounce st camp cs seqNum meta = do
  env <- mkEnvelope camp "corpus_announce" Nothing (object ["seq" .= seqNum, "entry" .= meta])
  broadcastBytes st cs (encodeEnvelope env)

broadcastBytes :: HubState -> CampaignState -> LBS.ByteString -> IO ()
broadcastBytes st cs bs = do
  connsNow <- readTVarIO cs.conns
  forM_ (Map.elems connsNow) $ \ConnState{..} -> do
    ok <- atomically $ tryWriteTBQueue connBcastQ (Just bs)
    unless ok $ bumpDroppedBroadcast st cs connCounters

mkAck :: Text -> Maybe Text -> Text -> IO Envelope
mkAck camp mid status =
  mkEnvelope camp "ack" mid (object ["ok" .= True, "status" .= status])

mkError :: Text -> Maybe Text -> Text -> Text -> IO Envelope
mkError camp mid code message =
  mkEnvelope camp "error" mid (object ["code" .= code, "message" .= message])

-- Metrics helpers
bumpIn :: HubState -> Maybe (TVar Counters) -> Int -> IO ()
bumpIn st mConn bytes = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { inMsgs = c.inMsgs + 1, inBytes = c.inBytes + bytes })
  modifyTVar' st.globalTotals (\c -> c { inMsgs = c.inMsgs + 1, inBytes = c.inBytes + bytes })
  forM_ mConn $ \cv -> modifyTVar' cv (\c -> c { inMsgs = c.inMsgs + 1, inBytes = c.inBytes + bytes })

bumpOut :: HubState -> Maybe CampaignState -> Maybe (TVar Counters) -> Int -> IO ()
bumpOut st mCamp mConn bytes = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { outMsgs = c.outMsgs + 1, outBytes = c.outBytes + bytes })
  modifyTVar' st.globalTotals (\c -> c { outMsgs = c.outMsgs + 1, outBytes = c.outBytes + bytes })
  forM_ mCamp $ \cs -> do
    modifyTVar' cs.campInterval (\c -> c { outMsgs = c.outMsgs + 1, outBytes = c.outBytes + bytes })
    modifyTVar' cs.campTotals (\c -> c { outMsgs = c.outMsgs + 1, outBytes = c.outBytes + bytes })
  forM_ mConn $ \cv -> modifyTVar' cv (\c -> c { outMsgs = c.outMsgs + 1, outBytes = c.outBytes + bytes })

bumpErr :: HubState -> Maybe (TVar Counters) -> IO ()
bumpErr st mConn = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { errs = c.errs + 1 })
  modifyTVar' st.globalTotals (\c -> c { errs = c.errs + 1 })
  forM_ mConn $ \cv -> modifyTVar' cv (\c -> c { errs = c.errs + 1 })

bumpAccepted :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpAccepted st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { accepted = c.accepted + 1 })
  modifyTVar' st.globalTotals (\c -> c { accepted = c.accepted + 1 })
  modifyTVar' cs.campInterval (\c -> c { accepted = c.accepted + 1 })
  modifyTVar' cs.campTotals (\c -> c { accepted = c.accepted + 1 })
  modifyTVar' connC (\c -> c { accepted = c.accepted + 1 })

bumpDeduped :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpDeduped st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { deduped = c.deduped + 1 })
  modifyTVar' st.globalTotals (\c -> c { deduped = c.deduped + 1 })
  modifyTVar' cs.campInterval (\c -> c { deduped = c.deduped + 1 })
  modifyTVar' cs.campTotals (\c -> c { deduped = c.deduped + 1 })
  modifyTVar' connC (\c -> c { deduped = c.deduped + 1 })

bumpRejected :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpRejected st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { rejected = c.rejected + 1 })
  modifyTVar' st.globalTotals (\c -> c { rejected = c.rejected + 1 })
  modifyTVar' cs.campInterval (\c -> c { rejected = c.rejected + 1 })
  modifyTVar' cs.campTotals (\c -> c { rejected = c.rejected + 1 })
  modifyTVar' connC (\c -> c { rejected = c.rejected + 1 })

bumpGetReq :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpGetReq st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { getsReq = c.getsReq + 1 })
  modifyTVar' st.globalTotals (\c -> c { getsReq = c.getsReq + 1 })
  modifyTVar' cs.campInterval (\c -> c { getsReq = c.getsReq + 1 })
  modifyTVar' cs.campTotals (\c -> c { getsReq = c.getsReq + 1 })
  modifyTVar' connC (\c -> c { getsReq = c.getsReq + 1 })

bumpGetServed :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpGetServed st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { getsServed = c.getsServed + 1 })
  modifyTVar' st.globalTotals (\c -> c { getsServed = c.getsServed + 1 })
  modifyTVar' cs.campInterval (\c -> c { getsServed = c.getsServed + 1 })
  modifyTVar' cs.campTotals (\c -> c { getsServed = c.getsServed + 1 })
  modifyTVar' connC (\c -> c { getsServed = c.getsServed + 1 })

bumpNotFound :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpNotFound st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { notFound = c.notFound + 1 })
  modifyTVar' st.globalTotals (\c -> c { notFound = c.notFound + 1 })
  modifyTVar' cs.campInterval (\c -> c { notFound = c.notFound + 1 })
  modifyTVar' cs.campTotals (\c -> c { notFound = c.notFound + 1 })
  modifyTVar' connC (\c -> c { notFound = c.notFound + 1 })

bumpTruncated :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpTruncated st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { truncatedSince = c.truncatedSince + 1 })
  modifyTVar' st.globalTotals (\c -> c { truncatedSince = c.truncatedSince + 1 })
  modifyTVar' cs.campInterval (\c -> c { truncatedSince = c.truncatedSince + 1 })
  modifyTVar' cs.campTotals (\c -> c { truncatedSince = c.truncatedSince + 1 })
  modifyTVar' connC (\c -> c { truncatedSince = c.truncatedSince + 1 })

bumpFailure :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpFailure st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { failures = c.failures + 1 })
  modifyTVar' st.globalTotals (\c -> c { failures = c.failures + 1 })
  modifyTVar' cs.campInterval (\c -> c { failures = c.failures + 1 })
  modifyTVar' cs.campTotals (\c -> c { failures = c.failures + 1 })
  modifyTVar' connC (\c -> c { failures = c.failures + 1 })

bumpFleetStop :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpFleetStop st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { fleetStops = c.fleetStops + 1 })
  modifyTVar' st.globalTotals (\c -> c { fleetStops = c.fleetStops + 1 })
  modifyTVar' cs.campInterval (\c -> c { fleetStops = c.fleetStops + 1 })
  modifyTVar' cs.campTotals (\c -> c { fleetStops = c.fleetStops + 1 })
  modifyTVar' connC (\c -> c { fleetStops = c.fleetStops + 1 })

bumpDroppedBroadcast :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpDroppedBroadcast st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { droppedBroadcast = c.droppedBroadcast + 1 })
  modifyTVar' st.globalTotals (\c -> c { droppedBroadcast = c.droppedBroadcast + 1 })
  modifyTVar' cs.campInterval (\c -> c { droppedBroadcast = c.droppedBroadcast + 1 })
  modifyTVar' cs.campTotals (\c -> c { droppedBroadcast = c.droppedBroadcast + 1 })
  modifyTVar' connC (\c -> c { droppedBroadcast = c.droppedBroadcast + 1 })

bumpRateLimited :: HubState -> CampaignState -> TVar Counters -> IO ()
bumpRateLimited st cs connC = atomically $ do
  modifyTVar' st.globalInterval (\c -> c { publishRateLimited = c.publishRateLimited + 1 })
  modifyTVar' st.globalTotals (\c -> c { publishRateLimited = c.publishRateLimited + 1 })
  modifyTVar' cs.campInterval (\c -> c { publishRateLimited = c.publishRateLimited + 1 })
  modifyTVar' cs.campTotals (\c -> c { publishRateLimited = c.publishRateLimited + 1 })
  modifyTVar' connC (\c -> c { publishRateLimited = c.publishRateLimited + 1 })

-- Logging
logEvent :: HubState -> LogLevel -> Text -> [(Text, Value)] -> IO ()
logEvent HubState{opts=HubOptions{logFormat}, logLock} lvl ev fields =
  withMVar logLock $ \_ -> do
    now <- getCurrentTime
    case logFormat of
      LogText -> do
        let base = "[" <> T.pack (show now) <> "] " <> T.pack (show lvl) <> " " <> ev
            kvs = T.unwords (fmap renderKV fields)
        putStrLn (T.unpack (if T.null kvs then base else base <> " " <> kvs))
      LogJson -> do
        let basePairs =
              [ (fromText "ts", String (T.pack (show now)))
              , (fromText "level", String (T.pack (show lvl)))
              , (fromText "event", String ev)
              ]
            extraPairs = fmap (\(k, v) -> (fromText k, v)) fields
        LBS8.putStrLn (encode (object (basePairs <> extraPairs)))
  where
    renderKV (k, v) = k <> "=" <> case v of
      String t -> t
      Number n -> T.pack (show n)
      Bool b -> if b then "true" else "false"
      Null -> "null"
      _ -> T.pack (LBS8.unpack (encode v))

statsLoop :: HubState -> IO ()
statsLoop st@HubState{opts=HubOptions{statsIntervalMs, statsFile}} = do
  t0 <- realToFrac <$> getPOSIXTime
  go t0
  where
    go lastT = do
      threadDelay (statsIntervalMs * 1000)
      now <- realToFrac <$> getPOSIXTime
      let dt = max 0.001 (now - lastT) -- avoid division by zero on clock skew
      snap <- collectStats st dt
      emitStats st snap
      forM_ statsFile $ \path ->
        LBS.writeFile path (encode (statsToJSON snap)) `catch` \(e :: SomeException) -> do
          atomically $ writeTVar st.lastError (Just ("stats-file write error: " <> T.pack (displayException e)))
          logEvent st LWarn "stats_file_error"
            [ ("path", String (T.pack path))
            , ("exception", String (T.pack (displayException e)))
            ]
      go now

    emitStats s StatsSnapshot{..} = do
      let dt = ssDt
          r n = ratePerSec n dt
          mibPerSec bytes = (fromIntegral bytes / dt) / (1024.0 * 1024.0) :: Double

      logEvent s LInfo "stats_global"
        [ ("dt_s", toJSON dt)
        , ("clients", toJSON ssClients)
        , ("campaigns", toJSON ssCampaignCount)
        , ("in_msgs_s", toJSON (r ssGlobalInterval.inMsgs))
        , ("out_msgs_s", toJSON (r ssGlobalInterval.outMsgs))
        , ("in_mib_s", toJSON (mibPerSec ssGlobalInterval.inBytes))
        , ("out_mib_s", toJSON (mibPerSec ssGlobalInterval.outBytes))
        , ("errs_s", toJSON (r ssGlobalInterval.errs))
        , ("accepted_s", toJSON (r ssGlobalInterval.accepted))
        , ("deduped_s", toJSON (r ssGlobalInterval.deduped))
        , ("rejected_s", toJSON (r ssGlobalInterval.rejected))
        , ("gets_s", toJSON (r ssGlobalInterval.getsServed))
        , ("not_found_s", toJSON (r ssGlobalInterval.notFound))
        , ("dropped_bcast_s", toJSON (r ssGlobalInterval.droppedBroadcast))
        , ("rate_limited_s", toJSON (r ssGlobalInterval.publishRateLimited))
        , ("last_error", maybe Null String ssLastError)
        ]

      forM_ ssCampaigns $ \CampaignSnap{..} -> do
        logEvent s LInfo "stats_campaign"
          [ ("campaign", String csCampaign)
          , ("clients", toJSON csClients)
          , ("entries", toJSON csEntries)
          , ("accepted_s", toJSON (r csInterval.accepted))
          , ("deduped_s", toJSON (r csInterval.deduped))
          , ("gets_s", toJSON (r csInterval.getsServed))
          , ("not_found_s", toJSON (r csInterval.notFound))
          , ("truncated_since", toJSON csInterval.truncatedSince)
          , ("dropped_broadcast", toJSON csInterval.droppedBroadcast)
          ]

data CampaignSnap = CampaignSnap
  { csCampaign :: !Text
  , csClients :: !Int
  , csEntries :: !Int
  , csInterval :: !Counters
  } deriving (Show, Eq)

data StatsSnapshot = StatsSnapshot
  { ssDt :: !Double
  , ssClients :: !Int
  , ssCampaignCount :: !Int
  , ssGlobalInterval :: !Counters
  , ssGlobalTotals :: !Counters
  , ssCampaigns :: ![CampaignSnap]
  , ssLastError :: !(Maybe Text)
  } deriving (Show, Eq)

collectStats :: HubState -> Double -> IO StatsSnapshot
collectStats HubState{campaigns, globalInterval, globalTotals, lastError} dt = do
  (globalInt, globalTot, campSnaps, mErr, clientsN, campsN) <- atomically $ do
    gi <- readTVar globalInterval
    gt <- readTVar globalTotals
    writeTVar globalInterval emptyCounters
    mp <- readTVar campaigns
    snaps <- forM (Map.toList mp) $ \(camp, cs) -> do
      ci <- readTVar cs.campInterval
      writeTVar cs.campInterval emptyCounters
      e <- readTVar cs.entries
      c <- readTVar cs.conns
      pure CampaignSnap
        { csCampaign = camp
        , csClients = Map.size c
        , csEntries = Map.size e
        , csInterval = ci
        }
    err <- readTVar lastError
    -- NoFieldSelectors is enabled for this project, so record selectors like
    -- `csClients` are not in scope. Use record-dot access instead.
    let clientsTotal = sum (fmap (\s -> s.csClients) snaps)
    pure (gi, gt, snaps, err, clientsTotal, Map.size mp)

  pure StatsSnapshot
    { ssDt = dt
    , ssClients = clientsN
    , ssCampaignCount = campsN
    , ssGlobalInterval = globalInt
    , ssGlobalTotals = globalTot
    , ssCampaigns = campSnaps
    , ssLastError = mErr
    }

ratePerSec :: Int -> Double -> Double
ratePerSec n dt
  | dt <= 0 = 0
  | otherwise = (fromIntegral n :: Double) / dt

statsToJSON :: StatsSnapshot -> Value
statsToJSON StatsSnapshot{..} =
  object
    [ "dt_s" .= ssDt
    , "global" .= object
        [ "clients" .= ssClients
        , "campaigns" .= ssCampaignCount
        , "interval" .= countersToJSON ssGlobalInterval
        , "rates" .= countersRatesToJSON ssGlobalInterval ssDt
        , "totals" .= countersToJSON ssGlobalTotals
        ]
    , "campaigns" .= fmap campaignToJSON ssCampaigns
    , "last_error" .= maybe Null String ssLastError
    ]
  where
    campaignToJSON CampaignSnap{..} =
      object
        [ "campaign" .= csCampaign
        , "clients" .= csClients
        , "entries" .= csEntries
        , "interval" .= countersToJSON csInterval
        , "rates" .= countersRatesToJSON csInterval ssDt
        ]

countersRatesToJSON :: Counters -> Double -> Value
countersRatesToJSON c dt =
  object
    [ "in_msgs_s" .= ratePerSec c.inMsgs dt
    , "out_msgs_s" .= ratePerSec c.outMsgs dt
    , "in_bytes_s" .= ratePerSec c.inBytes dt
    , "out_bytes_s" .= ratePerSec c.outBytes dt
    , "errs_s" .= ratePerSec c.errs dt
    , "accepted_s" .= ratePerSec c.accepted dt
    , "deduped_s" .= ratePerSec c.deduped dt
    , "rejected_s" .= ratePerSec c.rejected dt
    , "gets_req_s" .= ratePerSec c.getsReq dt
    , "gets_served_s" .= ratePerSec c.getsServed dt
    , "not_found_s" .= ratePerSec c.notFound dt
    , "truncated_since_s" .= ratePerSec c.truncatedSince dt
    , "failures_s" .= ratePerSec c.failures dt
    , "fleet_stops_s" .= ratePerSec c.fleetStops dt
    , "dropped_broadcast_s" .= ratePerSec c.droppedBroadcast dt
    , "publish_rate_limited_s" .= ratePerSec c.publishRateLimited dt
    ]

countersToJSON :: Counters -> Value
countersToJSON Counters{..} =
  object
    [ "in_msgs" .= inMsgs
    , "out_msgs" .= outMsgs
    , "in_bytes" .= inBytes
    , "out_bytes" .= outBytes
    , "errs" .= errs
    , "accepted" .= accepted
    , "deduped" .= deduped
    , "rejected" .= rejected
    , "gets_req" .= getsReq
    , "gets_served" .= getsServed
    , "not_found" .= notFound
    , "truncated_since" .= truncatedSince
    , "failures" .= failures
    , "fleet_stops" .= fleetStops
    , "dropped_broadcast" .= droppedBroadcast
    , "publish_rate_limited" .= publishRateLimited
    ]

-- Persistence reload
data IndexLine = IndexLine
  { ilSeq :: !Int
  , ilEntry :: !EntryMeta
  } deriving (Show, Eq)

instance FromJSON IndexLine where
  parseJSON = withObject "IndexLine" $ \o ->
    IndexLine <$> o .: "seq" <*> o .: "entry"

loadFromDisk :: HubState -> IO ()
loadFromDisk st@HubState{opts=HubOptions{dataDir}, campaigns} = do
  dirs <- listDirectory dataDir `catch` \(_ :: SomeException) -> pure []
  loaded <- fmap Map.fromList $ fmap concat $ forM dirs $ \d -> do
    let path = dataDir </> d
    isDir <- doesDirectoryExist path
    if not isDir then pure [] else do
      let camp = T.pack d
      mcs <- loadCampaignFrom path
      case mcs of
        Nothing -> pure []
        Just cs -> do
          nEntries <- Map.size <$> readTVarIO cs.entries
          logEvent st LInfo "campaign_loaded"
            [ ("campaign", String camp)
            , ("entries", toJSON nEntries)
            ]
          pure [(camp, cs)]
  atomically $ writeTVar campaigns loaded
  where
    loadCampaignFrom :: FilePath -> IO (Maybe CampaignState)
    loadCampaignFrom dir = do
      let idx = dir </> "index.jsonl"
      exists <- doesFileExist idx
      if not exists
        then pure Nothing
        else do
          (ls, badLines) <- loadIndexLines idx
          when (badLines > 0) $
            logEvent st LWarn "index_parse_errors"
              [ ("campaign", String (T.pack (takeFileName dir)))
              , ("file", String (T.pack idx))
              , ("bad_lines", toJSON badLines)
              ]
          let sorted = ls
              entryMap = foldl' (\m IndexLine{..} -> Map.insert ilEntry.entryId ilEntry m) mempty sorted
              idxList = fmap (\IndexLine{..} -> (ilSeq, ilEntry)) sorted
              maxSeq = foldl' (\mx (s, _) -> max mx s) 0 idxList
              covN = Map.size (Map.filter (\m -> m.entryType == EntryCoverage) entryMap)
          nextSeqVar <- newTVarIO maxSeq
          entriesVar <- newTVarIO entryMap
          indexVar <- newTVarIO idxList
          covVar <- newTVarIO covN
          failuresVar <- newTVarIO Set.empty
          nextConnVar <- newTVarIO 0
          connsVar <- newTVarIO mempty
          intervalVar <- newTVarIO emptyCounters
          totalsVar <- newTVarIO emptyCounters
          pure $ Just CampaignState
            { nextSeq = nextSeqVar
            , entries = entriesVar
            , index = indexVar
            , coverageCount = covVar
            , failuresSeen = failuresVar
            , nextConnId = nextConnVar
            , conns = connsVar
            , campInterval = intervalVar
            , campTotals = totalsVar
            }

loadIndexLines :: FilePath -> IO ([IndexLine], Int)
loadIndexLines file =
  withFile file ReadMode $ \h -> go [] 0 h
  where
    go acc bad h = do
      eof <- hIsEOF h
      if eof
        then pure (reverse acc, bad)
        else do
          line <- BS.hGetLine h
          case eitherDecodeStrict' line of
            Left _ -> go acc (bad + 1) h
            Right v -> go (v : acc) bad h
