# MCP Server for Live Echidna Runs — Design Plan

Goal: expose a **local MCP server** while Echidna runs so we can query **live run state**, including events, reverts, coverage, and test status.

---

## 1) Objectives

- **Live visibility** into fuzzing runs: events, reverts, tests, coverage, and stats.
- **Handler visibility**: which handlers were called, with counts and last‑seen params.
- **Revert insight**: revert reasons and (if possible) call traces for failed calls.
- **Local-only** access (localhost or unix socket).
- **Low overhead** with bounded memory.
- **Compatible with MCP clients** (resources + tools).

Non‑goals:
- Remote access over the public internet.
- Full VM state inspection (memory/stack).
- Replaying or mutating state through MCP (read‑only by default).

---

## 2) Transport & Lifecycle

**Transport options** (choose one):
1) **HTTP (localhost)** with MCP over JSON‑RPC
2) **Unix domain socket**
3) **stdio** (if launched by an MCP host)

**Lifecycle:**
- MCP server starts when `--mcp` (or config `mcp.enabled: true`) is set.
- MCP server stops when Echidna exits.

---

## 3) Configuration & CLI

Config keys:
```yaml
mcp:
  enabled: true
  transport: "http"        # http | unix | stdio
  host: "127.0.0.1"        # http only
  port: 9001               # http only
  socketPath: "/tmp/echidna.mcp.sock"  # unix only
  maxEvents: 5000          # ring buffer size
  maxReverts: 1000         # ring buffer size
  maxTxs: 1000             # ring buffer size
```

CLI flags:
```
--mcp true|false
--mcp-transport http|unix|stdio
--mcp-host 127.0.0.1
--mcp-port 9001
--mcp-socket /tmp/echidna.mcp.sock
--mcp-max-events 5000
--mcp-max-reverts 1000
--mcp-max-txs 1000
```

Defaults:
- `enabled=false`
- `transport=http`
- `host=127.0.0.1`, `port=9001`
- medium ring buffer sizes to avoid memory growth

---

## 4) Data Model (in‑process)

Add a runtime cache in `Env`:
```hs
data MCPState = MCPState
  { events     :: RingBuffer MCPEvent
  , reverts    :: RingBuffer MCPRevert
  , txs        :: RingBuffer MCPTx
  , handlers   :: IORef HandlerStats
  , traces     :: RingBuffer MCPTrace
  , tests      :: IORef [EchidnaTest]
  , coverage   :: IORef CoverageSummary
  , logicalCov :: IORef LogicalCoverage
  , cheatStats :: IORef (Map FunctionSelector CheatCallStats)
  , counters   :: IORef MCPRunCounters
  }
```

Populate from:
- `eventQueue` (for live events)
- `WorkerState` updates (cheat stats, logical coverage)
- Coverage maps (periodically or on request)

---

## 5) MCP Resources (read‑only)

Expose resources for standard MCP discovery:

**Core:**
- `echidna://run/status`
- `echidna://run/config`
- `echidna://run/tests`
- `echidna://run/events?since=<id>`
- `echidna://run/reverts?since=<id>`
- `echidna://run/txs?since=<id>`
- `echidna://run/handlers` (called handlers with counts, last args)
- `echidna://run/traces?since=<id>` (revert call traces)

**Coverage:**
- `echidna://coverage/summary`
- `echidna://coverage/lines` (line hits, same as `coverage_hits.json`)

**Stats:**
- `echidna://stats/cheatcodes`
- `echidna://stats/logical-coverage`
- `echidna://stats/corpus`

Each resource returns JSON (stable schema).

---

## 6) MCP Tools (optional, still read‑only)

Tools provide filtered queries:

**get_status**
- returns run phase, total calls, corpus size, unique codehashes, etc.

**get_events**
- inputs: `since`, `limit`, `types`

**get_reverts**
- inputs: `since`, `limit`, `selector`, `reason`

**get_handlers**
- inputs: `limit`, `sort` (by calls, by failures)

**get_traces**
- inputs: `since`, `limit`, `selector`

**get_logical_coverage**
- inputs: `topN`

**get_coverage_hits**
- inputs: `file`, `line`

**get_cheat_stats**
- inputs: `selector`

Control tools:
- `pause`, `resume`, `stop`

---

## 7) Event Types

Store normalized, schema‑stable events:

- `NewCoverage`
- `TestFalsified`
- `TestOptimized`
- `TxSequenceReplayed`
- `TxSequenceReplayFailed`
- `SymExecLog` / `SymExecError`
- `WorkerStopped`

Each event includes:
```
id, ts, workerId, type, payload
```

Reverts also get extracted into a separate stream:
```
id, ts, contract, selector, reason, tx, calldata, gas, sender
```

Traces (if enabled) include:
```
id, ts, selector, reason, traceSteps[]
```

---

## 8) Implementation Plan (files)

New modules:
- `lib/Echidna/MCP.hs` (server + MCP wiring)
- `lib/Echidna/MCP/Types.hs` (schemas)
- `lib/Echidna/MCP/Store.hs` (ring buffers)

Touch points:
- `lib/Echidna/Types/Config.hs` (config keys)
- `lib/Echidna/Config.hs` (parser defaults)
- `src/Main.hs` (CLI flags + start server)
- `lib/Echidna/Worker.hs` / `Campaign.hs` (push events)
- `lib/Echidna/Output/Source.hs` (reuse coverage hits)

---

## 9) Security & Safety

- Bind to **localhost** or **unix socket** only.
- No code execution or file access tools.
- Read‑only by default, except when control tools are enabled.
- Rate limit large responses (max items per query).

---

## 10) Testing Plan

- Unit tests for resource serialization.
- Integration test: start echidna with MCP enabled, query `/run/status`.
- Verify ring buffer truncation.

---

## 11) Open Questions

1) Transport preference: **unix socket vs http**?
2) Do you want **control tools** (pause/stop), or **read‑only** only?
3) Event retention size defaults?
4) Should MCP auto‑enable when `--server` (SSE) is enabled, or separate flag only?

---

## 12) Resolved Choices (from user)

- **Transport**: HTTP (localhost)
- **Access level**: Control tools enabled (pause/resume/stop)
- **Retention**: Medium ring buffers
- **Auto‑enable**: Explicit only (`--mcp` / config)
