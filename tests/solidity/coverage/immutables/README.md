These are compiler-output fixtures for contract recognition and memory retention.
`Factory.sol` deploys the same immutable-bearing `Child` with different arguments.
`StoredCodeFactory.sol` executes an archived Child deployment blob; its current
Child artifact has different metadata but the same executable program.

Solar fixtures were compiled with Solar 0.3.0 (e7a91fc7), solc fixtures with
solc 0.8.30 (73712a01), optimizer enabled with 200 runs, EVM Cancun, and the named
IPFS/none metadata setting. `export/combined_solc.json` is the compiler ABI,
bytecode and source maps in crytic-compile's format. The minimal `out` artifacts
retain the compiler's actual immutable locations, which that export discards.

Run `python3 tests/memory/regression.py /path/to/echidna` from the repository root.
The test imports these precompiled fixtures through the production parser and
runs the real fuzzer with coverage enabled, one worker, sequence length 1 and
seed 12345. The compiler shim only copies the fixture into the export directory.
Results are GHC maximum live heap, not process RSS or total machine memory.
