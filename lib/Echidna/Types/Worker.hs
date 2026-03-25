{-# LANGUAGE RecordWildCards #-}

module Echidna.Types.Worker where

import Data.Aeson (ToJSON(..), object, (.=))
import Data.Text (Text, pack)

import EVM.Types (Addr)

import Echidna.ABI (encodeSig)
import Echidna.Types.Test
import Echidna.Types.Signature (SolSignature)
import Echidna.Types.Tx

data EventTestType
  = EventPropertyTest Text Addr
  | EventOptimizationTest Text Addr
  | EventAssertionTest Bool SolSignature Addr
  | EventCallTest Text
  | EventExploration
  deriving (Show)

instance ToJSON EventTestType where
  toJSON = \case
    EventPropertyTest name addr ->
      object [ "type" .= ("property_test" :: String), "name" .= name, "addr" .= addr ]
    EventOptimizationTest name addr ->
      object [ "type" .= ("optimization_test" :: String), "name" .= name, "addr" .= addr ]
    EventAssertionTest _ sig addr ->
      object [ "type" .= ("assertion_test" :: String), "signature" .= sig, "addr" .= addr ]
    EventCallTest name ->
      object [ "type" .= ("call_test" :: String), "name" .= name ]
    EventExploration ->
      object [ "type" .= ("exploration_test" :: String) ]

data EventTest = EventTest
  { state :: TestState
  , testType :: EventTestType
  , value :: TestValue
  , reproducer :: [Tx]
  , result :: TxResult
  , workerId :: Maybe Int
  } deriving (Show)

instance ToJSON EventTest where
  toJSON EventTest{..} = object
    [ "state" .= state
    , "type" .= testType
    , "value" .= value
    , "reproducer" .= reproducer
    , "result" .= result
    ]

data WorkerType = FuzzWorker | SymbolicWorker deriving (Eq)

type WorkerId = Int

data CampaignEvent
  = WorkerEvent WorkerId WorkerType WorkerEvent
  | Failure String
  | ReproducerSaved String -- filename

data WorkerEvent
  = TestFalsified !EventTest
  | TestOptimized !EventTest
  | NewCoverage { points :: !Int, numCodehashes :: !Int, corpusSize :: !Int, coverageEntryId :: !Text }
  | SymExecError !String
  | SymExecLog !String
  | TxSequenceReplayed FilePath !Int !Int
  | TxSequenceReplayFailed FilePath Tx
  | WorkerStopped WorkerStopReason
  -- ^ This is a terminal event. Worker exits and won't push any events after
  -- this one
  deriving Show

data WorkerStopReason
  = TestLimitReached
  | SymbolicExplorationDone
  | SymbolicVerificationDone
  | TimeLimitReached
  | FastFailed
  | Killed !String
  | Crashed !String
  deriving Show

mkEventTest :: EchidnaTest -> EventTest
mkEventTest test =
  EventTest
    { state = test.state
    , testType = mkEventTestType test.testType
    , value = test.value
    , reproducer = test.reproducer
    , result = test.result
    , workerId = test.workerId
    }

mkEventTestType :: TestType -> EventTestType
mkEventTestType = \case
  PropertyTest name addr -> EventPropertyTest name addr
  OptimizationTest name addr -> EventOptimizationTest name addr
  AssertionTest isView sig addr -> EventAssertionTest isView sig addr
  CallTest name _ -> EventCallTest name
  Exploration -> EventExploration

eventTestName :: EventTest -> Text
eventTestName test =
  case test.testType of
    EventPropertyTest name _ -> name
    EventOptimizationTest name _ -> name
    EventAssertionTest _ sig _ -> encodeSig sig
    EventCallTest name -> name
    EventExploration -> "exploration"

eventTestCorpusName :: EventTest -> Text
eventTestCorpusName test =
  case test.testType of
    EventPropertyTest name _ -> name
    EventOptimizationTest name _ -> name
    EventAssertionTest _ sig _ -> pack (show sig)
    EventCallTest name -> name
    EventExploration -> "exploration"
