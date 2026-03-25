module Echidna.CoverageArtifacts
  ( cacheCoverageTxs
  , lookupCoverageTxs
  , coverageArtifactCacheLimit
  ) where

import Data.IORef (atomicModifyIORef', readIORef)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)

import Echidna.CorpusSync.Hash (entryIdForTxs)
import Echidna.Recent (insertRecent, lookupRecent)
import Echidna.Types.Config (Env(..))
import Echidna.Types.Tx (Tx)

coverageArtifactCacheLimit :: Int
coverageArtifactCacheLimit = 4096

cacheCoverageTxs :: Env -> [Tx] -> IO ()
cacheCoverageTxs env txs =
  let entryId = entryIdForTxs txs
  in atomicModifyIORef' env.coverageArtifacts $ \recent ->
       (insertRecent entryId txs recent, ())

lookupCoverageTxs :: Env -> Text -> IO (Maybe [Tx])
lookupCoverageTxs env entryId = do
  recent <- readIORef env.coverageArtifacts
  case lookupRecent entryId recent of
    Just txs -> pure (Just txs)
    Nothing -> do
      corpus <- readIORef env.corpusRef
      let found = snd <$> find ((== entryId) . entryIdForTxs . snd) (Set.toList corpus)
      case found of
        Just txs -> do
          cacheCoverageTxs env txs
          pure (Just txs)
        Nothing -> pure Nothing
