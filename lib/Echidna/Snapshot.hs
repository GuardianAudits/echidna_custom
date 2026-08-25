module Echidna.Snapshot
  ( PrefixSnapshotCache(..)
  , PrefixRestore(..)
  , MutationPlan(..)
  , SnapshotStats(..)
  , VmFingerprint(..)
  , emptyPrefixSnapshotCache
  , emptySnapshotStats
  , noPlan
  , firstDiffIndex
  , nearestPrefix
  , snapshotKeepIndices
  , shouldKeepSnapshot
  , restorePrefix
  , mkPrefixSnapshot
  , vmFingerprint
  , fingerprintsMatch
  , defaultSnapshotPrefixes
  , defaultMaxSnapshotsPerSequence
  , defaultMutationBatchSize
  , recordSnapshotStats
  , mergeSnapshotStats
  , parentKey
  , snapshotReuseAllowed
  , ppSnapshotStats
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.ST (stToIO)
import Data.Hashable (hash)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet
import Data.List (foldl')
import Data.Map.Strict qualified as Map

import EVM (blankState)
import EVM.Types hiding (Env)

import Echidna.Events (emptyEvents)
import Echidna.Types.Tx (Tx)

-- | Candidate sequence plus the corpus parent it was derived from.
-- 'planParent' is the original prefix the mutator selected, not the last
-- sequence this worker happened to execute.
data MutationPlan = MutationPlan
  { planParent    :: Maybe [Tx]
  , planCandidate :: [Tx]
  }

noPlan :: [Tx] -> MutationPlan
noPlan txs = MutationPlan Nothing txs

-- | Stable cache/batch key for a corpus parent. Avoids comparing full
-- sequences on the fuzz hot path.
parentKey :: [Tx] -> Int
parentKey = hash

-- | Worker-local cache keyed by 'parentKey', not the raw transaction list.
data PrefixSnapshotCache = PrefixSnapshotCache
  { cachedParentKey :: !(Maybe Int)
    -- ^ 'parentKey' of the corpus parent stored in 'snapshots'.
  , snapshots       :: !(IntMap (VM Concrete))
    -- ^ Bounded map: prefix length → continuation VM after that many parent txs.
  , snapFingerprint :: !(Maybe VmFingerprint)
    -- ^ Starting-VM identity required for reuse.
  }

emptyPrefixSnapshotCache :: PrefixSnapshotCache
emptyPrefixSnapshotCache =
  PrefixSnapshotCache Nothing IntMap.empty Nothing

data VmFingerprint = VmFingerprint
  { fpBlock        :: !W256Like
  , fpTimestamp    :: !W256Like
  , fpNContracts   :: !Int
  , fpAddrSum      :: !W256Like
  , fpCodehashSum  :: !W256Like
  , fpBalanceSum   :: !W256Like
  , fpNonceSum     :: !W256Like
  , fpStorageSum   :: !W256Like
  } deriving (Eq, Show)

-- | Avoid importing W256 into the Campaign type file; store as Integer.
type W256Like = Integer

data SnapshotStats = SnapshotStats
  { snapLookups    :: !Int
  , snapHits       :: !Int
  , snapExactHits  :: !Int
  , snapSkipped    :: !Int
  , snapGapReplay  :: !Int
  , snapMisses     :: !Int
  } deriving (Eq, Show)

emptySnapshotStats :: SnapshotStats
emptySnapshotStats = SnapshotStats 0 0 0 0 0 0

recordSnapshotStats :: PrefixRestore -> SnapshotStats -> SnapshotStats
recordSnapshotStats restore stats =
  let lookups' = stats.snapLookups + 1
  in if restore.restoreFrom <= 0
       then stats { snapLookups = lookups', snapMisses = stats.snapMisses + 1 }
       else
         let exact = restore.restoreExact
             gap = restore.restoreLen - restore.restoreFrom
         in stats
              { snapLookups   = lookups'
              , snapHits      = stats.snapHits + 1
              , snapExactHits = stats.snapExactHits + (if exact then 1 else 0)
              , snapSkipped   = stats.snapSkipped + restore.restoreFrom
              , snapGapReplay = stats.snapGapReplay + max 0 gap
              }

mergeSnapshotStats :: SnapshotStats -> SnapshotStats -> SnapshotStats
mergeSnapshotStats a b = SnapshotStats
  { snapLookups   = a.snapLookups + b.snapLookups
  , snapHits      = a.snapHits + b.snapHits
  , snapExactHits = a.snapExactHits + b.snapExactHits
  , snapSkipped   = a.snapSkipped + b.snapSkipped
  , snapGapReplay = a.snapGapReplay + b.snapGapReplay
  , snapMisses    = a.snapMisses + b.snapMisses
  }

ppSnapshotStats :: SnapshotStats -> String
ppSnapshotStats s =
  "snapshots: " <> show s.snapHits <> "/" <> show s.snapLookups
  <> " hits, skip " <> show s.snapSkipped
  <> ", gap " <> show s.snapGapReplay
  <> ", exact " <> show s.snapExactHits
  <> ", miss " <> show s.snapMisses

-- | FFI and RPC @latest@ are not replay-stable; refuse cache reuse.
snapshotReuseAllowed :: Bool -> Bool -> Bool
snapshotReuseAllowed allowFFI rpcLatest = not allowFFI && not rpcLatest

-- | Restore parent-sequence VMs at the mutation index. Disable with
-- @snapshotPrefixes: false@.
defaultSnapshotPrefixes :: Bool
defaultSnapshotPrefixes = True

defaultMaxSnapshotsPerSequence :: Int
defaultMaxSnapshotsPerSequence = 64

-- | Consecutive mutations of one parent, including the first (cache-filling)
-- mutation. Not a separate parent-seed iteration.
defaultMutationBatchSize :: Int
defaultMutationBatchSize = 8

firstDiffIndex :: Eq a => [a] -> [a] -> Int
firstDiffIndex = go 0
  where
    go i (x:xs) (y:ys)
      | x == y    = go (i + 1) xs ys
      | otherwise = i
    go i _ _ = i

nearestPrefix :: IntMap a -> Int -> Maybe (Int, a)
nearestPrefix snaps k
  | k <= 0 = Nothing
  | otherwise =
      case IntMap.splitLookup k snaps of
        (_lo, Just v, _) -> Just (k, v)
        (loMap, Nothing, _) -> IntMap.lookupMax loMap

snapshotKeepIndices :: Int -> Int -> IntSet
snapshotKeepIndices maxN seqLen
  | maxN <= 0 || seqLen <= 0 = IntSet.empty
  | seqLen <= maxN = IntSet.fromList [1 .. seqLen]
  | maxN == 1 = IntSet.singleton seqLen
  | otherwise = IntSet.fromList
      [ 1 + (i * (seqLen - 1)) `div` (maxN - 1) | i <- [0 .. maxN - 1] ]

shouldKeepSnapshot :: Int -> Int -> Int -> Bool
shouldKeepSnapshot maxN seqLen idx =
  IntSet.member idx (snapshotKeepIndices maxN seqLen)

data PrefixRestore = PrefixRestore
  { restoreLen   :: Int
    -- ^ Shared prefix length (first differing index).
  , restoreFrom  :: Int
    -- ^ Snapshot key actually restored (nearest kept ≤ restoreLen).
  , restoreVM    :: VM Concrete
  , restoreExact :: Bool
  }

restorePrefix
  :: PrefixSnapshotCache
  -> VM Concrete
  -> MutationPlan
  -> PrefixRestore
restorePrefix cache initialVM plan =
  case plan.planParent of
    Just parent
      | not (null parent)
      , cache.cachedParentKey == Just (parentKey parent)
      , fingerprintsMatch cache.snapFingerprint initialVM ->
          let k = firstDiffIndex parent plan.planCandidate
          in case nearestPrefix cache.snapshots k of
               Just (j, vm) ->
                 PrefixRestore k j vm (j == k)
               Nothing -> PrefixRestore 0 0 initialVM False
    _ -> PrefixRestore 0 0 initialVM False

vmFingerprint :: VM Concrete -> VmFingerprint
vmFingerprint vm =
  let Block { number = n, timestamp = ts } = vm.block
      contracts = Map.toList vm.env.contracts
  in VmFingerprint
       { fpBlock       = toInteger (forceLit n)
       , fpTimestamp   = toInteger (forceLit ts)
       , fpNContracts  = length contracts
       , fpAddrSum     = foldl' (\acc (addr, _) -> acc + toInteger (hash (show addr))) 0 contracts
       , fpCodehashSum = foldl' (\acc (_, c) -> acc + toInteger (forceLit c.codehash)) 0 contracts
       , fpBalanceSum  = foldl' (\acc (_, c) -> acc + toInteger (forceLit c.balance)) 0 contracts
       , fpNonceSum    = foldl' (\acc (_, c) -> acc + maybe 0 toInteger c.nonce) 0 contracts
       , fpStorageSum  = foldl' (\acc (_, c) -> acc + storageFingerprint c.storage) 0 contracts
       }

storageFingerprint :: Expr Storage -> Integer
storageFingerprint (ConcreteStore s) = toInteger (hash (Map.toList s))
storageFingerprint _ = 0

fingerprintsMatch :: Maybe VmFingerprint -> VM Concrete -> Bool
fingerprintsMatch Nothing _ = False
fingerprintsMatch (Just fp) vm = fp == vmFingerprint vm

-- | Continuation snapshot: drop per-tx mutable memory, frames, traces, logs,
-- bookkeeping, and 'txReversion' so retained VMs do not pin rollback maps.
mkPrefixSnapshot :: MonadIO m => VM Concrete -> m (VM Concrete)
mkPrefixSnapshot vm = liftIO $ stToIO $ do
  state' <- blankState
  let tx' = vm.tx { txReversion = mempty }
  pure vm
    { result = Nothing
    , state = state'
    , frames = []
    , logs = []
    , traces = emptyEvents
    , tx = tx'
    , pathsVisited = mempty
    , iterations = mempty
    , constraints = mempty
    , keccakPreImgs = mempty
    }
