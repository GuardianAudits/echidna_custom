module Echidna.ContractName (contractNameForAddr) where

import Control.Monad.Reader (MonadReader, MonadIO (liftIO), asks)
import Data.IORef (readIORef, atomicModifyIORef')
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Optics

import EVM.Format (contractNamePart)
import EVM.Types (VM(..), VMType(Concrete), Addr, Expr (LitAddr), Contract(..))

import Echidna.SourceMapping (findSrcByMetadata, lookupCodehash)
import Echidna.SymExec.Symbolic (forceWord)
import Echidna.Types.Config (Env(..))

contractNameForAddr :: (MonadReader Env m, MonadIO m) => VM Concrete -> Addr -> m Text
contractNameForAddr vm addr = do
  case Map.lookup (LitAddr addr) (vm ^. #env % #contracts) of
    Just contract -> do
      -- Figure out contract compile-time codehash
      codehashMap <- asks (.codehashMap)
      dapp <- asks (.dapp)
      let codehash = forceWord contract.codehash
      compileTimeCodehash <- liftIO $ lookupCodehash codehashMap codehash contract dapp
      -- See if we know the name
      cache <- asks (.contractNameCache)
      nameMap <- liftIO $ readIORef cache
      case Map.lookup compileTimeCodehash nameMap of
        Just name -> pure name
        Nothing -> do
          -- Cache miss, compute and store the name
          let maybeName = case findSrcByMetadata contract dapp of
                Just solcContract -> Just $ contractNamePart solcContract.contractName
                Nothing -> Nothing
              finalName = fromMaybe (T.pack $ show addr) maybeName
          -- Store in cache using compile-time codehash as key
          liftIO $ atomicModifyIORef' cache $ \m -> (Map.insert compileTimeCodehash finalName m, ())
          pure finalName
    Nothing -> pure $ T.pack $ show addr
