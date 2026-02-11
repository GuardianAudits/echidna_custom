{-# LANGUAGE RecordWildCards #-}

module Echidna.CorpusSync.Protocol
  ( Envelope(..)
  , decodeEnvelope
  , encodeEnvelope
  , newMsgId
  , mkHello
  , mkCorpusPublish
  , mkCorpusPublishBatch
  , mkCorpusGet
  , mkCorpusSinceRequest
  , mkFailurePublish
  , EntryType(..)
  , Origin(..)
  , EntryMeta(..)
  , CorpusAnnounce(..)
  , CorpusEntry(..)
  , CorpusSinceItem(..)
  , CorpusSince(..)
  , FleetStop(..)
  ) where

import Data.Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Numeric (showHex)
import System.Random (randomIO)

import Echidna.Types.Tx (Tx)

data Envelope = Envelope
  { v :: Int
  , msgType :: Text
  , msgId :: Maybe Text
  , ts :: UTCTime
  , campaign :: Text
  , payload :: Value
  } deriving (Show, Eq)

instance ToJSON Envelope where
  toJSON Envelope{..} =
    object
      [ "v" .= v
      , "type" .= msgType
      , "msg_id" .= msgId
      , "ts" .= ts
      , "campaign" .= campaign
      , "payload" .= payload
      ]

instance FromJSON Envelope where
  parseJSON = withObject "Envelope" $ \o ->
    Envelope
      <$> o .: "v"
      <*> o .: "type"
      <*> o .:? "msg_id"
      <*> o .: "ts"
      <*> o .: "campaign"
      <*> o .: "payload"

encodeEnvelope :: Envelope -> LBS.ByteString
encodeEnvelope = encode

decodeEnvelope :: LBS.ByteString -> Either String Envelope
decodeEnvelope = eitherDecode

newMsgId :: IO Text
newMsgId = do
  -- 128-bit random ID (hex).
  a <- (randomIO :: IO Word64)
  b <- (randomIO :: IO Word64)
  pure $ T.pack (pad16 a <> pad16 b)
  where
    pad16 x =
      let s = showHex x ""
      in replicate (16 - length s) '0' <> s

data EntryType = EntryCoverage | EntryReproducer deriving (Show, Eq)

instance ToJSON EntryType where
  toJSON = \case
    EntryCoverage -> String "coverage"
    EntryReproducer -> String "reproducer"

instance FromJSON EntryType where
  parseJSON = withText "EntryType" $ \t ->
    case T.toLower t of
      "coverage" -> pure EntryCoverage
      "reproducer" -> pure EntryReproducer
      _ -> fail "invalid entry_type (expected coverage|reproducer)"

data Origin = Origin
  { instanceId :: Text
  , workerId :: Maybe Int
  , workerType :: Maybe Text
  } deriving (Show, Eq)

instance ToJSON Origin where
  toJSON Origin{..} =
    object
      [ "instance_id" .= instanceId
      , "worker_id" .= workerId
      , "worker_type" .= workerType
      ]

instance FromJSON Origin where
  parseJSON = withObject "Origin" $ \o ->
    Origin
      <$> o .: "instance_id"
      <*> o .:? "worker_id"
      <*> o .:? "worker_type"

data EntryMeta = EntryMeta
  { entryId :: Text
  , entryType :: EntryType
  , encoding :: Text
  , compressed :: Text
  , txCount :: Int
  , bytes :: Int
  , origin :: Origin
  , hints :: Maybe Value
  } deriving (Show, Eq)

instance ToJSON EntryMeta where
  toJSON EntryMeta{..} =
    object
      [ "entry_id" .= entryId
      , "entry_type" .= entryType
      , "encoding" .= encoding
      , "compressed" .= compressed
      , "tx_count" .= txCount
      , "bytes" .= bytes
      , "origin" .= origin
      , "hints" .= hints
      ]

instance FromJSON EntryMeta where
  parseJSON = withObject "EntryMeta" $ \o ->
    EntryMeta
      <$> o .: "entry_id"
      <*> o .: "entry_type"
      <*> o .: "encoding"
      <*> o .: "compressed"
      <*> o .: "tx_count"
      <*> o .: "bytes"
      <*> o .: "origin"
      <*> o .:? "hints"

data CorpusAnnounce = CorpusAnnounce
  { seqNum :: Int
  , entry :: EntryMeta
  } deriving (Show, Eq)

instance FromJSON CorpusAnnounce where
  parseJSON = withObject "CorpusAnnounce" $ \o ->
    CorpusAnnounce
      <$> o .: "seq"
      <*> o .: "entry"

data CorpusEntry = CorpusEntry
  { entryMeta :: EntryMeta
  , txs :: [Tx]
  } deriving (Show, Eq)

instance FromJSON CorpusEntry where
  parseJSON = withObject "CorpusEntry" $ \o ->
    CorpusEntry
      <$> o .: "entry"
      <*> o .: "txs"

data CorpusSinceItem = CorpusSinceItem
  { sinceSeq :: Int
  , sinceEntry :: EntryMeta
  } deriving (Show, Eq)

instance FromJSON CorpusSinceItem where
  parseJSON = withObject "CorpusSinceItem" $ \o ->
    CorpusSinceItem
      <$> o .: "seq"
      <*> o .: "entry"

data CorpusSince = CorpusSince
  { fromSeq :: Int
  , toSeq :: Int
  , entries :: [CorpusSinceItem]
  , truncated :: Bool
  } deriving (Show, Eq)

instance FromJSON CorpusSince where
  parseJSON = withObject "CorpusSince" $ \o ->
    CorpusSince
      <$> o .: "from_seq"
      <*> o .: "to_seq"
      <*> o .: "entries"
      <*> o .: "truncated"

data FleetStop = FleetStop
  { stopReason :: Text
  , failureId :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON FleetStop where
  parseJSON = withObject "FleetStop" $ \o ->
    FleetStop
      <$> o .: "reason"
      <*> o .:? "failure_id"

mkHello
  :: Text
  -> Text -- ^ instance_id
  -> Text -- ^ client version
  -> Maybe Int -- ^ resume since_seq
  -> Maybe Text -- ^ bearer token
  -> IO Envelope
mkHello campaignFingerprint instanceId clientVersion sinceSeq token = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "hello"
    , msgId = msgId
    , ts = now
    , campaign = campaignFingerprint
    , payload = object
        [ "instance_id" .= instanceId
        , "client" .= object ["name" .= ("echidna" :: Text), "version" .= clientVersion]
        , "capabilities" .= object
            [ "max_msg_bytes" .= (1048576 :: Int)
            , "supports_binary" .= False
            , "supports_zstd" .= False
            , "supports_resume" .= True
            ]
        , "resume" .= object ["since_seq" .= sinceSeq]
        , "auth" .= case token of
            Nothing -> Null
            Just t -> object ["type" .= ("bearer" :: Text), "token" .= t]
        ]
    }

mkCorpusPublish
  :: Text -- ^ campaign fingerprint
  -> EntryMeta
  -> [Tx]
  -> IO Envelope
mkCorpusPublish camp entry txs = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "corpus_publish"
    , msgId = msgId
    , ts = now
    , campaign = camp
    , payload = object
        [ "entry" .= entry
        , "txs" .= txs
        ]
    }

-- | Publish multiple entries in one message (protocol v2 extension).
--
-- Payload: { "items": [ { "entry": EntryMeta, "txs": [Tx] } ] }
mkCorpusPublishBatch
  :: Text -- ^ campaign fingerprint
  -> [(EntryMeta, [Tx])]
  -> IO Envelope
mkCorpusPublishBatch camp items = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "corpus_publish_batch"
    , msgId = msgId
    , ts = now
    , campaign = camp
    , payload = object
        [ "items" .= fmap (\(entry, txs) -> object ["entry" .= entry, "txs" .= txs]) items
        ]
    }

mkCorpusGet :: Text -> Text -> IO Envelope
mkCorpusGet camp entryId = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "corpus_get"
    , msgId = msgId
    , ts = now
    , campaign = camp
    , payload = object ["entry_id" .= entryId]
    }

-- | Request a page of corpus metadata newer than `since_seq` (exclusive).
--
-- Payload: { "since_seq": Int, "limit": Int }
mkCorpusSinceRequest :: Text -> Int -> Int -> IO Envelope
mkCorpusSinceRequest camp sinceSeq limit = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "corpus_since_request"
    , msgId = msgId
    , ts = now
    , campaign = camp
    , payload = object
        [ "since_seq" .= sinceSeq
        , "limit" .= limit
        ]
    }

mkFailurePublish
  :: Text -- ^ campaign fingerprint
  -> Text -- ^ instance_id
  -> Text -- ^ failure_id
  -> Text -- ^ test_name
  -> EntryMeta -- ^ reproducer meta
  -> [Tx] -- ^ reproducer txs
  -> IO Envelope
mkFailurePublish camp instanceId failureId testName reproMeta reproTxs = do
  now <- getCurrentTime
  msgId <- Just <$> newMsgId
  pure $ Envelope
    { v = 1
    , msgType = "failure_publish"
    , msgId = msgId
    , ts = now
    , campaign = camp
    , payload = object
        [ "failure" .= object
            [ "failure_id" .= failureId
            , "test_name" .= testName
            ]
        , "reproducer" .= object
            [ "entry_id" .= reproMeta.entryId
            , "encoding" .= reproMeta.encoding
            , "compressed" .= reproMeta.compressed
            , "txs" .= reproTxs
            , "origin" .= object ["instance_id" .= instanceId]
            ]
        ]
    }
