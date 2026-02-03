# Custom Echidna + HEVM — Change Log

This document summarizes **all custom changes** applied so far in this repo + its paired `hevm` repo, with a focus on the three new cheatcodes:

- `doFunctionCall(address,bytes,address)`
- `snapshot()`
- `revertTo(uint256)`

It also documents Echidna’s integration so you can see the stats in output.

---

## 1) Overview of the 3 new cheatcodes

### A) `doFunctionCall(address target, bytes data, address actor)`
**Purpose:** Perform a **low‑level CALL** to `target` using `actor` as `msg.sender`, returning `(success, returndata)`.

**Behavior:**
- Executes an actual CALL in the EVM (not a precompile or a Solidity interface call).
- Uses the current call value from the VM.
- Returns the success flag + raw returndata (just like a low‑level `call`).
- Tracks per‑selector stats (success/fail counts) across the fuzz run.

**Selector stats recorded:**
- Total calls for that selector
- Successful calls
- Failed calls
- Success % (computed in Echidna UI/report)

---

### B) `snapshot()`
**Purpose:** Capture a **world‑state snapshot** (Foundry‑style). Returns `uint256 id`.

**Semantics (confirmed):**
- **World‑state only** (storage/balances/code, block/tx substate, logs/traces, forks)
- **Does not rewind execution** (pc/stack/memory unchanged)
- Persistent snapshots (not auto‑deleted)
- Unsupported in symbolic mode (Concrete only)

---

### C) `revertTo(uint256 id)`
**Purpose:** Restore a snapshot by id. Returns `bool`.

**Semantics (confirmed):**
- If id is **missing → throws** `BadCheatCode` (per user choice)
- Restores world‑state captured by snapshot
- Does **not** restore gas/constraints/freshVar/etc.

---

## 2) Where changes live (hevm repo)

### Cheatcode implementation
- **`hevm/src/EVM.hs`**
  - `cheatActions` contains the new cheatcodes
  - `doFunctionCall` implementation lives here
  - `snapshot`/`revertTo` logic + helpers live here

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

## 3) Echidna integration (this repo)

Echidna was modified to **collect and display selector stats** for `doFunctionCall`.

### State handling
- **`lib/Echidna/Types/Campaign.hs`**
  - Added `cheatCallStats` to `WorkerState`
- **`lib/Echidna/Exec.hs`**
  - Preserve `cheatCallStats` across revert resets
- **`lib/Echidna/Campaign.hs`**
  - Pull stats from VM back into `WorkerState`

### UI / reporting
- **`lib/Echidna/UI/Report.hs`**
  - Merge + format stats
  - Prints “Tracked calls” in end‑of‑run summary
- **`lib/Echidna/UI.hs`**
  - Shows compact “tracked: …” in live status line

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

**Example end‑of‑run output:**
```
Tracked calls:
  0x12345678: 8/10 ok (80.0%), 2 failed
```

**Example live line (interactive mode):**
```
..., tracked: 0x12345678 8/10 (80.0%) +2
```

---

## 4) How to call the cheatcodes in Solidity

### Cheatcode interface
```solidity
interface IHevmCheatcodes {
    function doFunctionCall(address target, bytes calldata data, address actor)
        external
        returns (bool success, bytes memory returndata);

    function snapshot() external returns (uint256 id);
    function revertTo(uint256 id) external returns (bool success);
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
(uint256 id) = hevm.snapshot();
// mutate state
(bool ok, ) = hevm.revertTo(id);
require(ok, "revertTo failed");
```

```solidity
(bool ok, bytes memory ret) = hevm.doFunctionCall(
    target,
    abi.encodeWithSelector(IMoneyMarketMain.operate.selector, nftId, 0, actionData),
    actor
);
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
```

### Build HEVM directly
```bash
cd /Users/robert/Documents/audits/others/echidna_hevm_custom/hevm
nix build .#ci -L --max-jobs auto --cores 0
```

Binary:
```
/Users/robert/Documents/audits/others/echidna_hevm_custom/hevm/result/bin/hevm
```

---

## 6) Known limitations / notes

- `snapshot()` and `revertTo()` are **concrete‑only**. Symbolic execution will throw `BadCheatCode`.
- Snapshots are **persistent**; there is no max count enforcement in v1.
- Cheat‑environment state (`labels`, `osEnv`, `cheatCallStats`) is **not reverted** on `revertTo`, per current decision.

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

**Purpose:** Provide a live, queryable view of Echidna runs, reverts, traces, handlers, logical coverage, cheatcode stats, and coverage hits via a local MCP‑style JSON‑RPC server plus a built‑in dashboard.

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
- Cheatcode stats (per selector)
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
- `echidna://coverage/summary`
- `echidna://coverage/lines`
- `echidna://stats/cheatcodes`
- `echidna://stats/logical-coverage`

### JSON‑RPC tools available

- `pause` / `resume` / `stop`
- `get_status`, `get_events`, `get_reverts`, `get_handlers`, `get_traces`
- `get_logical_coverage`, `get_coverage_hits`, `get_cheat_stats`

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
