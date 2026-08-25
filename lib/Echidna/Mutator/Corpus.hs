module Echidna.Mutator.Corpus where

import Control.Monad.Random.Strict (MonadRandom, getRandomR, weighted)
import Data.Set qualified as Set

import Echidna.Mutator.Array
import Echidna.Snapshot (MutationPlan(..))
import Echidna.Transaction (mutateTx, shrinkTx)
import Echidna.Types (MutationConsts)
import Echidna.Types.Corpus
import Echidna.Types.Tx (Tx)

defaultMutationConsts :: Num a => MutationConsts a
defaultMutationConsts = (1, 1, 1, 1)

fromConsts :: Num a => MutationConsts Integer -> MutationConsts a
fromConsts (a, b, c, d) = let fi = fromInteger in (fi a, fi b, fi c, fi d)

data TxsMutation = Identity
                 | Shrinking
                 | Mutation
                 | Expansion
                 | Swapping
                 | Deletion
  deriving (Eq, Ord, Show)

data CorpusMutation = RandomAppend TxsMutation
                    | RandomPrepend TxsMutation
                    | RandomSplice
                    | RandomInterleave
  deriving (Eq, Ord, Show)

mutator :: MonadRandom m => TxsMutation -> [Tx] -> m [Tx]
mutator Identity  = return
mutator Shrinking = mapM shrinkTx
mutator Mutation = mapM mutateTx
mutator Expansion = expandRandList
mutator Swapping = swapRandList
mutator Deletion = deleteRandList

selectFromCorpus
  :: MonadRandom m
  => Corpus
  -> m [Tx]
selectFromCorpus =
  weighted . map (\(i, txs) -> (txs, fromIntegral i)) . Set.toDescList

-- | Append-style mutation of an explicit parent. The parent is the original
-- selected prefix; the candidate may differ from index 0 if @f@ rewrites it.
appendFromParent
  :: MonadRandom m
  => ([Tx] -> m [Tx])
  -> Int
  -> [Tx]
  -> [Tx]
  -> m MutationPlan
appendFromParent f ql parent gtxs
  | null parent =
      MutationPlan Nothing . take ql . (++ gtxs) <$> f []
  | otherwise = do
      k <- getRandomR (0, length parent - 1)
      let origPrefix = take k parent
      mutatedPrefix <- f origPrefix
      pure MutationPlan
        { planParent = Just parent
        , planCandidate = take ql (mutatedPrefix ++ gtxs)
        }

-- | Prepend-style mutation: generated txs come first, so the corpus parent is
-- not a prefix of the candidate. No snapshot parent.
prependFromParent
  :: MonadRandom m
  => ([Tx] -> m [Tx])
  -> Int
  -> [Tx]
  -> [Tx]
  -> m MutationPlan
prependFromParent f ql parent gtxs = do
  rtxs' <- case parent of
    [] -> f []
    _ -> do
      k <- getRandomR (0, length parent - 1)
      f (take k parent)
  j <- getRandomR (0, max 0 (ql - 1))
  pure MutationPlan
    { planParent = Nothing
    , planCandidate = take ql (take j gtxs ++ rtxs')
    }

combineFromCorpus
  :: MonadRandom m
  => ([Tx] -> [Tx] -> m [Tx])
  -> Int
  -> Corpus
  -> [Tx]
  -> m MutationPlan
combineFromCorpus f ql corpus gtxs = do
  rtxs1 <- selectFromCorpus corpus
  rtxs2 <- selectFromCorpus corpus
  txs <- f rtxs1 rtxs2
  pure MutationPlan
    { planParent = Nothing
    , planCandidate = take ql (txs <> gtxs)
    }

applyCorpusMutation
  :: MonadRandom m
  => CorpusMutation
  -> Int
  -> [Tx]
  -> [Tx]
  -> m MutationPlan
applyCorpusMutation (RandomAppend m) = appendFromParent (mutator m)
applyCorpusMutation (RandomPrepend m) = prependFromParent (mutator m)
applyCorpusMutation RandomSplice = \_ _ _ ->
  error "applyCorpusMutation: RandomSplice needs two corpus sequences"
applyCorpusMutation RandomInterleave = \_ _ _ ->
  error "applyCorpusMutation: RandomInterleave needs two corpus sequences"

getCorpusMutation
  :: MonadRandom m
  => CorpusMutation
  -> (Int -> Corpus -> [Tx] -> m MutationPlan)
getCorpusMutation (RandomAppend m) = \ql ctxs gtxs -> do
  parent <- selectFromCorpus ctxs
  appendFromParent (mutator m) ql parent gtxs
getCorpusMutation (RandomPrepend m) = \ql ctxs gtxs -> do
  parent <- selectFromCorpus ctxs
  prependFromParent (mutator m) ql parent gtxs
getCorpusMutation RandomSplice = combineFromCorpus spliceAtRandom
getCorpusMutation RandomInterleave = combineFromCorpus interleaveAtRandom

-- | Apply @cmut@ to an already chosen corpus parent (sticky sibling batches).
mutateParent
  :: MonadRandom m
  => CorpusMutation
  -> Int
  -> Corpus
  -> [Tx]
  -> [Tx]
  -> m MutationPlan
mutateParent (RandomAppend m) ql _ parent gtxs =
  appendFromParent (mutator m) ql parent gtxs
mutateParent (RandomPrepend m) ql _ parent gtxs =
  prependFromParent (mutator m) ql parent gtxs
mutateParent RandomSplice ql corpus _ gtxs =
  combineFromCorpus spliceAtRandom ql corpus gtxs
mutateParent RandomInterleave ql corpus _ gtxs =
  combineFromCorpus interleaveAtRandom ql corpus gtxs

seqMutatorsStateful
  :: MonadRandom m
  => MutationConsts Rational
  -> m CorpusMutation
seqMutatorsStateful (c1, c2, c3, c4) = weighted
  [(RandomAppend Identity,   800),
   (RandomPrepend Identity,  200),

   (RandomAppend Shrinking,  c1),
   (RandomAppend Mutation,   c2),
   (RandomAppend Expansion,  c3),
   (RandomAppend Swapping,   c3),
   (RandomAppend Deletion,   c3),

   (RandomPrepend Shrinking, c1),
   (RandomPrepend Mutation,  c2),
   (RandomPrepend Expansion, c3),
   (RandomPrepend Swapping,  c3),
   (RandomPrepend Deletion,  c3),

   (RandomSplice,            c4),
   (RandomInterleave,        c4)
 ]

-- | Append-only mutators. Prepend/splice/interleave drop the parent prefix, so
-- 'planParent' is Nothing and VM snapshots never run.
seqMutatorsSnapshot
  :: MonadRandom m
  => MutationConsts Rational
  -> m CorpusMutation
seqMutatorsSnapshot (c1, c2, c3, _) = weighted
  [(RandomAppend Identity,   800),
   (RandomAppend Shrinking,  c1),
   (RandomAppend Mutation,   c2),
   (RandomAppend Expansion,  c3),
   (RandomAppend Swapping,   c3),
   (RandomAppend Deletion,   c3)
  ]

seqMutatorsStateless
  :: MonadRandom m
  => MutationConsts Rational
  -> m CorpusMutation
seqMutatorsStateless (c1, c2, _, _) = weighted
  [(RandomAppend Identity,   800),
   (RandomPrepend Identity,  200),

   (RandomAppend Shrinking,  c1),
   (RandomAppend Mutation,   c2),

   (RandomPrepend Shrinking, c1),
   (RandomPrepend Mutation,  c2)
  ]
