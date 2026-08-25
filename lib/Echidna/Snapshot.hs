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
  , seedParentCache
  , lookupParentSnaps
  , defaultSnapshotPrefixes
  , defaultMaxSnapshotsPerSequence
  , defaultMutationBatchSize
  , recordSnapshotStats
  , mergeSnapshotStats
  , parentKey
  , snapshotReuseAllowed
  , snapshotSkipReason
  , SnapshotMutators(..)
  , defaultSnapshotMutators
  , recordIneligible
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

-- | Worker-local caches keyed by 'parentKey'. The active slot is the parent
-- we last wrote; 'savedParents' holds at most one extra parent so a sequence
-- that just entered the corpus can be selected later without a miss.
data PrefixSnapshotCache = PrefixSnapshotCache
  { cachedParentKey :: !(Maybe Int)
  , snapshots       :: !(IntMap (VM Concrete))
  , snapFingerprint :: !(Maybe VmFingerprint)
  , savedParents    :: !(IntMap (VmFingerprint, IntMap (VM Concrete)))
  , lastCollected   :: !(IntMap (VM Concrete))
    -- ^ Prefix VMs from the sequence that just ran, used to seed a corpus entry.
  }

emptyPrefixSnapshotCache :: PrefixSnapshotCache
emptyPrefixSnapshotCache =
  PrefixSnapshotCache Nothing IntMap.empty Nothing IntMap.empty IntMap.empty

lookupParentSnaps
  :: PrefixSnapshotCache
  -> [Tx]
  -> VM Concrete
  -> Maybe (IntMap (VM Concrete))
lookupParentSnaps cache parent vm0 =
  let key = parentKey parent
  in if cache.cachedParentKey == Just key && fingerprintsMatch cache.snapFingerprint vm0
       then Just cache.snapshots
       else case IntMap.lookup key cache.savedParents of
         Just (fp, snaps) | fingerprintsMatch (Just fp) vm0 -> Just snaps
         _ -> Nothing

-- | Install 'snaps' as the active cache for 'txs'. Parks the previous active
-- parent instead of dropping it, so an ineligible seq does not have to be
-- the one that wipes the cache (callers skip this on ineligible).
seedParentCache
  :: PrefixSnapshotCache
  -> [Tx]
  -> VM Concrete
  -> IntMap (VM Concrete)
  -> PrefixSnapshotCache
seedParentCache cache txs vm0 snaps
  | IntMap.null snaps = cache { lastCollected = snaps }
  | otherwise =
      let key = parentKey txs
          fp = vmFingerprint vm0
          parked =
            case (cache.cachedParentKey, cache.snapFingerprint) of
              (Just k, Just pfp)
                | k /= key && not (IntMap.null cache.snapshots) ->
                    IntMap.singleton k (pfp, cache.snapshots)
              _ -> IntMap.delete key cache.savedParents
      in PrefixSnapshotCache
           { cachedParentKey = Just key
           , snapshots = snaps
           , snapFingerprint = Just fp
           , savedParents = parked
           , lastCollected = snaps
           }

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
    -- ^ Eligible sequences that entered the snapshot runner.
  , snapHits       :: !Int
  , snapExactHits  :: !Int
  , snapSkipped    :: !Int
    -- ^ Prefix transactions skipped on a hit.
  , snapGapReplay  :: !Int
  , snapMisses     :: !Int
  , snapIneligible :: !Int
    -- ^ Sequences with no snapshot parent (prepend/splice/interleave, empty corpus).
  } deriving (Eq, Show)

emptySnapshotStats :: SnapshotStats
emptySnapshotStats = SnapshotStats 0 0 0 0 0 0 0

-- | Prepend/splice/interleave (and empty-parent seqs) run the baseline runner.
recordIneligible :: SnapshotStats -> SnapshotStats
recordIneligible stats = stats { snapIneligible = stats.snapIneligible + 1 }

-- | Search policy when snapshots are on. Default keeps Echidna's mutator mix.
data SnapshotMutators
  = SnapshotMutatorsOriginal
    -- ^ Unchanged append/prepend/splice/interleave weights.
  | SnapshotMutatorsAppendOnly
    -- ^ Only prefix-preserving append mutations.
  | SnapshotMutatorsSticky
    -- ^ @mutationBatchSize - 1@ append siblings, then one unrestricted mutation.
  deriving (Eq, Show)

defaultSnapshotMutators :: SnapshotMutators
defaultSnapshotMutators = SnapshotMutatorsOriginal

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
  { snapLookups    = a.snapLookups + b.snapLookups
  , snapHits       = a.snapHits + b.snapHits
  , snapExactHits  = a.snapExactHits + b.snapExactHits
  , snapSkipped    = a.snapSkipped + b.snapSkipped
  , snapGapReplay  = a.snapGapReplay + b.snapGapReplay
  , snapMisses     = a.snapMisses + b.snapMisses
  , snapIneligible = a.snapIneligible + b.snapIneligible
  }

ppSnapshotStats :: SnapshotStats -> String
ppSnapshotStats s =
  "snapshots: eligible " <> show s.snapLookups
  <> ", hits " <> show s.snapHits
  <> ", miss " <> show s.snapMisses
  <> ", ineligible " <> show s.snapIneligible
  <> ", skip " <> show s.snapSkipped

-- | FFI and RPC @latest@ are not replay-stable; refuse cache reuse.
snapshotReuseAllowed :: Bool -> Bool -> Bool
snapshotReuseAllowed allowFFI rpcLatest = not allowFFI && not rpcLatest

-- | Why 'evalSeqPlan' will not use the snapshot runner. 'Nothing' means use it.
snapshotSkipReason :: Bool -> Bool -> Bool -> Bool -> Maybe String
snapshotSkipReason enabled allowFFI rpcLatest hasParent
  | enabled && snapshotReuseAllowed allowFFI rpcLatest && hasParent = Nothing
  | not enabled = Just "disabled"
  | allowFFI = Just "ffi"
  | rpcLatest = Just "rpc-latest"
  | otherwise = Just "no-parent"

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
      , Just snaps <- lookupParentSnaps cache parent initialVM ->
          let k = firstDiffIndex parent plan.planCandidate
          in case nearestPrefix snaps k of
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
