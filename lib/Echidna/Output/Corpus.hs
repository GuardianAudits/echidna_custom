module Echidna.Output.Corpus where

import Control.Exception (IOException, handle)
import Control.Monad (unless, when)
import Control.Monad.Extra (unlessM)
import Data.Aeson (ToJSON(..), decodeStrict, encodeFile)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Hashable (hash)
import Data.List (partition)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Time (LocalTime)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, makeRelativeToCurrentDirectory, removeFile, renameFile)
import System.FilePath ((</>), (<.>), dropTrailingPathSeparator, takeBaseName, takeDirectory, takeFileName)

import Echidna.Types.Campaign
import Echidna.Types.Config
import Echidna.Types.Test (EchidnaTest(..))
import Echidna.Types.Tx (Tx)
import Echidna.Types.Worker
import Echidna.Utility (listDirectory, withCurrentDirectory)
import Echidna.Worker (pushCampaignEvent)

saveTxs :: Env -> FilePath -> [[Tx]] -> IO ()
saveTxs env dir = mapM_ saveTxSeq where
  saveTxSeq txSeq = do
    createDirectoryIfMissing True dir
    let file = dir </> (show . abs . hash) txSeq <.> "txt"
    unlessM (doesFileExist file) $ do
      encodeFile file (toJSON txSeq)
      pushCampaignEvent env (ReproducerSaved file)

loadTxs :: FilePath -> IO [(FilePath, [Tx])]
loadTxs dir = do
  createDirectoryIfMissing True dir
  files <- listDirectory dir
  css <- mapM (\file -> fmap (file,) <$> readCall file) <$> mapM makeRelativeToCurrentDirectory files
  txSeqs <- catMaybes <$> withCurrentDirectory dir css
  putStrLn ("Loaded " ++ show (length txSeqs) ++ " transaction sequences from " ++ dir)
  pure txSeqs
  where readCall f = decodeStrict <$> BS.readFile f

-- Save corpus/reproducers transactions based on an event
saveCorpusEvent :: Env -> (LocalTime, CampaignEvent) -> IO ()
saveCorpusEvent env (_time, campaignEvent) = do
  case env.cfg.campaignConf.corpusDir of
    Just corpusDir -> saveEvent corpusDir campaignEvent
    Nothing -> pure ()
  where
    saveEvent dir (WorkerEvent _workerId _workerType event) =
      maybe (pure ()) (saveFile dir) $ getEventInfo event
    saveEvent _ _ = pure ()

    getEventInfo = \case
      -- TODO: We save intermediate reproducers in separate directories.
      -- This is because there can be a lot of them and we want to skip
      -- loading those on startup. Ideally, we should override the same file
      -- with a better version of a reproducer, this is smaller or more optimized.
      TestFalsified test -> Just ("reproducers-unshrunk", test.reproducer)
      TestOptimized test -> Just ("reproducers-optimizations", test.reproducer)
      NewCoverage { transactions } -> Just ("coverage", transactions)
      _ -> Nothing

    saveFile dir (subdir, txs) =
      unless (null txs) $
        handle exceptionHandler $ saveTxs env (dir </> subdir) [txs]

    exceptionHandler (e :: IOException) =
      pushCampaignEvent env (Failure $ "Problem while writing to file: " ++ show e)

-- | Move a seed out of @<corpusDir>/coverage@ into the archive directory.
-- Called for a sequence of the initial corpus whose replay added no coverage
-- (no new instruction, call depth, edge or transaction result), so the next
-- start does not replay it again. Returns whether a file was moved.
--
-- The archive is @corpusArchiveDir@, or @echidna-archive@ next to the corpus
-- directory when that is unset. Nothing is moved when the campaign has no
-- corpus directory, when coverage is off (no sequence can add coverage then),
-- or when the file is not in @coverage/@: reproducers are never archived. A
-- seed of the same name already in the archive is replaced.
archiveSeed :: Env -> FilePath -> IO Bool
archiveSeed env file =
  case conf.corpusDir of
    Just corpusDir | conf.coverageEnabled ->
      handle exceptionHandler $ do
        let name = takeFileName file
            source = corpusDir </> "coverage" </> name
            archiveDir = fromMaybe (defaultArchiveDir corpusDir) conf.corpusArchiveDir
        present <- doesFileExist source
        when present $ do
          createDirectoryIfMissing True archiveDir
          moveFile source (archiveDir </> name)
        pure present
    _ -> pure False
  where
    conf = env.cfg.campaignConf

    -- A rename fails when the archive is on another filesystem.
    moveFile source target =
      handle (\(_ :: IOException) -> copyFile source target >> removeFile source) $
        renameFile source target

    exceptionHandler (e :: IOException) = do
      pushCampaignEvent env (Failure $ "Problem while archiving " ++ file ++ ": " ++ show e)
      pure False

-- | Where archived seeds go when @corpusArchiveDir@ is unset: a directory
-- next to the corpus, so it is not checkpointed or replayed with it.
defaultArchiveDir :: FilePath -> FilePath
defaultArchiveDir corpusDir =
  takeDirectory (dropTrailingPathSeparator corpusDir) </> "echidna-archive"

-- | A seed saved under a name of the caller's choice, as opposed to the hash
-- of its transactions that Echidna names its own discoveries with.
isNamedSeed :: FilePath -> Bool
isNamedSeed = not . all isDigit . takeBaseName

-- | Put the coverage seeds in replay order with named seeds first, so that of
-- two seeds with the same coverage the named one is replayed first and kept.
-- A hash-named seed with the same transactions as a named one is not replayed
-- at all; those files are returned separately to be archived.
preferNamedSeeds :: [(FilePath, [Tx])] -> ([(FilePath, [Tx])], [FilePath])
preferNamedSeeds seeds = (named ++ kept, fst <$> copies)
  where
    (named, hashed) = partition (isNamedSeed . fst) seeds
    namedTxs = Set.fromList (snd <$> named)
    (copies, kept) = partition ((`Set.member` namedTxs) . snd) hashed
