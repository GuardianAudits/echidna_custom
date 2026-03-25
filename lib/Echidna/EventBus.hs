module Echidna.EventBus
  ( EventBus
  , EventSubscription
  , newEventBus
  , publishEvent
  , subscribeEventBus
  , readEvent
  ) where

import Control.Concurrent.STM (TChan, atomically, dupTChan, newBroadcastTChan, readTChan, writeTChan)

newtype EventBus a = EventBus (TChan a)

newtype EventSubscription a = EventSubscription (TChan a)

newEventBus :: IO (EventBus a)
newEventBus = EventBus <$> atomically newBroadcastTChan

publishEvent :: EventBus a -> a -> IO ()
publishEvent (EventBus ch) event = atomically $ writeTChan ch event

subscribeEventBus :: EventBus a -> IO (EventSubscription a)
subscribeEventBus (EventBus ch) = EventSubscription <$> atomically (dupTChan ch)

readEvent :: EventSubscription a -> IO a
readEvent (EventSubscription ch) = atomically $ readTChan ch
