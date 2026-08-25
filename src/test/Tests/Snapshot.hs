{-# LANGUAGE GADTs #-}

module Tests.Snapshot (snapshotTests) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Random.Strict (evalRandT)
import Control.Monad.Reader (runReaderT)
import Control.Monad.ST (stToIO)
import Control.Monad.State.Strict (runStateT)
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import System.Random (mkStdGen)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

import EVM.ABI (AbiValue(..))
import EVM.Solidity (BuildOutput(..), Contracts(..), SolcContract(..))
import EVM.Types hiding (Env)

import Echidna.Agent.Fuzzer (takeStickyParent)
import Echidna.Mutator.Corpus (appendFromParent)
import Echidna.Config (defaultConfig)
import Echidna.Exec (execTx, initialVM)
import Echidna.Execution (callseqPlan, evalSeqPlan)
import Echidna.Snapshot
import Echidna.Solidity (compileContracts, loadSpecified, mkTests, selectMainContract)
import Echidna.Types.Campaign
import Echidna.Types.Config (EConfig(..), Env(..))
import Echidna.Types.Solidity (SolConf(..), defaultContractAddr)
import Echidna.SymExec.Symbolic (forceAddr)
import Echidna.Types.Tx (Tx(..), TxCall(..), basicTx, basicTxWithValue, getResult)
import Echidna.Types.World (World(..))
import Echidna (mkEnv)

snapshotTests :: TestTree
snapshotTests = testGroup "Prefix VM snapshots"
  [ helperTests
  , configParseTests
  , evalSeqTests
  ]

helperTests :: TestTree
helperTests = testGroup "helpers"
  [ testCase "firstDiffIndex of equal lists is the length" $
      firstDiffIndex [1, 2, 3 :: Int] [1, 2, 3] @?= 3
  , testCase "firstDiffIndex reports the first changed index" $
      firstDiffIndex [1, 2, 3, 4, 5 :: Int] [1, 2, 3, 9, 5] @?= 3
  , testCase "firstDiffIndex of a prepend-style change is 0" $
      firstDiffIndex [1, 2, 3 :: Int] [9, 1, 2, 3] @?= 0
  , testCase "firstDiffIndex of an appended suffix is the original length" $
      firstDiffIndex [1, 2, 3 :: Int] [1, 2, 3, 4] @?= 3
  , testCase "nearestPrefix misses when k <= 0" $
      nearestPrefix (IntMap.fromList [(1 :: Int, 'a')]) 0 @?= Nothing
  , testCase "nearestPrefix returns the greatest key <= k" $
      nearestPrefix (IntMap.fromList [(1, 'a'), (5, 'b'), (10, 'c')]) 7
        @?= Just (5, 'b')
  , testCase "snapshotKeepIndices honors the cap and keeps the last prefix" $ do
      let kept = snapshotKeepIndices 2 10
      IntSet.size kept @?= 2
      assertBool "must keep final prefix" $ shouldKeepSnapshot 2 10 10
      assertBool "mid prefix dropped by cap" $ not $ shouldKeepSnapshot 2 10 7
  , testCase "parentKey is stable for equal sequences" $
      parentKey (mkSeq 5) @?= parentKey (mkSeq 5)
  , testCase "empty-parent append keeps mutated ++ gtxs order" $ do
      let gtxs = [mkNoCall 1, mkNoCall 2]
          extra = mkNoCall 99
      plan <- flip evalRandT (mkStdGen 0) $
        appendFromParent (\_ -> pure [extra]) 5 [] gtxs
      plan.planCandidate @?= [extra, mkNoCall 1, mkNoCall 2]
  ]

configParseTests :: TestTree
configParseTests = testGroup "config"
  [ testCase "empty YAML defaults snapshotPrefixes to true" $ do
      defaultConfig.campaignConf.snapshotPrefixes @?= True
      defaultConfig.campaignConf.maxSnapshotsPerSequence @?= 64
  ]

evalSeqTests :: TestTree
evalSeqTests = testGroup "evalSeq restore"
  [ testCase "parent-keyed restore skips prefix" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      (n1, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      n1 @?= 10
      assertEqual "all prefixes retained under cap" 10
        (IntMap.size ws1.prefixSnapshots.snapshots)
      (n2, results, _, ws2) <-
        runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      n2 @?= 3
      length results @?= 10
      ws2.ncalls @?= (ncallsAfter 10 + ncallsAfter 3)
  , testCase "unrelated last sequence does not steal the parent cache" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          unrelated = mkSeq 6
          mutated = mutateAt 7 parent
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (_, _, _, ws2) <- runCounted (snapCfg True 64) ws1 vm0 (noPlan unrelated)
      assertEqual "noPlan must not clobber parent cache"
        (Just (parentKey parent))
        ws2.prefixSnapshots.cachedParentKey
      (n3, _, _, _) <-
        runCounted (snapCfg True 64) ws2 vm0 (sibPlan parent mutated)
      n3 @?= 3
  , testCase "sibling of same parent skips prefix" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          sib1 = mutateAt 7 parent
          sib2 = mutateAt 8 parent
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (n1, _, _, ws2) <- runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent sib1)
      (n2, _, _, _) <- runCounted (snapCfg True 64) ws2 vm0 (sibPlan parent sib2)
      n1 @?= 3
      n2 @?= 2
  , testCase "different parent misses" $ do
      vm0 <- stToIO $ initialVM False
      let parentA = mkSeq 10
          parentB = map (mkNoCall . (+ 100) . fromIntegral) [1 .. 10 :: Int]
          mutatedA = mutateAt 7 parentA
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parentA)
      (_, _, _, ws2) <- runCounted (snapCfg True 64) ws1 vm0 (seedPlan parentB)
      (n, _, _, _) <-
        runCounted (snapCfg True 64) ws2 vm0 (sibPlan parentA mutatedA)
      n @?= 10
  , testCase "restored suffix matches full replay" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (_, snapResults, snapVm, _) <-
        runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      (_, fullResults, fullVm, _) <-
        runCounted (snapCfg False 64) initialWorkerState vm0 (noPlan mutated)
      -- Prefix slots are not reconstructed from cached VMResults.
      fmap (getResult . snd) (drop 7 snapResults)
        @?= fmap (getResult . snd) (drop 7 fullResults)
      vmClock snapVm @?= vmClock fullVm
  , testCase "absent snapshot executes every mutated tx" $ do
      vm0 <- stToIO $ initialVM False
      let mutated = mutateAt 7 (mkSeq 10)
      (n, results, _, _) <-
        runCounted (snapCfg True 64) initialWorkerState vm0 (noPlan mutated)
      n @?= 10
      length results @?= 10
  , testCase "first-diff at 0 (prepend) executes the whole sequence" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          prepended = mkNoCall 99 : parent
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (n, results, _, _) <-
        runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent prepended)
      n @?= 11
      length results @?= 11
  , testCase "cap of N snapshots: at most N retained; dropped prefix falls back" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      (n1, _, _, ws1) <- runCounted (snapCfg True 1) initialWorkerState vm0 (seedPlan parent)
      n1 @?= 10
      let kept = IntMap.size ws1.prefixSnapshots.snapshots
      assertBool "cap honored" $ kept <= 1
      kept @?= 1
      assertBool "mutated prefix 7 not among kept keys" $
        IntMap.notMember 7 ws1.prefixSnapshots.snapshots
      (n2, _, _, _) <-
        runCounted (snapCfg True 1) ws1 vm0 (sibPlan parent mutated)
      n2 @?= 10
  , testCase "callseq ncalls skips the shared prefix" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      ws1 <- runCallseqPlan (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      ws1.ncalls @?= ncallsAfter 10
      ws2 <- runCallseqPlan (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      ws2.ncalls @?= ncallsAfter 10 + ncallsAfter 3
  , testCase "seqLen 50 mutate at 40 drops prefix execs" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 50
          mutated = mutateAt 40 parent
      (nOff, _, _, _) <-
        runCounted (snapCfg False 64) initialWorkerState vm0 (noPlan mutated)
      (n1, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (nOn, _, _, _) <- runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      nOff @?= 50
      n1 @?= 50
      nOn @?= 10
      assertBool "snapshot path executes fewer txs" $ nOn < nOff
  , testCase "disabled path is baseline" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      (n1, _, _, ws1) <-
        runCounted (snapCfg False 64) initialWorkerState vm0 (seedPlan parent)
      (n2, _, _, ws2) <-
        runCounted (snapCfg False 64) ws1 vm0 (sibPlan parent mutated)
      n1 @?= 10
      n2 @?= 10
      assertBool "disabled runner retains no snapshots" $
        IntMap.null ws2.prefixSnapshots.snapshots
      ws2.prefixSnapshots.cachedParentKey @?= Nothing
  , testCase "fingerprint mismatch is a miss" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
          vm1 = bumpBlock vm0
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (n, _, _, ws2) <-
        runCounted (snapCfg True 64) ws1 vm1 (sibPlan parent mutated)
      n @?= 10
      assertEqual "mismatch is not a hit" 0 ws2.snapshotStats.snapHits
  , testCase "txReversion is cleared on continuation snapshot" $ do
      (vm0, env) <- loadStoreVm
      let tx = storeSet 1
      ((_, vm1), _) <-
        flip evalRandT (mkStdGen 0) $
          flip runReaderT env $
            flip runStateT initialWorkerState $
              execTx vm0 tx
      assertBool "exec populates txReversion" $
        not (Map.null vm1.tx.txReversion)
      snap <- mkPrefixSnapshot vm1
      assertBool "continuation snapshot drops txReversion" $
        Map.null snap.tx.txReversion
  , testCase "telemetry increments on lookup/hit/skip" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
      (_, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (_, _, _, ws2) <-
        runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      assertBool "lookups recorded" $ ws2.snapshotStats.snapLookups >= 2
      assertBool "hit recorded" $ ws2.snapshotStats.snapHits >= 1
      assertBool "skipped txs recorded" $ ws2.snapshotStats.snapSkipped >= 1
  , testCase "storage-changing txs: snapshot restore matches full replay of contracts/balances" $ do
      (vm0, env) <- loadStoreVm
      let parent =
            [ storeSet 1
            , storeSet 2
            , storeAdd 3 11
            , storeSet 4
            , storeSet 5
            ]
          mutated = take 4 parent ++ [storeSet 99]
      (n1, _, _, ws1) <-
        runCountedEnv env (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      n1 @?= 5
      (nOn, _, snapVm, _) <-
        runCountedEnv env (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      (_, _, fullVm, _) <-
        runCountedEnv env (snapCfg False 64) initialWorkerState vm0 (noPlan mutated)
      assertBool "storage sibling skipped the shared prefix" $ nOn < 5
      nOn @?= 1
      contractsView snapVm @?= contractsView fullVm
      slot0Of snapVm @?= slot0Of fullVm
      slot0Of snapVm @?= 99
  , testCase "fingerprint distinguishes storage writes" $ do
      (vm0, env) <- loadStoreVm
      ((_, vm1), _) <-
        flip evalRandT (mkStdGen 0) $
          flip runReaderT env $
            flip runStateT initialWorkerState $
              execTx vm0 (storeSet 1)
      ((_, vm2), _) <-
        flip evalRandT (mkStdGen 0) $
          flip runReaderT env $
            flip runStateT initialWorkerState $
              execTx vm0 (storeSet 2)
      assertBool "storage change must change fingerprint" $
        vmFingerprint vm1 /= vmFingerprint vm2
  , testCase "FFI disables snapshot reuse" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 10
          mutated = mutateAt 7 parent
          cfg = (snapCfg True 64)
            { solConf = (snapCfg True 64).solConf { allowFFI = True } }
      (_, _, _, ws1) <- runCounted cfg initialWorkerState vm0 (seedPlan parent)
      (n, _, _, _) <- runCounted cfg ws1 vm0 (sibPlan parent mutated)
      n @?= 10
  , testCase "rpc-latest disables snapshot reuse" $ do
      snapshotReuseAllowed False True @?= False
      snapshotReuseAllowed False False @?= True
      snapshotReuseAllowed True False @?= False
  , testCase "seqLen 200 mutate at 150 drops prefix execs" $ do
      vm0 <- stToIO $ initialVM False
      let parent = mkSeq 200
          mutated = mutateAt 150 parent
      (n1, _, _, ws1) <- runCounted (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (nOn, _, _, _) <- runCounted (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      n1 @?= 200
      assertBool "nearest kept prefix skips most txs" $ nOn < 80 && nOn > 40
  , testCase "revert after state change: snapshot restore matches full replay" $ do
      (vm0, env) <- loadStoreVm
      let parent = [storeSet 1, storeSet 2, storeBoom, storeSet 4]
          mutated = take 3 parent ++ [storeSet 99]
      (_, _, _, ws1) <-
        runCountedEnv env (snapCfg True 64) initialWorkerState vm0 (seedPlan parent)
      (nOn, _, snapVm, _) <-
        runCountedEnv env (snapCfg True 64) ws1 vm0 (sibPlan parent mutated)
      (_, _, fullVm, _) <-
        runCountedEnv env (snapCfg False 64) initialWorkerState vm0 (noPlan mutated)
      assertBool "skipped the shared prefix including revert" $ nOn < 4
      contractsView snapVm @?= contractsView fullVm
      slot0Of snapVm @?= 99
  , testCase "sticky parent batch does not rescan corpus" $ do
      let parent = mkSeq 8
          corp = Set.singleton (1 :: Int, parent)
      env <- mkTestEnv (snapCfg True 64)
      ((p1, p2), ws2) <-
        flip evalRandT (mkStdGen 1) $
          flip runReaderT env $
            flip runStateT initialWorkerState $ do
              a <- takeStickyParent corp
              b <- takeStickyParent corp
              pure (a, b)
      p1 @?= parent
      p2 @?= parent
      ws2.mutationBatchParent @?= Just parent
      ws2.mutationBatchLeft @?= defaultMutationBatchSize - 2
  ]

-- Trailing empty step in evalSeq still increments ncalls once.
ncallsAfter :: Int -> Int
ncallsAfter executed = executed + 1

vmClock :: VM Concrete -> (W256, W256)
vmClock vm =
  let Block { number = n, timestamp = ts } = vm.block
  in (forceLit n, forceLit ts)

bumpBlock :: VM Concrete -> VM Concrete
bumpBlock vm =
  let Block { number = n } = vm.block
  in vm { block = vm.block { number = Lit (forceLit n + 1) } }

mkNoCall :: Integer -> Tx
mkNoCall i = Tx
  { call = NoCall
  , src = 0
  , dst = 0
  , gas = 100000
  , gasprice = 0
  , value = 0
  , delay = (fromInteger i, 1)
  }

mkSeq :: Int -> [Tx]
mkSeq n = map (mkNoCall . fromIntegral) [1 .. n]

mutateAt :: Int -> [Tx] -> [Tx]
mutateAt k txs =
  take k txs ++ [mkNoCall 1000] ++ drop (k + 1) txs

seedPlan :: [Tx] -> MutationPlan
seedPlan txs = MutationPlan (Just txs) txs

sibPlan :: [Tx] -> [Tx] -> MutationPlan
sibPlan parent candidate = MutationPlan (Just parent) candidate

storeSender :: Addr
storeSender = 0x10000

storeSet :: Integer -> Tx
storeSet v =
  basicTx "set" [AbiUInt 256 (fromInteger v)] storeSender defaultContractAddr 1000000 (1, 1)

storeAdd :: Integer -> W256 -> Tx
storeAdd v val =
  basicTxWithValue "add" [AbiUInt 256 (fromInteger v)] storeSender defaultContractAddr 1000000 val (1, 1)

storeBoom :: Tx
storeBoom =
  basicTx "boom" [] storeSender defaultContractAddr 1000000 (1, 1)

contractsView
  :: VM Concrete
  -> [(Addr, W256, Map.Map W256 W256)]
contractsView vm =
  [ (forceAddr addr, forceLit c.balance, storeMap c.storage)
  | (addr, c) <- Map.toList vm.env.contracts
  ]
  where
    storeMap :: Expr Storage -> Map.Map W256 W256
    storeMap (ConcreteStore s) = s
    storeMap _ = Map.empty

slot0Of :: VM Concrete -> W256
slot0Of vm =
  case Map.lookup (LitAddr defaultContractAddr) vm.env.contracts of
    Nothing -> error "SnapshotStore not deployed"
    Just c -> case c.storage of
      ConcreteStore s -> Map.findWithDefault 0 0 s
      _ -> error "expected ConcreteStore"

loadStoreVm :: IO (VM Concrete, Env)
loadStoreVm = do
  let cfg = snapCfg True 64
      solConf = cfg.solConf
  buildOutput <- compileContracts solConf (pure "basic/snapshot-store.sol")
  let Contracts contractMap = buildOutput.contracts
      contracts = Map.elems contractMap
      eventMap = Map.unions $ map (.eventMap) contracts
      world = World solConf.sender mempty Nothing [] [] eventMap
  mainContract <- selectMainContract solConf Nothing contracts
  echidnaTests <- mkTests solConf cfg.campaignConf mainContract
  env <- mkEnv cfg buildOutput echidnaTests world Nothing
  vm <- loadSpecified env mainContract contracts
  pure (vm, env)

snapCfg :: Bool -> Int -> EConfig
snapCfg enabled maxN =
  defaultConfig
    { campaignConf = defaultConfig.campaignConf
        { snapshotPrefixes = enabled
        , maxSnapshotsPerSequence = maxN
        , knownCoverage = Nothing
        }
    }

world0 :: World
world0 = World (Set.fromList [0x10000, 0x20000, 0x30000]) mempty Nothing [] [] mempty

runCounted
  :: EConfig
  -> WorkerState
  -> VM Concrete
  -> MutationPlan
  -> IO (Int, [(Tx, VMResult Concrete)], VM Concrete, WorkerState)
runCounted cfg ws vm plan = do
  env <- mkTestEnv cfg
  runCountedEnv env cfg ws vm plan

runCountedEnv
  :: Env
  -> EConfig
  -> WorkerState
  -> VM Concrete
  -> MutationPlan
  -> IO (Int, [(Tx, VMResult Concrete)], VM Concrete, WorkerState)
runCountedEnv env _cfg ws vm plan = do
  counter <- newIORef (0 :: Int)
  let exec vm' tx = do
        liftIO $ modifyIORef' counter (+ 1)
        execTx vm' tx
  ((results, vm', _), ws') <-
    flip evalRandT (mkStdGen 0) $
      flip runReaderT env $
        flip runStateT ws $
          evalSeqPlan (pure ()) vm exec plan
  n <- readIORef counter
  pure (n, results, vm', ws')

runCallseqPlan
  :: EConfig
  -> WorkerState
  -> VM Concrete
  -> MutationPlan
  -> IO WorkerState
runCallseqPlan cfg ws vm plan = do
  env <- mkTestEnv cfg
  (_, ws') <-
    flip evalRandT (mkStdGen 0) $
      flip runReaderT env $
        flip runStateT ws $
          callseqPlan (pure ()) vm plan False
  pure ws'

mkTestEnv :: EConfig -> IO Env
mkTestEnv cfg = mkEnv cfg (mempty :: BuildOutput) [] world0 Nothing
