module Echidna.Types.Config where

import Control.Concurrent (Chan)
import Data.Aeson (FromJSON(..), withText)
import Data.Aeson.Key (Key)
import Data.IORef (IORef)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (LocalTime)
import Data.Word (Word64)

import EVM.Dapp (DappInfo)
import EVM.Fetch qualified as Fetch
import EVM.Types (Addr, W256)

import Echidna.SourceAnalysis.Slither (SlitherInfo)
import Echidna.SourceMapping (CodehashMap)
import Echidna.Types.Cache
import Echidna.Types.Campaign (CampaignConf)
import Echidna.Types.Corpus (Corpus)
import Echidna.Types.Coverage (CoverageMap)
import Echidna.Types.Solidity (SolConf)
import Echidna.Types.Test (TestConf, EchidnaTest)
import Echidna.Types.Tx (TxConf)
import Echidna.Types.Worker (CampaignEvent)
import Echidna.Types.World (World)
import Echidna.MCP.Store (MCPState)

data MCPTransport = MCPHttp | MCPUnix | MCPStdio deriving (Show, Eq)

data MCPConf = MCPConf
  { enabled    :: Bool
  , transport  :: MCPTransport
  , host       :: Text
  , port       :: Int
  , socketPath :: FilePath
  , maxEvents  :: Int
  , maxReverts :: Int
  , maxTxs     :: Int
  , maxReproducerArtifacts :: Int
  , maxReproducerTxs      :: Int
  , reproducerEventsLimit  :: Int
  , reproducerResultTTLMinutes :: Int
  , includeCallData        :: Bool
  , maxReproducerJsonBytes :: Int
  } deriving (Show, Eq)

defaultMCPConf :: MCPConf
defaultMCPConf = MCPConf
  { enabled = False
  , transport = MCPHttp
  , host = "127.0.0.1"
  , port = 9001
  , socketPath = "/tmp/echidna.mcp.sock"
  , maxEvents = 5000
  , maxReverts = 1000
  , maxTxs = 1000
  , maxReproducerArtifacts = 5000
  , maxReproducerTxs = 128
  , reproducerEventsLimit = 500
  , reproducerResultTTLMinutes = 120
  , includeCallData = False
  , maxReproducerJsonBytes = 256000
  }

data CorpusSyncValidate
  = CorpusSyncValidateNone
  | CorpusSyncValidateReplay
  | CorpusSyncValidateExecute
  deriving (Show, Eq)

instance FromJSON CorpusSyncValidate where
  parseJSON = withText "CorpusSyncValidate" $ \t ->
    case T.toLower t of
      "none" -> pure CorpusSyncValidateNone
      "replay" -> pure CorpusSyncValidateReplay
      "execute" -> pure CorpusSyncValidateExecute
      _ -> fail "invalid corpusSync.ingest.validate (expected none|replay|execute)"

data CorpusSyncWeightPolicy
  = CorpusSyncWeightConstant
  | CorpusSyncWeightLocalNCallseqs
  | CorpusSyncWeightHubScore
  deriving (Show, Eq)

instance FromJSON CorpusSyncWeightPolicy where
  parseJSON = withText "CorpusSyncWeightPolicy" $ \t ->
    case T.toLower t of
      "constant" -> pure CorpusSyncWeightConstant
      "local_ncallseqs" -> pure CorpusSyncWeightLocalNCallseqs
      "hub_score" -> pure CorpusSyncWeightHubScore
      _ -> fail "invalid corpusSync.ingest.weightPolicy (expected constant|local_ncallseqs|hub_score)"

data CorpusSyncPublishConf = CorpusSyncPublishConf
  { coverage :: Bool
  , failures :: Bool
  , maxPerSecond :: Int
  , burst :: Int
  , maxEntryBytes :: Int
  , batchSize :: Int
  } deriving (Show, Eq)

defaultCorpusSyncPublishConf :: CorpusSyncPublishConf
defaultCorpusSyncPublishConf = CorpusSyncPublishConf
  { coverage = True
  , failures = True
  , maxPerSecond = 2
  , burst = 20
  , maxEntryBytes = 262144
  , batchSize = 20
  }

data CorpusSyncIngestConf = CorpusSyncIngestConf
  { enabled :: Bool
  , validate :: CorpusSyncValidate
  , maxPending :: Int
  , maxPerMinute :: Int
  , sampleRate :: Double
  , weightPolicy :: CorpusSyncWeightPolicy
  , constantWeight :: Int
  } deriving (Show, Eq)

defaultCorpusSyncIngestConf :: CorpusSyncIngestConf
defaultCorpusSyncIngestConf = CorpusSyncIngestConf
  { enabled = True
  , validate = CorpusSyncValidateReplay
  , maxPending = 2000
  , maxPerMinute = 600
  , sampleRate = 1.0
  , weightPolicy = CorpusSyncWeightConstant
  , constantWeight = 1
  }

data CorpusSyncBehaviorConf = CorpusSyncBehaviorConf
  { stopOnFleetStop :: Bool
  , resume :: Bool
  , reconnectBackoffMs :: [Int]
  } deriving (Show, Eq)

defaultCorpusSyncBehaviorConf :: CorpusSyncBehaviorConf
defaultCorpusSyncBehaviorConf = CorpusSyncBehaviorConf
  { stopOnFleetStop = True
  , resume = True
  , reconnectBackoffMs = [250, 500, 1000, 2000, 5000, 10000]
  }

data CorpusSyncTLSConf = CorpusSyncTLSConf
  { insecureSkipVerify :: Bool
  , caFile :: Maybe FilePath
  } deriving (Show, Eq)

defaultCorpusSyncTLSConf :: CorpusSyncTLSConf
defaultCorpusSyncTLSConf = CorpusSyncTLSConf
  { insecureSkipVerify = False
  , caFile = Nothing
  }

data CorpusSyncConf = CorpusSyncConf
  { enabled :: Bool
  , url :: Text
  , token :: Maybe Text
  , campaignOverride :: Maybe Text
  , publish :: CorpusSyncPublishConf
  , ingest :: CorpusSyncIngestConf
  , behavior :: CorpusSyncBehaviorConf
  , tls :: CorpusSyncTLSConf
  } deriving (Show, Eq)

defaultCorpusSyncConf :: CorpusSyncConf
defaultCorpusSyncConf = CorpusSyncConf
  { enabled = False
  , url = "ws://127.0.0.1:9010/ws"
  , token = Nothing
  , campaignOverride = Nothing
  , publish = defaultCorpusSyncPublishConf
  , ingest = defaultCorpusSyncIngestConf
  , behavior = defaultCorpusSyncBehaviorConf
  , tls = defaultCorpusSyncTLSConf
  }

data OperationMode = Interactive | NonInteractive OutputFormat deriving (Show, Eq)
data OutputFormat = Text | JSON | None deriving (Show, Eq)
data UIConf = UIConf { maxTime       :: Maybe Int
                     , operationMode :: OperationMode
                     }

-- | An address involved with a 'Transaction' is either the sender, the recipient, or neither of those things.
data Role = Sender | Receiver

-- | Rules for pretty-printing addresses based on their role in a transaction.
type Names = Role -> Addr -> String

-- | Our big glorious global config type, just a product of each local config.,
data EConfig = EConfig
  { campaignConf :: CampaignConf
  , namesConf :: Names
  , solConf :: SolConf
  , testConf :: TestConf
  , txConf :: TxConf
  , uiConf :: UIConf
  , mcpConf :: MCPConf
  , corpusSyncConf :: CorpusSyncConf

  , allEvents :: Bool
  , rpcUrl :: Maybe Text
  , rpcBlock :: Maybe Word64
  , etherscanApiKey :: Maybe Text
  , projectName :: Maybe Text
  , disableOnchainSources :: Bool
  }

instance Read OutputFormat where
  readsPrec _ =
    \case 't':'e':'x':'t':r -> [(Text, r)]
          'j':'s':'o':'n':r -> [(JSON, r)]
          'n':'o':'n':'e':r -> [(None, r)]
          _ -> []

instance FromJSON MCPTransport where
  parseJSON = withText "MCPTransport" $ \t ->
    case T.toLower t of
      "http" -> pure MCPHttp
      "unix" -> pure MCPUnix
      "stdio" -> pure MCPStdio
      _ -> fail "invalid mcp transport (expected http|unix|stdio)"


data EConfigWithUsage = EConfigWithUsage
  { econfig   :: EConfig
  , badkeys   :: Set Key
  , unsetkeys :: Set Key
  }

data Env = Env
  { cfg :: EConfig
  , dapp :: DappInfo

  -- | Shared between all workers. Events are fairly rare so contention is
  -- minimal.
  , eventQueue :: Chan (LocalTime, CampaignEvent)

  , testRefs :: [IORef EchidnaTest]
  , coverageRefInit :: IORef CoverageMap
  , coverageRefRuntime :: IORef CoverageMap
  , corpusRef :: IORef Corpus

  , slitherInfo :: Maybe SlitherInfo
  , codehashMap :: CodehashMap
  , fetchSession :: Fetch.Session
  , contractNameCache :: IORef ContractNameCache
  , chainId :: Maybe W256
  , world :: World
  , mcpState :: Maybe MCPState
  }
