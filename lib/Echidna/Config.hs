module Echidna.Config where

import Control.Applicative ((<|>))
import Control.Monad (forM_, when)
import Control.Monad.State (StateT(..), runStateT, modify')
import Control.Monad.Trans (lift)
import Data.Aeson
import Data.Aeson.KeyMap (keys)
import Data.Bool (bool)
import Data.ByteString qualified as BS
import Data.Functor ((<&>))
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (isPrefixOf)
import Data.Yaml qualified as Y

import EVM.Solvers (Solver(..))
import EVM.Types (VM(..), W256)

import Echidna.Mutator.Corpus (defaultMutationConsts)
import Echidna.Test
import Echidna.Types.Campaign
import Echidna.Types.Config
import Echidna.Types.Coverage (CoverageFileType(..))
import Echidna.Types.Solidity
import Echidna.Types.Test (TestConf(..))
import Echidna.Types.Tx (TxConf(TxConf), maxGasPerBlock, defaultTimeDelay, defaultBlockDelay)

instance FromJSON EConfig where
  -- retrieve the config from the key usage annotated parse
  parseJSON x = (.econfig) <$> parseJSON @EConfigWithUsage x

instance FromJSON EConfigWithUsage where
  -- this runs the parser in a StateT monad which keeps track of the keys
  -- utilized by the config parser
  -- we can then compare the set difference between the keys found in the config
  -- file and the keys used by the parser to compute which keys were set in the
  -- config and not used and which keys were unset in the config and defaulted
  parseJSON o = do
    let v' = case o of
               Object v -> v
               _        -> mempty
    (c, ks) <- runStateT (parser v') $ Set.fromList []
    let found = Set.fromList (keys v')
    pure $ EConfigWithUsage c (found `Set.difference` ks) (ks `Set.difference` found)
    -- this parser runs in StateT and comes equipped with the following
    -- equivalent unary operators:
    -- x .:? k (Parser) <==> x ..:? k (StateT)
    -- x .!= v (Parser) <==> x ..!= v (StateT)
    -- tl;dr use an extra initial . to lift into the StateT parser
    where
    parser v =
      EConfig <$> campaignConfParser
              <*> pure names
              <*> solConfParser
              <*> testConfParser
              <*> txConfParser
              <*> (UIConf <$> v ..:? "timeout" <*> formatParser)
              <*> mcpConfParser
              <*> corpusSyncConfParser
              <*> v ..:? "allEvents" ..!= False
              <*> v ..:? "rpcUrl"
              <*> fallbackRpcUrlsParser
              <*> v ..:? "rpcTimeout"
              <*> v ..:? "rpcBlock"
              <*> v ..:? "etherscanApiKey"
              <*> v ..:? "projectName"
              <*> v ..:? "disableOnchainSources" ..!= False
      where
      useKey k = modify' $ Set.insert k
      x ..:? k = useKey k >> lift (x .:? k)
      x ..!= y = fromMaybe y <$> x
      fallbackRpcUrlsParser = do
        mList <- v ..:? "fallbackRpcUrls"
        mSingle <- v ..:? "fallbackRpcUrl"
        pure $ fromMaybe [] mList <> maybe [] (:[]) mSingle
      -- Parse as unbounded Integer and see if it fits into W256
      getWord256 k def = do
        value :: Integer <- fromMaybe (fromIntegral (def :: W256)) <$> v ..:? k
        if value > fromIntegral (maxBound :: W256) then
          fail $ show k <> ": value does not fit in 256 bits"
        else
          pure $ fromIntegral value

      txConfParser = TxConf
        <$> v ..:? "propMaxGas" ..!= maxGasPerBlock
        <*> v ..:? "testMaxGas" ..!= maxGasPerBlock
        <*> getWord256 "maxGasprice" 0
        <*> getWord256 "maxTimeDelay" defaultTimeDelay
        <*> getWord256 "maxBlockDelay" defaultBlockDelay
        <*> getWord256 "maxValue" 100000000000000000000 -- 100 eth

      testConfParser = do
        psender <- v ..:? "psender" ..!= 0x10000
        fprefix <- v ..:? "prefix"  ..!= "echidna_"
        let goal fname = if (fprefix <> "revert_") `isPrefixOf` fname then ResRevert else ResTrue
            classify fname vm = maybe ResOther classifyRes vm.result == goal fname
        pure $ TestConf classify (const psender)

      campaignConfParser = CampaignConf
        <$> v ..:? "testLimit" ..!= defaultTestLimit
        <*> v ..:? "stopOnFail" ..!= False
        <*> v ..:? "seqLen" ..!= defaultSequenceLength
        <*> v ..:? "shrinkLimit" ..!= defaultShrinkLimit
        <*> v ..:? "showShrinkingEvery" ..!= Nothing
        <*> (v ..:? "coverage" <&> \case Just False -> Nothing;  _ -> Just mempty)
        <*> v ..:? "seed"
        <*> v ..:? "dictFreq" ..!= 0.40
        <*> v ..:? "corpusDir" ..!= Nothing
        <*> v ..:? "coverageDir" ..!= Nothing
        <*> v ..:? "mutConsts" ..!= defaultMutationConsts
        <*> v ..:? "coverageFormats" ..!= [Txt,Html,Lcov]
        <*> v ..:? "coverageExcludes" ..!= []
        <*> v ..:? "coverageLineHits" ..!= True
        <*> v ..:? "workers"
        <*> v ..:? "server"
        <*> v ..:? "symExec"            ..!= False
        <*> smtSolver
        <*> v ..:? "symExecTargets"     ..!= []
        <*> v ..:? "symExecTimeout"     ..!= defaultSymExecTimeout
        <*> v ..:? "symExecNSolvers"    ..!= defaultSymExecNWorkers
        <*> v ..:? "symExecMaxIters"    ..!= defaultSymExecMaxIters
        <*> v ..:? "symExecAskSMTIters" ..!= defaultSymExecAskSMTIters
        <*> v ..:? "symExecMaxExplore"  ..!= defaultSymExecMaxExplore
        <*> v ..:? "saveEvery"          ..!= Nothing
        <*> v ..:? "logicalCoverage" ..!= True
        <*> v ..:? "logicalCoverageTopN" ..!= defaultLogicalCoverageTopN
        <*> v ..:? "logicalCoverageMaxReasons" ..!= defaultLogicalCoverageMaxReasons
        <*> v ..:? "logicalCoverageMaxSamples" ..!= defaultLogicalCoverageMaxSamples
        <*> v ..:? "logicalCoverageMaxDepth" ..!= defaultLogicalCoverageMaxDepth
        where
        smtSolver = v ..:? "symExecSMTSolver" >>= \case
          Just ("z3" :: String)  -> pure Z3
          Just "cvc5"            -> pure CVC5
          Just "bitwuzla"        -> pure Bitwuzla
          Just s                 -> fail $ "Unrecognized SMT solver: " <> s
          Nothing                -> pure Bitwuzla

      solConfParser = do
        contractAddr <- v ..:? "contractAddr" ..!= defaultContractAddr
        deployer <- v ..:? "deployer" ..!= defaultDeployerAddr
        sender <- v ..:? "sender" ..!= Set.fromList [0x10000, 0x20000, defaultDeployerAddr]
        balanceAddr <- v ..:? "balanceAddr" ..!= 0xffffffff
        balanceContract <- v ..:? "balanceContract" ..!= 0
        codeSize <- v ..:? "codeSize" ..!= 0xffffffff
        prefix <- v ..:? "prefix" ..!= "echidna_"
        disableSlither <- v ..:? "disableSlither" ..!= False
        cryticArgs <- v ..:? "cryticArgs" ..!= []
        solcArgs <- v ..:? "solcArgs" ..!= ""
        solcLibs <- v ..:? "solcLibs" ..!= []
        autoLinkLibraries <- v ..:? "autoLinkLibraries" ..!= False
        autoLinkLibrariesStart <- v ..:? "autoLinkLibrariesStart" ..!= 0x10
        autoLinkLibrariesMax <- v ..:? "autoLinkLibrariesMax" ..!= 240
        autoLinkLibrariesOutDir <- v ..:? "autoLinkLibrariesOutDir" ..!= Nothing
        quiet <- v ..:? "quiet" ..!= False
        deployContracts <- v ..:? "deployContracts" ..!= []
        deployBytecodes <- v ..:? "deployBytecodes" ..!= []
        allContracts <- ((<|>) <$> v ..:? "allContracts"
                         -- TODO: keep compatible with the old name for a while
                         <*> lift (v .:? "multi-abi")) ..!= False
        testMode <- mode
        testDestruction <- v ..:? "testDestruction" ..!= False
        allowFFI <- v ..:? "allowFFI" ..!= False
        methodFilter <- fnFilter
        functionWeights <- v ..:? "functionWeights" ..!= Map.empty
        defaultFunctionWeight <- v ..:? "defaultFunctionWeight" ..!= 1

        when (defaultFunctionWeight <= 0) $
          fail "defaultFunctionWeight must be greater than 0"

        forM_ (Map.toList functionWeights) $ \(sig, weight) ->
          when (weight <= 0) $
            fail $ "functionWeights entry for " <> show sig <> " must be greater than 0"

        pure SolConf
          { contractAddr
          , deployer
          , sender
          , balanceAddr
          , balanceContract
          , codeSize
          , prefix
          , disableSlither
          , cryticArgs
          , solcArgs
          , solcLibs
          , autoLinkLibraries
          , autoLinkLibrariesStart
          , autoLinkLibrariesMax
          , autoLinkLibrariesOutDir
          , quiet
          , deployContracts
          , deployBytecodes
          , allContracts
          , testMode
          , testDestruction
          , allowFFI
          , methodFilter
          , functionWeights
          , defaultFunctionWeight
          }
        where
        mode = v ..:? "testMode" >>= \case
          Just s  -> pure $ validateTestMode s
          Nothing -> pure "property"
        fnFilter = bool Whitelist Blacklist <$> v ..:? "filterBlacklist" ..!= True
                                            <*> v ..:? "filterFunctions" ..!= []

      names :: Names
      names Sender = (" from: " ++) . show
      names _      = const ""

      mcpConfParser = v ..:? "mcp" >>= \case
        Nothing -> pure defaultMCPConf
        Just mv -> lift $ withObject "mcp" (\mcpObj ->
          MCPConf
            <$> mcpObj .:? "enabled" .!= defaultMCPConf.enabled
            <*> mcpObj .:? "transport" .!= defaultMCPConf.transport
            <*> mcpObj .:? "host" .!= defaultMCPConf.host
            <*> mcpObj .:? "port" .!= defaultMCPConf.port
            <*> mcpObj .:? "socketPath" .!= defaultMCPConf.socketPath
            <*> mcpObj .:? "maxEvents" .!= defaultMCPConf.maxEvents
            <*> mcpObj .:? "maxReverts" .!= defaultMCPConf.maxReverts
            <*> mcpObj .:? "maxTxs" .!= defaultMCPConf.maxTxs
            <*> ((<|>) <$> mcpObj .:? "reproducerArtifactsLimit" <*> mcpObj .:? "maxReproducerArtifacts") .!= defaultMCPConf.maxReproducerArtifacts
            <*> mcpObj .:? "maxReproducerTxs" .!= defaultMCPConf.maxReproducerTxs
            <*> mcpObj .:? "reproducerEventsLimit" .!= defaultMCPConf.reproducerEventsLimit
            <*> mcpObj .:? "reproducerResultTTLMinutes" .!= defaultMCPConf.reproducerResultTTLMinutes
            <*> mcpObj .:? "includeCallData" .!= defaultMCPConf.includeCallData
            <*> mcpObj .:? "maxReproducerJsonBytes" .!= defaultMCPConf.maxReproducerJsonBytes
          ) mv

      corpusSyncConfParser = v ..:? "corpusSync" >>= \case
        Nothing -> pure defaultCorpusSyncConf
        Just cv -> lift $ withObject "corpusSync" (\csObj -> do
          publishConf <- csObj .:? "publish" >>= \case
            Nothing -> pure defaultCorpusSyncPublishConf
            Just pv -> withObject "publish" (\pObj ->
              CorpusSyncPublishConf
                <$> pObj .:? "coverage" .!= defaultCorpusSyncPublishConf.coverage
                <*> pObj .:? "failures" .!= defaultCorpusSyncPublishConf.failures
                <*> pObj .:? "maxPerSecond" .!= defaultCorpusSyncPublishConf.maxPerSecond
                <*> pObj .:? "burst" .!= defaultCorpusSyncPublishConf.burst
                <*> pObj .:? "maxEntryBytes" .!= defaultCorpusSyncPublishConf.maxEntryBytes
                <*> pObj .:? "batchSize" .!= defaultCorpusSyncPublishConf.batchSize
              ) pv

          ingestConf <- csObj .:? "ingest" >>= \case
            Nothing -> pure defaultCorpusSyncIngestConf
            Just iv -> withObject "ingest" (\iObj ->
              CorpusSyncIngestConf
                <$> iObj .:? "enabled" .!= defaultCorpusSyncIngestConf.enabled
                <*> iObj .:? "validate" .!= defaultCorpusSyncIngestConf.validate
                <*> iObj .:? "maxPending" .!= defaultCorpusSyncIngestConf.maxPending
                <*> iObj .:? "maxPerMinute" .!= defaultCorpusSyncIngestConf.maxPerMinute
                <*> iObj .:? "sampleRate" .!= defaultCorpusSyncIngestConf.sampleRate
                <*> iObj .:? "weightPolicy" .!= defaultCorpusSyncIngestConf.weightPolicy
                <*> iObj .:? "constantWeight" .!= defaultCorpusSyncIngestConf.constantWeight
              ) iv

          behaviorConf <- csObj .:? "behavior" >>= \case
            Nothing -> pure defaultCorpusSyncBehaviorConf
            Just bv -> withObject "behavior" (\bObj ->
              CorpusSyncBehaviorConf
                <$> bObj .:? "stopOnFleetStop" .!= defaultCorpusSyncBehaviorConf.stopOnFleetStop
                <*> bObj .:? "resume" .!= defaultCorpusSyncBehaviorConf.resume
                <*> bObj .:? "reconnectBackoffMs" .!= defaultCorpusSyncBehaviorConf.reconnectBackoffMs
              ) bv

          tlsConf <- csObj .:? "tls" >>= \case
            Nothing -> pure defaultCorpusSyncTLSConf
            Just tv -> withObject "tls" (\tObj ->
              CorpusSyncTLSConf
                <$> tObj .:? "insecureSkipVerify" .!= defaultCorpusSyncTLSConf.insecureSkipVerify
                <*> tObj .:? "caFile" .!= defaultCorpusSyncTLSConf.caFile
              ) tv

          CorpusSyncConf
            <$> csObj .:? "enabled" .!= defaultCorpusSyncConf.enabled
            <*> csObj .:? "url" .!= defaultCorpusSyncConf.url
            <*> csObj .:? "token" .!= defaultCorpusSyncConf.token
            <*> csObj .:? "campaignOverride" .!= defaultCorpusSyncConf.campaignOverride
            <*> pure publishConf
            <*> pure ingestConf
            <*> pure behaviorConf
            <*> pure tlsConf
          ) cv

      formatParser = fromMaybe Interactive <$> (v ..:? "format" >>= \case
        Just ("text" :: String) -> pure . Just . NonInteractive $ Text
        Just "json"             -> pure . Just . NonInteractive $ JSON
        Just "none"             -> pure . Just . NonInteractive $ None
        Nothing -> pure Nothing
        _ -> fail "Unrecognized format type (should be text, json, or none)")

-- | The default config used by Echidna (see the 'FromJSON' instance for values used).
defaultConfig :: EConfig
defaultConfig = either (error "Config parser got messed up :(") id $ Y.decodeEither' ""

-- | Try to parse an Echidna config file, throw an error if we can't.
parseConfig :: FilePath -> IO EConfigWithUsage
parseConfig f = BS.readFile f >>= Y.decodeThrow
