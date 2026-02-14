# Echidna 3.0

This release adds automatic Foundry library discovery and linking for Echidna runs on Foundry projects. It removes the need to manually maintain `--compile-libraries` and `deployContracts` for internal libraries in most cases.

## Highlights

- New foundry linked-library auto-configuration path in the main compile flow:
  - discovers libraries from Foundry artifacts (`bytecode.linkReferences` and `deployedBytecode.linkReferences`)
  - computes dependency order
  - assigns deterministic deployment addresses
  - injects both:
    - `--compile-libraries=(LibName,0x10),...`
    - `deployContracts` entries `[(addr,"path/Lib.sol:Lib"), ...]`
- New config surface:
  - `autoLinkLibraries` (default `false`)
  - `autoLinkLibrariesStart` (default `0x10`)
  - `autoLinkLibrariesMax` (default `240`)
  - `autoLinkLibrariesOutDir` (defaults to `foundry.toml` `out`, then `out`)
- New CLI overrides:
  - `--auto-link-libraries`
  - `--no-auto-link-libraries`
- Deterministic behavior:
  - addresses assigned in dependency-respecting order
  - deterministic fallback ordering when dependency cycles prevent a clean topological ordering
- New failure mode:
  - `LibraryLinkingError` for actionable auto-linking misconfiguration

---

## 1) Automatic Linking Behavior

Automatic linking is inserted during `compileContracts` if all precedence checks pass:

1. `autoLinkLibraries` must be enabled (config or CLI)
2. no manual `--compile-libraries` already in `cryticArgs`
3. no legacy manual libraries via `solcLibs`

When enabled, Echidna:

- determines Foundry root from the input path
- resolves artifact output directory (`out` by default, or from `foundry.toml`, overridable by `autoLinkLibrariesOutDir`)
- scans artifacts for link references:
  - `bytecode.linkReferences`
  - `deployedBytecode.linkReferences`
- builds library dependency graph and sorts it so dependents are linked after dependencies
- assigns addresses starting at `autoLinkLibrariesStart`, skipping occupied addresses in existing `deployContracts`
- fails with `autoLinkLibrariesMax` bounds if the auto-link range is exhausted

### Duplicate name handling

- If two different library source files export the same library name, auto-linking fails fast.
- This mirrors `crytic-compile` expectations where `--compile-libraries` keys are name-only.

---

## 2) Fallback behavior when artifacts are missing

If no artifacts are found in the configured output directory:

- Echidna tries `forge build --root <foundry-root>` (best effort) when `forge` is installed
- If forge is not available or build fails, auto-linking proceeds without error (best-effort warning path in logs)
- compile continues with existing config

---

## 3) CLI / Config Usage

Example config:

```yaml
autoLinkLibraries: true
autoLinkLibrariesStart: 0x10
autoLinkLibrariesMax: 240
# optional override:
# autoLinkLibrariesOutDir: "out"
```

Example CLI:

```bash
echidna . --auto-link-libraries
echidna . --no-auto-link-libraries
```

Precedence:

- `--auto-link-libraries` forces auto-linking on
- `--no-auto-link-libraries` forces auto-linking off
- otherwise config/default apply

---

## 4) Testing + validation

- Added dedicated linked-library tests:
  - `src/test/Tests/LinkedLibraries.hs`
  - covers:
    - `bytecode` link references
    - `deployedBytecode` link references
    - malformed reference skipping
    - dependency ordering
    - duplicate-name failures
    - occupancy/max-bound address assignment behavior

---

## 5) Compatibility notes

- Existing manual linkage paths remain intact:
  - `solcLibs`
  - manual `cryticArgs` with `--compile-libraries`
  - user-provided `deployContracts`
- Auto-linking augments config in-memory for the current run and does not overwrite manual settings.
- Corpus-sync fingerprints now include linked-library settings to avoid replay/coverage collisions across runs with different auto-link behavior.

---

## 6) Fuzzing/runtime hardening

- Fixed deterministic fuzzing crashes in small-width integer generation during ABI synthesis/mutation:
  - `getRandomPow` now avoids invalid random ranges for small Solidity widths, preventing `low > high` failures for types like `uint8`/`uint16`.
- Hardened delay parameter generation against edge-case bounds:
  - `genDelay` now handles `maxTimeDelay`/`maxBlockDelay` set to `0` deterministically.
  - Prevented modulo-overflow edge cases when delay bounds are at `maxBound`.
- Added complete seed provenance in JSON output for multi-worker campaigns:
  - JSON now records root seed plus per-worker resolved seeds and seed derivation metadata.
  - This enables exact replay reconstruction from output artifacts without re-deriving worker seeds from worker ordering.

---

## 7) Cheatcode validation + microbenchmarks

Added a dedicated cheatcode suite runner:

- Script: `benchmark/scripts/run_cheatcodes_suite.sh`
- Scope: Foundry-compatible cheatcodes implemented in this custom Echidna/HEVM branch:
  - `deal`
  - `snapshot` / `revertTo`
  - `record` / `accesses`
  - `readFile`
  - `parseJsonBytes`
  - `getCode`
- It runs:
  - smoke properties: `benchmark/contracts/smoke/CheatcodesSmoke.sol`
  - microbench properties: `benchmark/contracts/bench/CheatcodesBench.sol`
- It intentionally skips distributed corpus benchmarking and focuses only on cheatcode coverage + timing.

Run from the `echidna/` repo root:

```bash
cd /Users/robert/Documents/audits/others/echidna_hevm_custom/echidna && ./benchmark/scripts/run_cheatcodes_suite.sh result/bin/echidna --repeats 5 --workers 1 --seq-len 1 --test-limit 500 --smoke-test-limit 50
```
