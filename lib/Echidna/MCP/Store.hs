module Echidna.MCP.Store
  ( RingBuffer
  , newRingBuffer
  , pushRing
  , readSince
  , readById
  , MCPState(..)
  , MCPControl(..)
  , newMCPState
  , pauseMCP
  , resumeMCP
  , requestStopMCP
  , waitIfPaused
  ) where

import Control.Concurrent.MVar (MVar, newMVar, readMVar, tryPutMVar, tryTakeMVar)
import Data.Foldable qualified as Foldable
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import EVM.Types (FunctionSelector, CheatCallStats)
import Echidna.LogicalCoverage.Types (LogicalCoverage)

import Echidna.MCP.Types
  ( MCPEvent
  , MCPRevert
  , MCPTrace
  , MCPTx
  , HandlerStat
  , MCPRunCounters(..)
  )

data RingBuffer a = RingBuffer
  { maxSize :: Int
  , nextId  :: Int
  , items   :: Seq (Int, a)
  }

newRingBuffer :: Int -> IO (IORef (RingBuffer a))
newRingBuffer size = newIORef (RingBuffer size 0 Seq.empty)

pushRing :: IORef (RingBuffer a) -> (Int -> a) -> IO Int
pushRing ref mkItem =
  atomicModifyIORef' ref $ \rb ->
    let
      newId = rb.nextId
      items' = rb.items Seq.|> (newId, mkItem newId)
      overflow = Seq.length items' - rb.maxSize
      trimmed = if overflow > 0 then Seq.drop overflow items' else items'
      rb' = rb { nextId = newId + 1, items = trimmed }
    in (rb', newId)

readSince :: IORef (RingBuffer a) -> Int -> Int -> IO [(Int, a)]
readSince ref since limit = do
  rb <- readIORef ref
  let entries = filter (\(i, _) -> i > since) (toList rb.items)
  pure $ take limit entries
  where
    toList = Foldable.toList

readById :: IORef (RingBuffer a) -> Int -> IO (Maybe a)
readById ref target = do
  rb <- readIORef ref
  pure $ lookup target (Foldable.toList rb.items)

data MCPControl = MCPControl
  { pauseGate :: MVar ()
  , stopFlag  :: IORef Bool
  }

data MCPState = MCPState
  { events     :: IORef (RingBuffer MCPEvent)
  , reverts    :: IORef (RingBuffer MCPRevert)
  , traces     :: IORef (RingBuffer MCPTrace)
  , txs        :: IORef (RingBuffer MCPTx)
  , handlers   :: IORef (Map Text HandlerStat)
  , logicalByWorker :: IORef (Map Int LogicalCoverage)
  , cheatByWorker :: IORef (Map Int (Map FunctionSelector CheatCallStats))
  , counters   :: IORef MCPRunCounters
  , control    :: MCPControl
  , phase      :: IORef Text
  }

newMCPState :: Int -> Int -> Int -> IO MCPState
newMCPState maxEvents maxReverts maxTxs = do
  eventsRef <- newRingBuffer maxEvents
  revertsRef <- newRingBuffer maxReverts
  tracesRef <- newRingBuffer maxReverts
  txsRef <- newRingBuffer maxTxs
  handlersRef <- newIORef mempty
  logicalRef <- newIORef mempty
  cheatRef <- newIORef mempty
  countersRef <- newIORef (MCPRunCounters 0 0 0)
  gate <- newMVar ()
  stopRef <- newIORef False
  phaseRef <- newIORef "running"
  pure MCPState
    { events = eventsRef
    , reverts = revertsRef
    , traces = tracesRef
    , txs = txsRef
    , handlers = handlersRef
    , logicalByWorker = logicalRef
    , cheatByWorker = cheatRef
    , counters = countersRef
    , control = MCPControl gate stopRef
    , phase = phaseRef
    }

pauseMCP :: MCPState -> IO ()
pauseMCP st = do
  _ <- tryTakeMVar st.control.pauseGate
  pure ()

resumeMCP :: MCPState -> IO ()
resumeMCP st = do
  _ <- tryPutMVar st.control.pauseGate ()
  pure ()

requestStopMCP :: MCPState -> IO ()
requestStopMCP st = do
  writeIORef st.control.stopFlag True
  _ <- tryPutMVar st.control.pauseGate ()
  pure ()

waitIfPaused :: MCPState -> IO Bool
waitIfPaused st = do
  _ <- readMVar st.control.pauseGate
  readIORef st.control.stopFlag
