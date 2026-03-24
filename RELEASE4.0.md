# Echidna 4.0

This release adds function-weighted fresh call selection and hardens RPC-backed on-chain fetch behavior for Echidna/HEVM integrations.

- Function weighting:
  - New top-level config keys:
    - `functionWeights`
    - `defaultFunctionWeight`
  - Weight keys use the same fully-qualified signature format as `filterFunctions`, for example:
    - `Test.set0(int256)`
    - `A.trigger_bug()`
  - Fresh function selection is now weighted instead of uniform.
  - Weighting applies only when Echidna chooses a fresh function to call.
  - Contract selection, calldata generation, and `mutateTx` semantics are unchanged.
- Weighted ABI/signature plumbing:
  - Added `WeightedSignature` to carry:
    - the raw `SolSignature`
    - the fully-qualified signature text
    - the resolved positive weight
  - `ContractA` and `SignatureMap` now store weighted signatures.
  - ABI preparation resolves weights after normal method filtering.
  - Explicit weight entries are validated against the final callable ABI for the current run.
- Function-weight validation hardening:
  - `defaultFunctionWeight <= 0` is rejected at config parse time.
  - Explicit `functionWeights` entries with `<= 0` are rejected.
  - Unknown, stale, or filtered-out weighted signatures fail startup with `InvalidFunctionWeights`.
  - Weight `0` is not treated as "disable"; function exclusion remains the job of `filterFunctions`.
- RPC fallback / timeout / retry hardening:
  - New top-level config keys:
    - `fallbackRpcUrl`
    - `fallbackRpcUrls`
    - `rpcTimeout`
  - Fallback URLs are tried after the primary `rpcUrl` returns an error.
  - Contract and slot RPC fetches now retry forever across all configured URLs.
  - Exponential backoff is used when all URLs fail:
    - 1s, 2s, 4s, 8s, 16s, 30s cap
  - Optional per-request timeout is supported via `rpcTimeout` in milliseconds.
  - Fetch exceptions are converted to `FetchError` values instead of crashing the process at the fetch boundary.
- Execution resilience updates:
  - Contract fetch failures now degrade to `emptyAccount` instead of killing the worker.
  - Slot fetch failures now degrade to `0` instead of killing the worker.
  - Fetch failures are logged and retried rather than aborting the campaign worker.
- Config/docs updates:
  - `tests/solidity/basic/default.yaml` now documents:
    - `functionWeights`
    - `defaultFunctionWeight`
    - `fallbackRpcUrl`
    - `fallbackRpcUrls`
    - `rpcTimeout`

Regression tests added:

- `functionWeights` config parse
- `defaultFunctionWeight` positive-only validation
- explicit `functionWeights` positive-only validation
- weighted fresh-selection bias
- unknown weighted signature rejection
- filtered-out weighted signature rejection
- `allContracts` weighted config support
- `fallbackRpcUrl` + `rpcTimeout` parse
- `fallbackRpcUrls` + `fallbackRpcUrl` merge behavior

Distribution/build updates:

- Portable Apple Silicon macOS build produced via the redistributable flake target.
- Packaged artifact verified by:
  - inspecting tarball contents
  - starting the extracted binary successfully
  - checking reported version output (`Echidna 2.3.1`)
