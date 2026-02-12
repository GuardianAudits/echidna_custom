module Tests.PeriodicSave (periodicSaveTests) where

import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

import EVM.Dapp (DappInfo(..))

import Common (overrideQuiet, runContract)
import Echidna.Config (defaultConfig)
import Echidna.Output.Source (spawnPeriodicSaver)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (EConfig(..), Env(..))
import Echidna.Types.Worker (WorkerType(..))

periodicSaveTests :: TestTree
periodicSaveTests =
  testGroup "Periodic save tests"
    [ testCase "spawnPeriodicSaver returns Nothing when saveEvery is Nothing" $ do
        let baseCfg = defaultConfig & overrideQuiet
            cfg =
              baseCfg
                { campaignConf =
                    baseCfg.campaignConf
                      { testLimit = 100
                      , shrinkLimit = 0
                      , saveEvery = Nothing
                      }
                }
        (env, _) <- runContract "basic/revert.sol" Nothing cfg FuzzWorker
        let contracts = Map.elems env.dapp.solcByName
        tid <- spawnPeriodicSaver env 0 "" mempty contracts
        assertBool "should return Nothing" (tid == Nothing)
    ]
