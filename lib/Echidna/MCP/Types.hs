{-# LANGUAGE RecordWildCards #-}

module Echidna.MCP.Types
  ( MCPEvent(..)
  , MCPRevert(..)
  , MCPTrace(..)
  , MCPTx(..)
  , MCPReproducerArtifact(..)
  , MCPReproducerStatus(..)
  , MCPReproducerJob(..)
  , MCPReproducerJobStatus(..)
  , MCPReproducerJobPriority(..)
  , MCPReproducerEvent(..)
  , MCPReproducerTxSet(..)
  , MCPReproducerShrink(..)
  , MCPReproducerOrigin(..)
  , HandlerStat(..)
  , MCPRunCounters(..)
  ) where

import Data.Aeson (ToJSON(..), Value, object, (.=))
import Data.Time (UTCTime)
import Data.Text (Text)

import Echidna.Types.Tx (Tx)

data MCPEvent = MCPEvent
  { eventId    :: Int
  , timestamp  :: Text
  , workerId   :: Maybe Int
  , workerType :: Maybe Text
  , eventType  :: Text
  , payload    :: Value
  }

instance ToJSON MCPEvent where
  toJSON MCPEvent{..} = object
    [ "id" .= eventId
    , "ts" .= timestamp
    , "workerId" .= workerId
    , "workerType" .= workerType
    , "type" .= eventType
    , "payload" .= payload
    ]

data MCPRevert = MCPRevert
  { revertId   :: Int
  , timestamp  :: Text
  , contract   :: Text
  , selector   :: Maybe Text
  , reason     :: Text
  , sender     :: Text
  , recipient  :: Text
  , tx         :: Tx
  , traceId    :: Maybe Int
  }

instance ToJSON MCPRevert where
  toJSON MCPRevert{..} = object
    [ "id" .= revertId
    , "ts" .= timestamp
    , "contract" .= contract
    , "selector" .= selector
    , "reason" .= reason
    , "sender" .= sender
    , "recipient" .= recipient
    , "tx" .= tx
    , "traceId" .= traceId
    ]

data MCPTrace = MCPTrace
  { traceId   :: Int
  , timestamp :: Text
  , selector  :: Maybe Text
  , reason    :: Text
  , trace     :: Text
  }

instance ToJSON MCPTrace where
  toJSON MCPTrace{..} = object
    [ "id" .= traceId
    , "ts" .= timestamp
    , "selector" .= selector
    , "reason" .= reason
    , "trace" .= trace
    ]

data MCPTx = MCPTx
  { txId      :: Int
  , timestamp :: Text
  , method    :: Maybe Text
  , success   :: Bool
  , reason    :: Maybe Text
  , tx        :: Tx
  }

instance ToJSON MCPTx where
  toJSON MCPTx{..} = object
    [ "id" .= txId
    , "ts" .= timestamp
    , "method" .= method
    , "success" .= success
    , "reason" .= reason
    , "tx" .= tx
    ]

data HandlerStat = HandlerStat
  { totalCalls   :: Int
  , successCalls :: Int
  , failedCalls  :: Int
  , lastArgs     :: [Text]
  , lastSeen     :: Text
  }

instance ToJSON HandlerStat where
  toJSON HandlerStat{..} = object
    [ "totalCalls" .= totalCalls
    , "successCalls" .= successCalls
    , "failedCalls" .= failedCalls
    , "lastArgs" .= lastArgs
    , "lastSeen" .= lastSeen
    ]

data MCPReproducerStatus
  = MCPReproducerUnknown
  | MCPReproducerIdle
  | MCPReproducerActive
  | MCPReproducerQueued
  | MCPReproducerComplete
  | MCPReproducerFailed
  deriving (Eq, Ord, Show)

instance ToJSON MCPReproducerStatus where
  toJSON = \case
    MCPReproducerUnknown -> "unknown"
    MCPReproducerIdle -> "idle"
    MCPReproducerActive -> "active"
    MCPReproducerQueued -> "queued"
    MCPReproducerComplete -> "complete"
    MCPReproducerFailed -> "failed"

data MCPReproducerJobStatus
  = MCPReproducerJobQueued
  | MCPReproducerJobActive
  | MCPReproducerJobComplete
  | MCPReproducerJobFailed
  | MCPReproducerJobCanceled
  deriving (Eq, Ord, Show)

instance ToJSON MCPReproducerJobStatus where
  toJSON = \case
    MCPReproducerJobQueued -> "queued"
    MCPReproducerJobActive -> "active"
    MCPReproducerJobComplete -> "complete"
    MCPReproducerJobFailed -> "failed"
    MCPReproducerJobCanceled -> "canceled"

data MCPReproducerJobPriority = MCPReproducerPriorityLow | MCPReproducerPriorityNormal | MCPReproducerPriorityHigh
  deriving (Eq, Ord, Show)

instance ToJSON MCPReproducerJobPriority where
  toJSON = \case
    MCPReproducerPriorityLow -> "low"
    MCPReproducerPriorityNormal -> "normal"
    MCPReproducerPriorityHigh -> "high"

data MCPReproducerEvent = MCPReproducerEvent
  { reproducerEventId    :: Int
  , reproducerEventTs    :: Text
  , reproducerEventType  :: Text
  , reproducerEventKey   :: Text
  , reproducerEventTestKey :: Text
  , reproducerEventPayload :: Value
  }

instance ToJSON MCPReproducerEvent where
  toJSON MCPReproducerEvent{..} = object
    [ "id" .= reproducerEventId
    , "ts" .= reproducerEventTs
    , "type" .= reproducerEventType
    , "key" .= reproducerEventKey
    , "testKey" .= reproducerEventTestKey
    , "payload" .= reproducerEventPayload
    ]

data MCPReproducerTxSet = MCPReproducerTxSet
  { reproducerLatest :: [Tx]
  , reproducerBest :: [Tx]
  , reproducerCandidate :: [Tx]
  } deriving Show

instance ToJSON MCPReproducerTxSet where
  toJSON MCPReproducerTxSet{..} = object
    [ "latest" .= reproducerLatest
    , "best" .= reproducerBest
    , "candidate" .= reproducerCandidate
    , "length" .= object
        [ "latest" .= length reproducerLatest
        , "best" .= length reproducerBest
        , "candidate" .= length reproducerCandidate
        ]
    ]

data MCPReproducerShrink = MCPReproducerShrink
  { shrinkStatus :: MCPReproducerStatus
  , shrinkFullyShrunk :: Bool
  , shrinkLastUpdatedAt :: Maybe UTCTime
  , shrinkAttempts :: Int
  , shrinkStableSince :: Maybe UTCTime
  , shrinkNoProgressCount :: Int
  } deriving Show

instance ToJSON MCPReproducerShrink where
  toJSON MCPReproducerShrink{..} = object
    [ "status" .= shrinkStatus
    , "fullyShrunk" .= shrinkFullyShrunk
    , "lastUpdatedAt" .= shrinkLastUpdatedAt
    , "shrinkAttempts" .= shrinkAttempts
    , "stableSince" .= shrinkStableSince
    , "noProgressCount" .= shrinkNoProgressCount
    ]

data MCPReproducerOrigin = MCPReproducerOrigin
  { originEventId :: Maybe Int
  , originIsFromWorker :: Maybe Bool
  , originSourceRunId :: Text
  } deriving Show

instance ToJSON MCPReproducerOrigin where
  toJSON MCPReproducerOrigin{..} = object
    [ "eventId" .= originEventId
    , "isFromWorker" .= originIsFromWorker
    , "sourceRunId" .= originSourceRunId
    ]

data MCPReproducerArtifact = MCPReproducerArtifact
  { testKey        :: Text
  , testId         :: Text
  , workerId       :: Maybe Int
  , testType       :: Text
  , testState      :: Text
  , campaignId     :: Text
  , reproducer     :: MCPReproducerTxSet
  , shrink         :: MCPReproducerShrink
  , origin         :: Maybe MCPReproducerOrigin
  , coverage       :: Maybe Value
  , updatedAt      :: UTCTime
  }

instance ToJSON MCPReproducerArtifact where
  toJSON MCPReproducerArtifact{..} = object
    [ "testKey" .= testKey
    , "testId" .= testId
    , "workerId" .= workerId
    , "testType" .= testType
    , "state" .= testState
    , "campaignId" .= campaignId
    , "reproducer" .= reproducer
    , "shrink" .= shrink
    , "origin" .= origin
    , "coverage" .= coverage
    , "updatedAt" .= updatedAt
    ]

data MCPReproducerJob = MCPReproducerJob
  { jobId      :: Text
  , testKey    :: Text
  , status     :: MCPReproducerJobStatus
  , priority   :: MCPReproducerJobPriority
  , retries    :: Int
  , workerHint :: Maybe Text
  , createdAt  :: UTCTime
  , updatedAt  :: UTCTime
  , force      :: Bool
  , reason     :: Maybe Text
  , lastError  :: Maybe Text
  }

instance ToJSON MCPReproducerJob where
  toJSON MCPReproducerJob{..} = object
    [ "jobId" .= jobId
    , "testKey" .= testKey
    , "status" .= status
    , "priority" .= priority
    , "retries" .= retries
    , "workerHint" .= workerHint
    , "createdAt" .= createdAt
    , "updatedAt" .= updatedAt
    , "force" .= force
    , "reason" .= reason
    , "lastError" .= lastError
    ]

data MCPRunCounters = MCPRunCounters
  { totalCalls    :: Int
  , successCalls  :: Int
  , failedCalls   :: Int
  }

instance ToJSON MCPRunCounters where
  toJSON MCPRunCounters{..} = object
    [ "totalCalls" .= totalCalls
    , "successCalls" .= successCalls
    , "failedCalls" .= failedCalls
    ]
