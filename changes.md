# Echidna Branch Changes

This document consolidates the changes implemented in this branch during this session.

It covers two feature sets:

- function-weighted fresh call selection
- RPC fallback / timeout / retry hardening for on-chain fetches

It also records the portable macOS build that was produced from the modified branch.

## 1. Function Weighting

### Goal

Add support for biasing fresh function selection during Echidna campaign generation with config shaped like:

```yaml
functionWeights:
  "Test.set0(int256)": 13
defaultFunctionWeight: 7
```

The intent is to change which function is selected for a fresh synthesized call, without changing contract selection, calldata generation, or corpus mutation semantics.

### User-facing behavior

Two new top-level YAML keys are supported:

- `functionWeights`
  Maps a fully-qualified function signature string to a positive integer weight.
- `defaultFunctionWeight`
  Positive fallback weight for any callable function not explicitly listed.

Signature keys use the same format already used by `filterFunctions`, for example:

- `Test.set0(int256)`
- `A.trigger_bug()`

Behavior:

- Weights apply only to fresh function selection.
- Contract selection remains unchanged.
- Argument generation remains unchanged.
- `mutateTx` remains argument-only and does not switch functions.
- In `allContracts: true` mode, weighting applies inside the ABI of the already-selected contract.

### Validation rules

Configuration now rejects:

- `defaultFunctionWeight <= 0`
- any explicit `functionWeights` entry with `<= 0`
- any explicit `functionWeights` key that does not match a callable function in the final ABI for the current run

This means stale, misspelled, filtered-out, or otherwise non-callable signatures fail startup.

### Core implementation

Files changed:

- `lib/Echidna/Types/Signature.hs`
- `lib/Echidna/Types/Solidity.hs`
- `lib/Echidna/Config.hs`
- `lib/Echidna/Solidity.hs`
- `lib/Echidna/ABI.hs`

Main code changes:

- Added `WeightedSignature`, which carries:
  - the raw `SolSignature`
  - the fully-qualified signature text
  - the resolved positive weight
- Changed `ContractA` and `SignatureMap` to store `WeightedSignature` values instead of raw `SolSignature`.
- Extended `SolConf` with:
  - `functionWeights :: Map Text Int`
  - `defaultFunctionWeight :: Int`
- Added `InvalidFunctionWeights [Text]` to `SolException`.
- Converted `solConfParser` to `do` notation so weight validation can happen during config parsing.
- Added `weightSignature` and `validateFunctionWeights` in `lib/Echidna/Solidity.hs`.
- Updated `mkSignatureMap` so weights are resolved after normal ABI filtering.
- Updated fallback filtering and function-hash preparation so they operate on `WeightedSignature`.
- Replaced uniform fresh function selection in `lib/Echidna/ABI.hs` with weighted selection via `Random.weighted`.

### Tests and fixtures

Files changed:

- `src/test/Tests/Config.hs`
- `src/test/Tests/Integration.hs`
- `tests/solidity/basic/default.yaml`
- `tests/solidity/basic/function-weights.yaml`
- `tests/solidity/basic/function-weights-unknown.yaml`
- `tests/solidity/basic/function-weights-filtered.yaml`
- `tests/solidity/basic/allContracts-weighted.yaml`

Coverage added:

- config parsing for `functionWeights` and `defaultFunctionWeight`
- rejection of non-positive weights
- rejection of unknown weighted signatures
- rejection of filtered-out weighted signatures
- `allContracts` support
- a deterministic bias test showing heavier functions are selected more often

### What did not change

These semantics were intentionally preserved:

- contract-first scheduling
- ABI argument generation
- dictionary behavior
- corpus mutation semantics
- disabling functions via `filterFunctions`

Weight `0` is not treated as "disabled". Function exclusion is still controlled by `filterFunctions`.

## 2. RPC Fallback / Timeout / Retry Hardening

### Goal

Port the runtime behavior from PR `GuardianAudits/echidna_custom#6` into this branch so RPC-backed contract and slot fetches are more resilient:

- support fallback RPC URLs
- support optional per-request timeout
- retry forever instead of failing fast on transient RPC transport errors
- stop killing the worker when fetches fail

### User-facing behavior

New top-level config keys:

- `fallbackRpcUrl`
  Single fallback RPC URL
- `fallbackRpcUrls`
  List of fallback RPC URLs
- `rpcTimeout`
  Optional per-request timeout in milliseconds

Behavior:

- the primary URL is still `rpcUrl`
- fallback URLs are tried after the primary URL returns an error
- if all configured URLs fail, Echidna waits and retries with exponential backoff
- backoff starts at 1 second and grows up to a 30 second cap
- contract fetch failures now degrade to `emptyAccount`
- slot fetch failures now degrade to `0`
- these failures no longer kill the worker with `error`

### Core implementation

Files changed:

- `lib/Echidna/Types/Config.hs`
- `lib/Echidna/Config.hs`
- `lib/Echidna/Onchain.hs`
- `lib/Echidna/Exec.hs`
- `tests/solidity/basic/default.yaml`
- `src/test/Tests/Config.hs`

Main code changes:

- Extended `EConfig` with:
  - `fallbackRpcUrls :: [Text]`
  - `rpcTimeout :: Maybe Int`
- Added parser support for both:
  - `fallbackRpcUrls`
  - `fallbackRpcUrl`
- Merged them into a single `[Text]` field so both syntaxes can be used together.
- Added `retryForever` in `lib/Echidna/Onchain.hs`.
- `retryForever`:
  - cycles through `rpcUrl : fallbackRpcUrls`
  - optionally wraps each request in `System.Timeout.timeout`
  - treats thrown exceptions as `FetchError`
  - logs failures to `stderr`
  - retries forever with exponential backoff capped at 30 seconds
- Updated `safeFetchContractFrom` and `safeFetchSlotFrom` to use the new API.
- Updated `lib/Echidna/Exec.hs` so `FetchError` no longer crashes execution:
  - contract fetch falls back to `emptyAccount`
  - slot fetch falls back to `0`

### Tests and docs

Added config coverage for:

- parsing `fallbackRpcUrl`
- parsing `fallbackRpcUrls`
- merging `fallbackRpcUrl` into `fallbackRpcUrls`
- parsing `rpcTimeout`

Updated `tests/solidity/basic/default.yaml` to document:

- `fallbackRpcUrl`
- `fallbackRpcUrls`
- `rpcTimeout`

## 3. Portable macOS Build

### Goal

Produce a redistributable Apple Silicon macOS binary that can be moved to another Mac, rather than a local machine-specific build.

### Build path used

The portable build path in `scripts/build-portable-echidna.sh` was used:

```bash
HEVM_SRC="$PWD/../hevm" ./scripts/build-portable-echidna.sh --hevm-src "$PWD/../hevm"
```

This builds the flake's `echidna-redistributable` output, which is the correct target for another Mac because the build process strips or rewrites Nix-specific runtime references and performs a portability check.

### Produced artifacts

- `portable-binaries/echidna-portable-3.2-1-ge0d5eca-dirty-aarch64-darwin.tar.gz`
- `portable-binaries/echidna-portable-3.2-1-ge0d5eca-dirty-aarch64-darwin.tar.gz.sha256`

### Verification performed

- portable build script completed successfully
- tarball contents were inspected
- extracted binary started successfully
- extracted binary reported `Echidna 2.3.1`

The artifact is for Apple Silicon (`aarch64-darwin`).

The `dirty` suffix reflects that the branch had uncommitted local changes at build time.

## 4. Summary of Changed Files

Function weighting:

- `lib/Echidna/ABI.hs`
- `lib/Echidna/Config.hs`
- `lib/Echidna/Solidity.hs`
- `lib/Echidna/Types/Signature.hs`
- `lib/Echidna/Types/Solidity.hs`
- `src/test/Tests/Config.hs`
- `src/test/Tests/Integration.hs`
- `tests/solidity/basic/default.yaml`
- `tests/solidity/basic/function-weights.yaml`
- `tests/solidity/basic/function-weights-unknown.yaml`
- `tests/solidity/basic/function-weights-filtered.yaml`
- `tests/solidity/basic/allContracts-weighted.yaml`

RPC fallback / timeout / retry hardening:

- `lib/Echidna/Config.hs`
- `lib/Echidna/Exec.hs`
- `lib/Echidna/Onchain.hs`
- `lib/Echidna/Types/Config.hs`
- `src/test/Tests/Config.hs`
- `tests/solidity/basic/default.yaml`

Build/documentation:

- `scripts/build-portable-echidna.sh`
  - existing script used to produce the redistributable artifact
- `portable-binaries/echidna-portable-3.2-1-ge0d5eca-dirty-aarch64-darwin.tar.gz`
- `portable-binaries/echidna-portable-3.2-1-ge0d5eca-dirty-aarch64-darwin.tar.gz.sha256`

## 5. Shrink Reproducer Delay Fix

### Bug

Echidna's shrinker replaces reverted transactions with `NoCall` / `*wait*` entries.
The bug was that these replacement entries preserved the original transaction delay.

That is incorrect for reverted transactions:

- the original transaction runs `setupTx`
- `setupTx` advances `block.number` and `block.timestamp`
- if the transaction reverts, `execTxWith` restores the VM snapshot from before `setupTx`
- so the reverted transaction does not leave its block/time advance behind

Because the replacement `NoCall` kept the original delay, the shrunk reproducer could
replay at a later `block.number` / `block.timestamp` than the real failing execution.
This breaks reproduction for bugs that depend on exact block or timestamp values.

### Fix

The source-level fix is in `lib/Echidna/Shrink.hs`:

- before: `tx { call = NoCall }`
- after: `tx { call = NoCall, delay = (0, 0) }`

This keeps the intended shrink behavior of removing reverted calls, while preserving
the original execution semantics. Only reverted-call replacements lose their delay;
real `NoCall` wait steps are unchanged.

### Regression Coverage

A deterministic regression was added to cover this case:

- `tests/solidity/basic/shrink-revert-delay.sol`
- `tests/solidity/basic/shrink-revert-delay.yaml`
- `src/test/Tests/Integration.hs`

The regression runs a fixed-seed assertion campaign, collects the stored reproducer,
replays it transaction-by-transaction, and checks that the replay still falsifies the
same assertion. This guards against future shrink outputs that silently stop reproducing
the original failure because of block/time drift.
