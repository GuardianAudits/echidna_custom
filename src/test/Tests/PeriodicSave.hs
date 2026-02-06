module Tests.PeriodicSave (periodicSaveTests) where

import Data.Function ((&))
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool)

import EVM.Dapp (DappInfo(..))
import EVM.Solidity (BuildOutput(..))

import Common (runContract, overrideQuiet)
import Echidna.Config (defaultConfig)
import Echidna.Output.PeriodicSave (spawnPeriodicSaver)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..))
import Echidna.Types.Worker (WorkerType(..))

periodicSaveTests :: TestTree
periodicSaveTests = testGroup "Periodic save tests"
  [ testCase "spawnPeriodicSaver returns Nothing when saveEvery is Nothing" $ do
      let cfg = defaultConfig & overrideQuiet
          cfg' = cfg { campaignConf = cfg.campaignConf
                        { testLimit = 100
                        , shrinkLimit = 0
                        , saveEvery = Nothing
                        }}
      (env, _) <- runContract "basic/revert.sol" Nothing cfg' FuzzWorker
      let contracts = Map.elems env.dapp.solcByName
      tid <- spawnPeriodicSaver env 0 "" mempty contracts
      assertBool "should return Nothing" (tid == Nothing)
  ]
