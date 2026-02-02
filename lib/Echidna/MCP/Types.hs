{-# LANGUAGE RecordWildCards #-}

module Echidna.MCP.Types
  ( MCPEvent(..)
  , MCPRevert(..)
  , MCPTrace(..)
  , MCPTx(..)
  , HandlerStat(..)
  , MCPRunCounters(..)
  ) where

import Data.Aeson (ToJSON(..), Value, object, (.=))
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
