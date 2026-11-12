import System.Directory (withCurrentDirectory)
import Test.Tasty (defaultMain, testGroup)
import Tests.ABIv2 (abiv2Tests)
import Tests.Assertion (assertionTests)
import Tests.Atomic (atomicTests)
import Tests.Cheat (cheatTests)
import Tests.Compile (compilationTests)
import Tests.Config (configTests)
import Tests.CorpusArchive (corpusArchiveTests)
import Tests.Coverage (coverageTests)
import Tests.Encoding (encodingJSONTests)
import Tests.Foundry (foundryTests)
import Tests.HitCounts (hitCountTests)
import Tests.FoundryTestGen (foundryTestGenTests)
import Tests.Integration (integrationTests)
import Tests.MCPParse (mcpParseTests)
import Tests.Onchain (onchainTests)
import Tests.Optimization (optimizationTests)
import Tests.Overflow (overflowTests)
import Tests.ReplaySeed (replaySeedTests)
import Tests.Research (researchTests)
import Tests.Sample (sampleTests)
import Tests.Seed (seedTests)
import Tests.SourceMapping (sourceMappingTests)
import Tests.Symbolic (symbolicTests)
import Tests.Values (valuesTests)

main :: IO ()
main = withCurrentDirectory "./tests/solidity" . defaultMain $
         testGroup "Echidna"
           [ atomicTests
           , hitCountTests
           , configTests
           , compilationTests
           , seedTests
           , integrationTests
           , valuesTests
           , coverageTests
           , corpusArchiveTests
           , sourceMappingTests
           , abiv2Tests
           , assertionTests
           , overflowTests
           , optimizationTests
           , researchTests
           , foundryTests
           , encodingJSONTests
           , onchainTests
           , mcpParseTests
           , replaySeedTests
           , sampleTests
           , foundryTestGenTests
           , cheatTests
           , symbolicTests
           ]
