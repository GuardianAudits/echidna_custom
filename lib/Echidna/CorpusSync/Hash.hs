module Echidna.CorpusSync.Hash
  ( sha256Hex
  , entryIdForTxs
  , computeCampaignFingerprint
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value, encode, object, (.=))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import EVM.Dapp (DappInfo(..))
import EVM.Solidity (SolcContract(..))
import EVM.Types (Addr, W256)

import Echidna.Types.Config (Env(..), EConfig(..))
import Echidna.Types.Solidity (SolConf(..))
import Echidna.Types.Tx (Tx)

sha256Hex :: LBS.ByteString -> Text
sha256Hex bs =
  -- Digest SHA256 has a stable hex Show instance.
  T.pack $ show (hashlazy bs :: Digest SHA256)

entryIdForTxs :: [Tx] -> Text
entryIdForTxs txs = sha256Hex (encode txs)

-- | Compute a campaign fingerprint used to prevent mixing corpuses across
-- incompatible builds/configs.
computeCampaignFingerprint :: Env -> Maybe Text -> Text
computeCampaignFingerprint Env{cfg, dapp, chainId} selectedContract =
  sha256Hex $ encode descriptor
  where
    DappInfo{solcByName = solcByNameMap} = dapp

    contractsList :: [(Text, W256)]
    contractsList =
      sortOn fst
        [ (name, h)
        | SolcContract{contractName = name, runtimeCodehash = h} <- Map.elems solcByNameMap
        ]

    solConf = cfg.solConf

    descriptor :: Value
    descriptor =
      object
        [ "selected_contract" .= selectedContract
        , "contracts" .= fmap (\(name, h) -> object ["name" .= name, "runtimeCodehash" .= showW256 h]) contractsList
        , "deployment"
            .= object
              [ "contractAddr" .= showAddr solConf.contractAddr
              , "deployer" .= showAddr solConf.deployer
              , "solcLibs" .= solConf.solcLibs
              , "autoLinkLibraries" .= solConf.autoLinkLibraries
              , "autoLinkLibrariesStart" .= showAddr solConf.autoLinkLibrariesStart
              , "autoLinkLibrariesMax" .= solConf.autoLinkLibrariesMax
              , "autoLinkLibrariesOutDir" .= solConf.autoLinkLibrariesOutDir
              , "deployContracts" .= fmap (\(a, s) -> object ["addr" .= showAddr a, "contract" .= s]) solConf.deployContracts
              , "deployBytecodes" .= fmap (\(a, t) -> object ["addr" .= showAddr a, "bytecode" .= t]) solConf.deployBytecodes
              , "allContracts" .= solConf.allContracts
              ]
        , "fork"
            .= object
              [ "rpcUrl" .= cfg.rpcUrl
              , "rpcBlock" .= cfg.rpcBlock
              ]
        , "chainId" .= fmap showW256 chainId
        ]

    showAddr :: Addr -> Text
    showAddr = T.pack . show

    showW256 :: W256 -> Text
    showW256 = T.pack . show
