module Echidna.Output.PeriodicSave where

import Control.Concurrent (ThreadId, threadDelay, forkIO)
import Control.Monad (forever, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO (writeFile)
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prelude hiding (writeFile)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Text.Printf (printf)

import EVM.Dapp (DappInfo(..))
import EVM.Solidity (SourceCache, SolcContract)

import Echidna.Output.Source (coverageFileExtension, ppCoveredCode)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..))
import Echidna.Types.Coverage (CoverageFileType, FrozenCoverageMap, mergeCoverageMaps)
import Echidna.Types.Solidity (SolConf(..))

-- | Spawn a thread that periodically saves coverage data during campaign execution
-- Returns the ThreadId so it can be killed when the campaign ends
spawnPeriodicSaver
  :: Env
  -> Int          -- ^ seed for filename
  -> FilePath     -- ^ base directory to save to
  -> SourceCache  -- ^ source cache
  -> [SolcContract] -- ^ contracts
  -> IO (Maybe ThreadId)
spawnPeriodicSaver env seed dir sources contracts =
  case env.cfg.campaignConf.saveEvery of
    Nothing -> pure Nothing
    Just minutes -> do
      let intervalMicroseconds = minutes * 60 * 1000000
      tid <- forkIO $ forever $ do
        threadDelay intervalMicroseconds

        timestamp <- round <$> getPOSIXTime

        saveCoverageSnapshot env seed timestamp dir sources contracts

      pure (Just tid)

-- | Save a snapshot of the current coverage data with a timestamp
saveCoverageSnapshot
  :: Env
  -> Int          -- ^ seed
  -> Int          -- ^ timestamp
  -> FilePath     -- ^ base directory
  -> SourceCache  -- ^ source cache
  -> [SolcContract] -- ^ contracts
  -> IO ()
saveCoverageSnapshot env seed timestamp dir sources contracts = do
  let snapshotDir = dir </> "coverage-snapshots"
  createDirectoryIfMissing True snapshotDir

  coverage <- mergeCoverageMaps env.dapp env.coverageRefInit env.coverageRefRuntime

  let fileTypes = env.cfg.campaignConf.coverageFormats
  mapM_ (\ty -> saveCoverageWithTimestamp ty env seed timestamp snapshotDir sources contracts coverage) fileTypes

  when (not env.cfg.solConf.quiet) $
    putStrLn $ printf "Coverage snapshot saved at %d" timestamp

-- | Save coverage with timestamp in filename
saveCoverageWithTimestamp
  :: CoverageFileType
  -> Env
  -> Int          -- ^ seed
  -> Int          -- ^ timestamp
  -> FilePath     -- ^ directory
  -> SourceCache  -- ^ source cache
  -> [SolcContract] -- ^ contracts
  -> FrozenCoverageMap
  -> IO ()
saveCoverageWithTimestamp fileType env seed timestamp dir sc cs covMap = do
  let extension = coverageFileExtension fileType
      fn = dir </> printf "covered.%d.%d%s" seed timestamp extension
      showHits = env.cfg.campaignConf.coverageLineHits
      projectName = env.cfg.projectName
      excludePatterns = env.cfg.campaignConf.coverageExcludes
  currentTime <- getCurrentTime
  let timeStr = T.pack $ formatTime defaultTimeLocale "%B %d, %Y at %H:%M:%S UTC" currentTime
      cc = ppCoveredCode fileType showHits sc cs covMap projectName timeStr excludePatterns
  createDirectoryIfMissing True dir
  writeFile fn cc
