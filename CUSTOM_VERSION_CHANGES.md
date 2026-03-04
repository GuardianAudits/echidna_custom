# Custom Echidna + HEVM — Change Log

This document summarizes **all custom changes** applied so far in this repo + its paired `hevm` repo, with a focus on the custom HEVM cheatcodes:

- `snapshot()`
- `revertTo(uint256)`
- `deal(address,uint256)`
- `deal(address,address,uint256)`
- `deal(address,address,uint256,bool)`
- `record()`
- `accesses(address)`
- `readFile(string)`
- `getCode(string)`
- `parseJsonBytes(string,string)`

It also tracks custom Echidna runtime features added in this branch:
- `showShrinkingEvery` (realtime shrinking progress in text mode)
- `saveEvery` (periodic coverage snapshots during campaign execution)

---

## 1) Overview of the cheatcodes

### A) `snapshot()`
**Purpose:** Capture a **world‑state snapshot** (Foundry‑style). Returns `uint256 id`.

**Semantics (confirmed):**
- **World‑state only** (storage/balances/code, block/tx substate, logs/traces, forks)
- **Does not rewind execution** (pc/stack/memory unchanged)
- Persistent snapshots (not auto‑deleted)
- Unsupported in symbolic mode (Concrete only)

---

### B) `revertTo(uint256 id)`
**Purpose:** Restore a snapshot by id. Returns `bool`.

**Semantics (confirmed):**
- If id is **missing → throws** `BadCheatCode` (per user choice)
- Restores world‑state captured by snapshot
- Does **not** restore gas/constraints/freshVar/etc.

---

### C) `deal(...)` (native ETH + ERC20)
**Purpose:** Deterministically set native ETH balances and ERC20 balances (Foundry/forge-std parity).

**Semantics (confirmed):**
- Native ETH:
  - `deal(address who, uint256 give)` sets `who.balance = give`.
- ERC20:
  - `deal(address token, address to, uint256 give)` forces `token.balanceOf(to) == give` by mutating token storage.
  - `deal(address token, address to, uint256 give, bool adjustTotalSupply)` additionally adjusts `totalSupply()` by `(give - prevBal)` when `adjustTotalSupply=true` using Solidity checked arithmetic (reverts with `Panic(0x11)` on under/overflow).
- Uses a `StdStorage.checked_write`-style algorithm (like forge-std):
  - `STATICCALL` into `balanceOf(to)` / `totalSupply()` to discover candidate storage slots via observed storage reads.
  - Temporarily flips candidate slots to ensure the call result changes, then performs the write and verifies by re-calling.
  - Reverts on: no storage reads, slot(s) not found, or write verification failure.
- No `Transfer` events, no allowance updates.

---

### D) `record()` / `accesses(address)`
**Purpose:** Foundry-compatible storage access recording for slot discovery and debugging.

**Semantics (confirmed):**
- `record()` enables recording of storage reads/writes performed by subsequent calls in the current transaction context.
- `accesses(address c)` returns `(bytes32[] reads, bytes32[] writes)` for contract `c` since the last `record()`.
- If `record()` has not been called yet, `accesses(...)` returns empty arrays (Foundry gotcha).
- Subsequent calls to `record()` clear previous recorded data (Foundry behavior).
- Foundry semantics: **every write also counts as a read**, so written slots appear in both arrays.

**Implementation notes:**
- Implemented by extending HEVM's `TxState.subState` with recording fields and recording on every `SLOAD` / `SSTORE`.

---

### E) `readFile(string path)`
**Purpose:** Read a file from the local filesystem (sandboxed) and return its contents as `string`.

**Semantics (confirmed):**
- Requires `allowFFI=true` (same gate as `ffi(string[])`)
- Path is resolved under a filesystem root; attempts to escape the root are rejected
- Enforces a max file size (default: 5 MiB)
- On failure, reverts with `Error(string)` describing the error

---

### F) `parseJsonBytes(string json, string keyPath)`
**Purpose:** Parse JSON and extract a value as `bytes`.

**Semantics (confirmed):**
- `json` must be valid JSON text
- `keyPath` supports dot-separated keys and `[index]` array indexing; bracket-quoted keys like `['a.b']` are supported
- Selected value must be:
  - a hex string with `0x` prefix (odd-length allowed; left-padded)
  - OR an array of byte values (numbers `0..255`)
- On failure, reverts with `Error(string)` describing the parse/path/type error
- Not gated behind `allowFFI`

---

### G) `getCode(string artifactPath)`
**Purpose:** Read contract creation bytecode from local artifact JSON files (Foundry-style selectors).

**Semantics (confirmed):**
- Requires `allowFFI=true` (same gate as `ffi(string[])` and `readFile(string)`)
- Returns creation bytecode as `bytes`
- Supports selectors:
  - direct artifact path (`*.json`)
  - `<File.sol>:<Contract>`
  - `<Contract>`
  - `<File.sol>`
  - `<File.sol>:<Version>`
  - `<Contract>:<Version>`
- Rejects malformed refs, unresolved refs, invalid JSON, missing bytecode fields, invalid hex, and unlinked library placeholders
- Uses sandboxed filesystem resolution under artifacts root with max-bytes limit

---

## 2) Where changes live (hevm repo)

### Cheatcode implementation
- **`hevm/src/EVM.hs`**
  - `cheatActions` contains the custom cheatcodes (`snapshot`, `revertTo`, `deal`, `record`, `accesses`, `readFile`, `getCode`, `parseJsonBytes`)
  - `snapshot`/`revertTo` capture/restore helpers live here
  - `deal` ERC20 overloads + `checked_write`/slot-discovery helpers live here
  - `record`/`accesses` storage-access recording hooks + ABI return handling live here
  - `parseJsonBytes` JSON path + decoding helpers live here
  - `getCode` dispatch + ABI return/revert handling live here

### `readFile` query plumbing
- **`hevm/src/EVM/Types.hs`**
  - Added `PleaseReadFile :: FilePath -> (Either String ByteString -> EVM t ()) -> Query t`
- **`hevm/src/EVM/Fetch.hs`**
  - Answers `PleaseReadFile` using a sandboxed filesystem root + max size

### `getCode` query plumbing
- **`hevm/src/EVM/Types.hs`**
  - Added `PleaseGetCode :: FilePath -> (Either String ByteString -> EVM t ()) -> Query t`
- **`hevm/src/EVM/GetCode.hs`**
  - Shared resolver + artifact selector parser + bytecode extraction + sandbox checks
- **`hevm/src/EVM/Fetch.hs`**
  - Answers `PleaseGetCode` with HEVM-preferring env precedence
- **`hevm/hevm.cabal`**
  - Exposes `EVM.GetCode` from the `hevm` library so Echidna can reuse the same resolver

### New VM snapshot state
- **`hevm/src/EVM/Types.hs`**
  - Added `snapshots :: Map SnapshotId Snapshot`
  - Added `nextSnapshotId :: SnapshotId`
  - Added `SnapshotId` + `Snapshot` types

### Snapshot scope (world‑state only)
Captured in snapshot:
- `env` (contracts + balances + code)
- `block`
- `tx.subState`
- `logs`
- `traces`
- `forks`, `currentFork`

Not captured:
- `state`, `frames`, `memory`, `result`
- `constraints`, `burned`, `freshVar`, etc.

---

## 3) Echidna notes

### Logical coverage summary behavior (important)
The **Logical coverage** section is **Top‑N only** and **sorted by total call count**, not by success rate.

Defaults:
- `logicalCoverageTopN = 10`
- Only methods that were **actually called** are shown (never‑called methods don’t appear).

If you have many handlers (e.g., 103), you’ll only see the **most‑called** methods in the summary.  
To show all called methods, set `logicalCoverageTopN` higher via CLI or config:

```bash
./result/bin/echidna ... --logical-coverage-topn 200
```

```yaml
logicalCoverageTopN: 200
```

---

### `readFile` support (filesystem sandbox)
Echidna answers HEVM `PleaseReadFile` queries in **`lib/Echidna/Exec.hs`**.

Environment variables:
- `ECHIDNA_FS_ROOT` / `HEVM_FS_ROOT`: filesystem root (default: current working directory)
- `ECHIDNA_FS_MAX_BYTES` / `HEVM_FS_MAX_BYTES`: max file size in bytes (default: `5 * 1024 * 1024`)

Notes:
- `readFile(string)` is still gated by `allowFFI=true` (same as `ffi(string[])`). In Echidna, set `allowFFI: true` in the YAML config.
- Precedence: Echidna prefers `ECHIDNA_*` first; HEVM prefers `HEVM_*` first.
- Both Echidna and HEVM prevent paths from escaping the configured root (after canonicalization).

### `getCode` support (artifact resolver)
Echidna answers HEVM `PleaseGetCode` queries in **`lib/Echidna/Exec.hs`** via shared resolver logic in `hevm/src/EVM/GetCode.hs`.

Environment variables:
- `ECHIDNA_ARTIFACTS_ROOT` / `HEVM_ARTIFACTS_ROOT`: artifact search root (fallback: `*_FS_ROOT`, then current directory)
- `ECHIDNA_ARTIFACTS_MAX_BYTES` / `HEVM_ARTIFACTS_MAX_BYTES`: max artifact size in bytes (fallback: `*_FS_MAX_BYTES`, then `5 * 1024 * 1024`)
- `ECHIDNA_SOLC_VERSION` / `HEVM_SOLC_VERSION` / `FOUNDRY_SOLC_VERSION` / `SOLC_VERSION`: preferred compiler version for ambiguous selectors

Notes:
- If `ECHIDNA_ARTIFACTS_ROOT` points directly to your artifact directory, selector paths should usually be root-relative (e.g., `MyContract.json`, not `artifacts/MyContract.json`).
- Echidna-side env precedence for getCode is Echidna-first (`ECHIDNA_*` before `HEVM_*`), matching `readFile` behavior.

### Realtime shrinking progress (`showShrinkingEvery`)
Adds optional periodic printing of intermediate shrinking state in **non-interactive text mode**.

Config / CLI:
```yaml
showShrinkingEvery: 10
```
```bash
--show-shrinking-every 10
```

Behavior:
- Default is disabled (`null` / unset).
- When enabled with `N > 0`, prints progress every `N` shrink iterations per active test.
- Output includes test name, iteration (`current/shrinkLimit`), transaction count, and current call sequence.
- Interactive UI mode is unchanged.

Implementation wiring:
- Config parse: `lib/Echidna/Config.hs`
- Runtime field: `lib/Echidna/Types/Campaign.hs`
- Output loop: `lib/Echidna/UI.hs`
- CLI override: `src/Main.hs`
- MCP run config exposes `showShrinkingEvery`: `lib/Echidna/MCP.hs`

### Periodic coverage snapshots (`saveEvery`)
Adds optional periodic coverage snapshots while the campaign is running.

Config / CLI:
```yaml
saveEvery: 5
```
```bash
--save-every 5
```

Behavior:
- Default is disabled (`null` / unset).
- When enabled with `M > 0`, Echidna spawns a background saver thread that writes snapshots every `M` minutes.
- Snapshot directory: `<coverageDir or corpusDir>/coverage-snapshots/`
- Reuses existing coverage format settings (`coverageFormats`) and exclusions (`coverageExcludes`).
- If `coverageLineHits=true`, also writes timestamped `coverage_hits.<ts>.json` files in snapshot dir.
- Saver thread is stopped cleanly on campaign exit.

Implementation wiring:
- Runtime field: `lib/Echidna/Types/Campaign.hs`
- Config parse: `lib/Echidna/Config.hs`
- Saver implementation: `lib/Echidna/Output/Source.hs` (`spawnPeriodicSaver`)
- Lifecycle wiring: `src/Main.hs`
- MCP run config exposes `saveEvery`: `lib/Echidna/MCP.hs`

### Compiler warning / compatibility cleanups
The integration also included explicit cleanups for current/future GHC compatibility:

- Fixed non-interactive shrink progress compile issue by evaluating `ppTx` under `ReaderT Env`:
  - `lib/Echidna/UI.hs` now uses `runReaderT (mapM (ppTx ...)) env` in the ticker path.
- Addressed GADT mono-local-binds warnings by enabling `GADTs` where needed:
  - `lib/Echidna/LogicalCoverage.hs`
  - `lib/Echidna/MCP.hs`
- Addressed ambiguous duplicate-record-field update warning by replacing the update with explicit `WorkerState` reconstruction:
  - `lib/Echidna/Campaign.hs` now sets `logicalCoverage` via constructor fields (no ambiguous record update)
  - avoids relying on deprecated type-directed disambiguation behavior.

### Cheatcode + runtime feature test coverage (current)

Echidna tests:
- `src/test/Tests/Cheat.hs` registers `getCode` coverage in both modes:
  - `tests/solidity/cheat/getCode.sol` (`TestGetCode`) with `allowFFI: true`
  - `tests/solidity/cheat/getCode.sol` (`TestGetCodeNoFFI`) with `allowFFI: false`
- Config files:
  - `tests/solidity/cheat/getCode.yaml`
  - `tests/solidity/cheat/getCode_noffi.yaml`
- Artifact fixtures:
  - `tests/solidity/cheat/getcode_artifacts/*.json`
- Config parsing/default coverage for `showShrinkingEvery` + `saveEvery`:
  - `src/test/Tests/Config.hs`
  - `tests/solidity/basic/show-shrinking-test.yaml`
  - `tests/solidity/basic/save-every-test.yaml`
- Shrinking behavior checks with display config enabled:
  - `src/test/Tests/Shrinking.hs`
- Periodic save wiring guard checks:
  - `src/test/Tests/PeriodicSave.hs`
- Coverage test includes `saveEvery` config passthrough check:
  - `src/test/Tests/Coverage.hs`

Local smoke project tests:
- `solidity_project/contracts/smoke/CheatcodesSmoke.sol` covers selector matrix + bad-input reverts for `getCode`.
- `solidity_project/contracts/smoke/CheatcodesSmoke_NoFFI.sol` verifies `getCode` gate behavior when `allowFFI=false`.
- `solidity_project/scripts/run_smoke.sh` exports `ECHIDNA_ARTIFACTS_ROOT`/`ECHIDNA_ARTIFACTS_MAX_BYTES` and runs full smoke sequence.

HEVM tests/benchmarks:
- `hevm/test/test.hs` adds concrete tests for ERC20 `deal` (no-adjust + adjust totalSupply).
- `hevm/bench/bench-perf.hs` adds a `dealErc20` benchmark group to measure cheatcode overhead.

---

## 4) How to call the cheatcodes in Solidity

### Cheatcode interface
```solidity
interface IHevmCheatcodes {
    function snapshot() external returns (uint256 id);
    function revertTo(uint256 id) external returns (bool success);

    function deal(address who, uint256 give) external;
    function deal(address token, address to, uint256 give) external;
    function deal(address token, address to, uint256 give, bool adjustTotalSupply) external;

    function readFile(string calldata path) external returns (string memory contents);
    function getCode(string calldata artifactPath) external returns (bytes memory creationBytecode);
    function parseJsonBytes(string calldata json, string calldata keyPath) external returns (bytes memory out);
}
```

### Cheatcode address
```solidity
IHevmCheatcodes hevm = IHevmCheatcodes(
    address(uint160(uint256(keccak256("hevm cheat code"))))
);
```

### Example usage
```solidity
uint256 id = hevm.snapshot();
// mutate state
bool ok = hevm.revertTo(id);
require(ok, "revertTo failed");

// Set ERC20 balances without minting/transfers (no Transfer event).
hevm.deal(address(token), user, 1e18);
hevm.deal(address(token), user, 1e18, true); // optionally adjust totalSupply()

// Read a JSON fixture and extract bytes from it.
string memory json = hevm.readFile("fixtures/input.json");
bytes memory blob = hevm.parseJsonBytes(json, ".foo.bar[0]");

// Load creation bytecode from an artifact selector.
bytes memory initCode = hevm.getCode("MyContract.sol:MyContract");
```

---

## 5) Build + run notes

### Build Echidna with custom HEVM
```bash
cd /Users/robert/Documents/audits/others/echidna_hevm_custom/echidna
HEVM_SRC=/Users/robert/Documents/audits/others/echidna_hevm_custom/hevm \
  nix build .#echidna --impure -L --max-jobs auto --cores 0
```

Binary:
```
/Users/robert/Documents/audits/others/echidna_hevm_custom/echidna/result/bin/echidna
/Users/robert/Documents/audits/others/echidna_hevm_custom/echidna/result/bin/echidna-corpus-hub
```

### Build HEVM directly
```bash
cd /Users/robert/Documents/audits/others/echidna_hevm_custom/hevm
nix build .#hevm -L --max-jobs auto --cores 0
```

Binary:
```
/Users/robert/Documents/audits/others/echidna_hevm_custom/hevm/result/bin/hevm
```

HEVM CLI version check:
```bash
./result/bin/hevm version
```

If your Nix setup disables import-from-derivation during evaluation, add:
```bash
--option allow-import-from-derivation true
```

---

## 6) Known limitations / notes

- `snapshot()` and `revertTo()` are **concrete‑only**. Symbolic execution will throw `BadCheatCode`.
- ERC20 `deal(token,to,give[,adjust])` is **concrete-only** in this branch.
- ERC20 `deal` relies on storage-slot discovery via observed `SLOAD`s from `balanceOf(to)` / `totalSupply()` and may fail for tokens with packed balances, rebasing/custom accounting, or multi-slot balance computations.
- Snapshots are **persistent**; there is no max count enforcement in v1.
- Cheat‑environment state (`labels`, `osEnv`) is **not reverted** on `revertTo`, per current decision.
- `readFile(string)` is gated by `allowFFI=true` and is sandboxed under `*_FS_ROOT` with a `*_FS_MAX_BYTES` cap.
- `getCode(string)` is gated by `allowFFI=true`, uses sandboxed artifact resolution, and defaults to deterministic ambiguity errors when selector/version is not unique.
- `parseJsonBytes(string,string)` only decodes a selected value as either a `0x`-prefixed hex string or an array of byte values.

---

## 7) Coverage hit counts (per‑line)

Per‑line hit counts are now tracked and can be displayed in coverage outputs.

**Behavior**
- Hit counts are collected **for every opcode** executed and aggregated to the corresponding source line.
- Applies to **all contracts covered** in the run (protocol‑wide), not just fuzz targets.

**Where it shows**
- **HTML coverage report**: new hits column (when enabled).
- **TXT coverage report**: extra hits column (when enabled).
- **LCOV**: uses actual hit counts for `DA:<line>,<count>` when enabled.
- **JSON**: `coverage_hits.json` written next to coverage reports when enabled.

**Config / CLI**
```yaml
coverageLineHits: true
```

```bash
--coverage-line-hits true|false
```

---

## 8) MCP Server + Live Dashboard (HTTP)

**Purpose:** Provide a live, queryable view of Echidna runs, reverts, traces, handlers, logical coverage, and coverage hits via a local MCP‑style JSON‑RPC server plus a built‑in dashboard.

### How it works

When MCP is enabled, Echidna starts an embedded HTTP server and keeps bounded in-memory run state that is updated as fuzzing progresses.

- Producer side (inside Echidna):
  - workers/tests emit events, reverts, tx summaries, handlers, traces, and coverage stats.
  - MCP store keeps the latest data with configurable caps (`maxEvents`, `maxReverts`, `maxTxs`).
- Consumer side:
  - Dashboard (`/` and `/ui`) reads from the same MCP store.
  - JSON-RPC clients call `POST /mcp` to query resources/tools.

This is live runtime state, not a historical database. Restarting Echidna resets MCP in-memory state.

### How to reach it

MCP address is built from `mcp.host` + `mcp.port`:

- Base URL: `http://<host>:<port>`
- Dashboard: `GET /` (or `GET /ui`)
- Health: `GET /health`
- JSON-RPC: `POST /mcp`

Reachability rules:
- `host: 127.0.0.1` => local machine only (recommended default).
- `host: 0.0.0.0` => reachable from other machines on the network (add network/firewall controls yourself).

### What you get

- **Web dashboard** (dark UI) served by Echidna itself  
  - URL: `http://127.0.0.1:9001/` (default)  
  - Alias: `http://127.0.0.1:9001/ui`  
- **JSON‑RPC API** at `POST /mcp`  
- **Health check** at `GET /health`

### How to enable

**Config file (`echidna.yaml`)**
```yaml
mcp:
  enabled: true
  transport: http
  host: "127.0.0.1"
  port: 9001
  maxEvents: 5000
  maxReverts: 1000
  maxTxs: 1000
```

Minimal quick-start `echidna.yaml`:
```yaml
testMode: property
format: text
quiet: true

mcp:
  enabled: true
  transport: http
  host: "127.0.0.1"
  port: 9001
  maxEvents: 5000
  maxReverts: 1000
  maxTxs: 1000
```

**CLI flags**
```bash
--mcp true \
--mcp-transport http \
--mcp-host 127.0.0.1 \
--mcp-port 9001 \
--mcp-max-events 5000 \
--mcp-max-reverts 1000 \
--mcp-max-txs 1000
```

Example run using config file:
```bash
./result/bin/echidna contracts/MyTest.sol --contract MyTest --config echidna.yaml
```

Quick connectivity checks:
```bash
curl -s http://127.0.0.1:9001/health
curl -s -X POST http://127.0.0.1:9001/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"resources/list"}'
```

**Defaults**
- `enabled: false`
- `transport: http`
- `host: 127.0.0.1`
- `port: 9001`
- `maxEvents: 5000`
- `maxReverts: 1000`
- `maxTxs: 1000`

> Note: Only HTTP transport is supported in this custom build.  
> `unix` and `stdio` are parsed but will switch MCP to `disabled`.

### Dashboard data surfaced

- Run status (phase, worker counts, time, seeds)
- Handlers (calls + success/failure)
- Logical coverage (success rate, arg ranges, revert reasons)
- Coverage summary + per‑line hit counts
- Reverts (reason + trace)
- Events stream

### JSON‑RPC resources available

From `resources/list`:
- `echidna://run/status`
- `echidna://run/config`
- `echidna://run/tests`
- `echidna://run/events`
- `echidna://run/reverts`
- `echidna://run/txs`
- `echidna://run/handlers`
- `echidna://run/traces`
- `echidna://run/trace` (by id)
- `echidna://coverage/summary`
- `echidna://coverage/lines`
- `echidna://stats/logical-coverage`

### JSON‑RPC tools available

- `pause` / `resume` / `stop`
- `get_status`, `get_events`, `get_reverts`, `get_handlers`, `get_traces`
- `get_logical_coverage`, `get_coverage_hits`

### Example `curl` usage
```bash
curl -s -X POST http://127.0.0.1:9001/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"resources/list"}'
```

### Phase lifecycle

Typical MCP phases during a run:
- `starting` → `running`  
- `paused` (when dashboard Pause is used)  
- `stopped` (when Stop is used)  
- `completed` (after run finishes normally)  
- `disabled` (when MCP is off or transport unsupported)

---

## 9) Distributed Corpus Sync (WebSockets / WSS)

**Purpose:** Run Echidna in a fleet (100+ cores/nodes) where instances share high-signal inputs (coverage-increasing call sequences and failing reproducers) via a hub-and-spoke WebSocket protocol, converging toward one consolidated corpus.

Protocol/design notes are now consolidated in this changelog section (the old standalone spec file was removed).

### What was added

Client-side (in `echidna`):
- `lib/Echidna/CorpusSync.hs`: in-process corpus sync client (publish + subscribe + ingest).
- `lib/Echidna/CorpusSync/Protocol.hs`: JSON message envelope + message payload types/builders.
- `lib/Echidna/CorpusSync/Hash.hs`: `entry_id` + campaign fingerprint hashing (SHA256 via `cryptonite`).
- `lib/Echidna/UI.hs`: starts corpus sync alongside workers; waits for it to finish on shutdown.

Configuration + CLI wiring:
- `lib/Echidna/Types/Config.hs`: new `corpusSyncConf :: CorpusSyncConf` and nested config types/defaults.
- `lib/Echidna/Config.hs`: YAML parsing for the new `corpusSync:` key.
- `src/Main.hs`: new CLI flags (see below).

Hub-side (new executable):
- `src/hub/Main.hs`: `echidna-corpus-hub` WebSocket hub server.
- `package.yaml`: new executable stanza + deps (`websockets`, `wuss`, `cryptonite`, `stm`).

### High-level behavior (v1)

- Each Echidna instance opens **one** `ws://` or `wss://` connection to a hub.
- On `WorkerEvent.NewCoverage`, the instance publishes a `corpus_publish` message containing:
  - metadata (entry type, tx count, bytes, origin info, hints)
  - the `[Tx]` payload
- The hub persists/deduplicates entries and broadcasts `corpus_announce` (metadata only).
- Other instances receive `corpus_announce`, then request the payload via `corpus_get` and ingest it on `corpus_entry`.
- On `WorkerEvent.TestFalsified`, the instance publishes `failure_publish` with a reproducer; the hub can optionally broadcast `fleet_stop` to stop the fleet early.

### Entry IDs and deduplication

- `entry_id = sha256Hex(encode([Tx]))` (Aeson JSON encoding, then SHA256).
- Hub recomputes `entry_id` from the received tx list and rejects mismatches.
- Client recomputes `entry_id` on ingest and rejects mismatches.

Note: this is stable within the same Echidna build; it is not a cross-language canonicalization scheme.

### Campaign fingerprint

To avoid mixing incompatible runs, the client computes a `campaign_fingerprint` (SHA256 over a JSON descriptor including Echidna version, deployed codehashes list, deployment config, and fork config). This fingerprint is used as the hub “campaign group” key.

### Fleet stop behavior

- When the hub broadcasts `fleet_stop` and `corpusSync.behavior.stopOnFleetStop=true` (default), instances stop their workers gracefully.
- The “origin” instance (the one that already published a failure) delays stop until its shrink phase is done (heuristic: it waits until no tests are in `Large _` state).

### How to enable (YAML)

```yaml
corpusSync:
  enabled: true
  url: "ws://127.0.0.1:9010/ws"
  token: null
  publish:
    coverage: true
    failures: true
    maxPerSecond: 2
    burst: 20
    maxEntryBytes: 262144
    batchSize: 20
  ingest:
    enabled: true
    validate: replay   # none|replay|execute
    maxPending: 2000   # coverage-only backpressure; reproducers bypass
    maxPerMinute: 600  # coverage-only rate limit; reproducers bypass
    sampleRate: 1.0    # coverage entries only; reproducers always ingested
  behavior:
    stopOnFleetStop: true
    resume: true
```

### CLI flags

```bash
--corpus-sync true|false
--corpus-sync-url ws://... or wss://...
--corpus-sync-token TOKEN
--corpus-sync-validate none|replay|execute
--corpus-sync-sample-rate 0.0-1.0
--corpus-sync-max-entry-bytes N
--corpus-sync-stop-on-fleet-stop true|false
```

### Hub usage

After building, the hub binary is:
- `./result/bin/echidna-corpus-hub`

Example (no auth):
```bash
./result/bin/echidna-corpus-hub --host 0.0.0.0 --port 9010 --no-auth --data-dir ./hub_data
```

Example (token auth, and broadcast fleet_stop on first failure):
```bash
./result/bin/echidna-corpus-hub --host 0.0.0.0 --port 9010 --data-dir ./hub_data --token mytoken --broadcast-fleet-stop
```

Hub persistence layout (per campaign fingerprint):
- `hub_data/<campaign>/corpus/<entry_id>.txt` (JSON `[Tx]`)
- `hub_data/<campaign>/index.jsonl` (append-only index with seq + meta)

### v2 Improvements (Implemented)

Hub:
- **Default-on visibility:** logs connect/disconnect, failures, fleet_stop broadcasts, payload corruption/missing payloads, persistence write errors, and periodic stats (`--stats-interval-ms`).
- **Better operator UX:** hub stdout is line-buffered (so redirected `hub.log` updates immediately) and stats are emitted as one-line `stats_global` + `stats_campaign` events (or JSON with `--log-format json`).
- **Structured logs:** `--log-format text|json`.
- **Optional stats file:** `--stats-file PATH` writes a JSON snapshot each interval.
- **Reload on restart:** scans `hub_data/*/index.jsonl` on startup and rebuilds in-memory state so restarts don’t “forget” accepted entries.
- **Resume pagination:** adds `corpus_since_request` paging so clients can catch up beyond the previous 1000-entry truncation.
- **Backpressure + fanout control:** per-connection bounded queues for announcements and GET servicing (`--max-inflight-gets`), avoiding unbounded memory growth from slow clients.
- **Payload cache:** LRU-ish in-memory cache to reduce disk reads during GET storms (`--payload-cache-mb`).
- **Rate limiting + caps:** optional per-connection publish limit (`--max-publishes-per-minute`) and optional cap for coverage entries per campaign (`--max-coverage-entries`). Reproducers always bypass the cap.
- **Safety warning:** loud startup warning if `--no-auth` is used while listening on `0.0.0.0`/`::`.

Client:
- **Resume paging loop:** automatically pages `corpus_since_request` until caught up (when `corpusSync.behavior.resume=true`).
- **Enforces `ingest.maxPerMinute`:** coverage entry ingestion is token-bucket limited; reproducers always allowed.
- **Stricter `ingest.maxPending`:** refuses new coverage GETs when pending is too large; reproducers use high-priority enqueue.
- **Publish batching:** implements `publish.batchSize` via `corpus_publish_batch` when the hub advertises `supports_batch`.

### Known limitations / notes

- Hub is **ws:// only** (no built-in TLS). Use a reverse proxy / TLS terminator (Caddy/Nginx/stunnel) for `wss://`.
- Client TLS knobs exist in config (`corpusSync.tls`) but are not wired yet (v1 uses wuss defaults).
- `validate=execute` currently behaves the same as `replay` (cheap structural validation only).
- **Nix build gotcha:** `flake.nix` uses a git-cleaned source tree. If you add new `.hs` files and don't `git add` them, `nix build` will fail with errors like `Could not find module ‘Echidna.CorpusSync’`.
- Build note: because this repo uses `NoFieldSelectors` + `OverloadedRecordDot`, the corpus sync code imports the relevant record types with `(..)` (e.g., `EConfig`, `CampaignConf`, `CorpusSyncBehaviorConf`) so record-dot field access can be resolved by GHC.

---

## 10) RPC Fetch Retry + Timeout Hardening

**Problem:** Echidna crashes with `ResponseTimeout` when fetching storage slots through Anvil → upstream RPC (e.g. Tenderly). wreq's default timeout is 30s, but Anvil's upstream timeout is 45s, so Echidna gives up before Anvil gets the response.

### Changes

**hevm_custom** (`src/EVM/Fetch.hs`):
- `mkSession` now creates a wreq session with 60s response timeout (up from 30s default) so it outlasts Anvil's 45s upstream timeout.

**echidna_custom** (`lib/Echidna/Onchain.hs`):
- Added `retryFetch` helper: retries RPC fetch calls up to 3 times with 2s backoff between attempts.
- `safeFetchContractFrom` and `safeFetchSlotFrom` now use `retryFetch` instead of bare `catch`.
- After all retries fail, returns `FetchError` which still crashes in `Exec.hs` (preserving existing fail-fast behavior).

### Build note
Requires paired hevm_custom branch `fix/rpc-timeout-60s` for the 60s timeout. Build with:
```bash
HEVM_SRC=/path/to/hevm_custom nix build .#echidna --impure -L
```
