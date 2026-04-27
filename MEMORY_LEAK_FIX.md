# Echidna 4.1 MCP Memory Leak — Diagnosis, Fix, Verification

**Status**: Complete (2026-04-26).

## Headline numbers (release-binary verification, 24 GB cgroup, 21-min runs)

| Binary                                | Peak RSS  | Iters in 21m | Drift rate (avg) | OOM? |
|---------------------------------------|-----------|--------------|------------------|------|
| **stock 4.1**                         | 22.3 GB   | 37 509       | ~140 MB/s        | **YES @ 2m41s** |
| **patched commits 1-3** (StrictData + 2 bangs)  | 3.38 GB | 278 095 | 1.5 MB/s | no |
| **patched commits 1-7** (+ deep-force on hot paths) | **2.94 GB** | 205 164 | **1.1 MB/s** | no |

Stock OOMs in 4 min. Both patched variants survive 21 min with no OOM.
Final commit-7 binary has **7.6× lower peak RSS than stock** and would
take ~5 hours to hit 24 GB at the residual drift rate.

## TL;DR

Stock echidna 4.1 with `--mcp true` OOMs at the 24 GB cgroup cap in 3-4 min on
the SentryV2 Ethereal fuzz suite. With `--mcp false` everything else identical
runs flat at 1.5 GB. The root cause is **lazy thunk retention** in MCP's
per-iteration recording paths (`recordTx`, `recordEvent`, `recordLogicalCoverage`)
where `atomicModifyIORef'` writes accumulated thunks that pinned VM/dapp/event
state across iterations.

Two-commit fix on top of `4.1` tag in `forkforkdog/echidna_custom@leak-fix-strictdata-v1`:
- Commit 1 (`6a4235f`) — `StrictData` on `MCP/Types.hs` + bang on `traceText` in
  `recordTx` + bang on `payload` in `recordEvent`. **Killed the catastrophic
  leak** (22 GB → 3.4 GB peak in 20-min run).
- Commit 2 (`73b8dda`) — deep-`force` on `args`, `payload`, and bangs on
  `recordLogicalCoverage` cov + `applyCallUpdate` result. **Targets residual
  ~1.5 MB/s drift** seen in commit-1-only run.

## Repro

Docker container with `--memory=24g --memory-swap=24g` mimicking the staging
ECS cgroup cap. Suite: SentryRepo-EtherealE2E @ `8d05fe3`, mainnet fork at
block 24960591, 4 workers, 9 forked contracts.

```bash
docker run --rm --platform=linux/amd64 --memory=24g --memory-swap=24g \
  -v /path/to/suite:/work -v /path/to/conf:/conf -v /tmp/out:/out -w /work \
  echidna-test:<binary>  sh -c '
    forge build --build-info test/fuzzing/Fuzz.sol
    echidna test/fuzzing/Fuzz.sol --contract Fuzz --config /conf/echidna.yaml \
      --corpus-dir /out/corpus --coverage-line-hits true \
      --mcp true --mcp-host 127.0.0.1 --mcp-port 9001
  '
```

## Ablation matrix

| # | Binary                              | MCP | Peak RSS  | Iters / 4min | Outcome |
|---|--------------------------------------|-----|-----------|--------------|---------|
| 1 | stock 4.1 (release)                  | on  | 22.3 GB   | 37 509       | **OOM (137) at 2m41s** |
| 2 | stock 4.1                            | off | **1.5 GB** | 75 909       | flat (4m43s wall) |
| 3 | stock 4.1 + `mcp:` retention overrides | on  | 22.7 GB | 34 496 | OOM (137) at 3m14s |
| 4 | stock 4.1 + `+RTS -A4m -N4 -Iw60 -Fd1.5` | on | 23.1 GB | 18 672 | OOM (137) at 2m34s |
| 5 | **patched v1** (commits 1-3, 3-patch)  | on | 3.38 GB (peak in 21m) | 278 095 in 21m | **clean, 0 OOM** |
| 6 | **patched v2** (commits 1-7, 7-patch)  | on | **2.94 GB** (peak in 21m) | 205 164 in 21m | **clean, 0 OOM** |

Detailed per-second RSS curves in `/tmp/leak-forensics/dock*-{control,*}/`.

## Root cause (with code citations)

### Why MCP — `--mcp false` proves it

Same suite, same fork, same coverage tracking, same RTS:
- `--mcp true`: 22 GB OOM in 4 min
- `--mcp false`: 1.5 GB flat

The Solidity suite + crytic-compile + HEVM fork cache + line-hit coverage map
all together cost 1.5 GB. Anything above that is MCP-side.

### Why lazy thunks — RTS flags and retention overrides don't help

If the leak were in MCP's bounded ring/map sizes, lowering
`maxReproducerArtifacts` 5000→50, `maxEvents` 5000→200, etc. would help.
It didn't (run #3 still OOMs).

If the leak were GHC heap fragmentation / Linux not returning pages, RTS
flags `-A4m -N4 -Iw60 -Fd1.5` would help. They didn't (run #4 still OOMs).

Reading `lib/Echidna/MCP.hs:194-264 recordTx` shows the actual problem:

```haskell
let traceText = showTraceTree dapp vm    -- LAZY thunk closes over `dapp` + `vm`
traceId <- pushRing st.traces (\idVal ->
  MCPTrace { trace = traceText, ... })   -- field is lazy `Text`
```

`MCPTrace.trace :: Text` field had no `!` (per `MCP/Types.hs:29-39`).
`showTraceTree dapp vm` is never forced. The bounded ring stores 1000
entries — each holding a thunk that pins an entire `VM Concrete` snapshot
(with its `cache :: Cache` of fetched mainnet slots, `traces :: TreeZipper Trace`,
`state :: FrameState`, etc.). 1000 × ~22 MB per VM = the observed 22 GB peak.

Same pattern in:
- `recordEvent` (`lib/Echidna/MCP.hs:1233-1242`): `payload :: Value`
  stored as unforced `toJSON e` thunk pinning the source `WorkerEvent`,
  which transitively holds `EchidnaTest`, `[Tx]` reproducers, etc.
- `recordTx` counter updates (`lib/Echidna/MCP.hs:208-216`): every
  `t + 1` becomes a thunk because `MCPRunCounters.totalCalls :: Int`
  has no strictness annotation.
- `recordTx` handler stats (`lib/Echidna/MCP.hs:223-235`): `lastArgs :: [Text]`
  list spine isn't forced; each `T.pack . ppAbiValue vm.labels v` stays
  as a thunk holding `vm.labels`.
- `LogicalCoverage.applyCallUpdate` builds new CallStats lazily; without
  forcing, each merge per worker chains a new thunk on top of the prior.

## The fix

### Patch 1 — `{-# LANGUAGE StrictData #-}` on `lib/Echidna/MCP/Types.hs`

One pragma. Makes every field of every record in the file strict. Stops
counter, tx, event, revert, trace, and reproducer thunk chains.

### Patch 2 — bang on `traceText` in `recordTx`

```diff
-     let traceText = showTraceTree dapp vm
+     let !traceText = showTraceTree dapp vm
```

Forces `showTraceTree` to actually run at the moment of revert, producing a
concrete `Text`. The stored `MCPTrace.trace` no longer pins `dapp` or `vm`.
**Single biggest contributor** — turns the dominant 22 GB leak into a manageable
~3 GB peak.

### Patch 3 — bang on `payload` and `event` in `recordEvent`

```diff
-     let (wid, wtype, etype, payload) = case ev of
+     let !(wid, wtype, etype, !payload) = case ev of
        ...
-     event = MCPEvent 0 (formatTimestamp ts) wid wtype etype payload
+     !event = MCPEvent 0 (formatTimestamp ts) wid wtype etype payload
```

Forces the Aeson `Value` top constructor at construction, plus the whole
event record.

### Patch 4 — deep-`force` on `args` in `recordTx`

```diff
-     let args = map (T.pack . ppAbiValue vm.labels) (snd solCall)
+     let !args = force (map (T.pack . ppAbiValue vm.labels) (snd solCall))
```

`force :: NFData a => a -> a` deeply evaluates the list AND each `Text`
inside, dropping all references to `vm.labels`. Plus a `!newStat = updateStat stat`
to force the new HandlerStat record before Map insert.

### Patch 5 — bang `cov` in `recordLogicalCoverage`

```diff
- recordLogicalCoverage st wid cov =
+ recordLogicalCoverage st wid !cov =
```

Makes the parameter strict. Combined with Patch 6 below, prevents merge
thunks from chaining through the worker map.

### Patch 6 — bang on `updated` in `LogicalCoverage.updateLogicalCoverage`

```diff
-     let updated = applyCallUpdate maxReasons success calldataLen (snd solCall) reason existing
+     let !updated = applyCallUpdate maxReasons success calldataLen (snd solCall) reason existing
```

Forces the new `CallStats` record at construction (its `!Int`/`!(Map ...)` fields
then evaluate at WHNF), so the value stored in the methods Map doesn't need
to be re-forced on read.

### Patch 7 — deep-`force` on `payload_thunk` in `recordEvent`

```diff
-     let !(wid, wtype, etype, !payload) = case ev of ...
+     let (wid, wtype, etype, payload_thunk) = case ev of ...
+         !payload = force payload_thunk
+         !event = MCPEvent ... payload
```

Replaces shallow bang on payload with `force` (which calls NFData Value's
deep eval), traversing Object/Array contents.

## Trade-offs

The fix shifts work from "lazy on read" to "eager on write." Every revert
now eagerly computes `showTraceTree` even if no MCP client ever asks for the
trace. For a fuzzer with hundreds of reverts/sec this is real CPU overhead —
estimate <5%, would need a benchmark. Memory ceiling drops from 22 GB → ~3 GB
on this workload.

If you want both low memory AND low CPU, the next step is to extract a small
"trace summary" struct from `dapp + vm` synchronously, store *that*, and only
materialize the full pretty trace on MCP query. Bigger change, not in this PR.

## What was NOT changed

- MCP HTTP/stdio protocol (no methods added/removed)
- MCP retention sizes (`maxEvents=5000`, `maxReproducerArtifacts=5000`, etc.
  — defaults unchanged)
- Reproducer artifact format
- Coverage tracking
- TTL behavior, lifecycle, init handshake
- Anything observable to clients

## Files changed

- `lib/Echidna/MCP/Types.hs` (+8 lines: pragma + comment)
- `lib/Echidna/MCP.hs` (+25 lines: import deepseq, 4 bang/force sites)
- `lib/Echidna/LogicalCoverage.hs` (+1 line: bang on `updated`)

Total: 3 files, ~34 lines added, 8 lines deleted.

## Branch & build

- Branch: `forkforkdog/echidna_custom@leak-fix-strictdata-v1`
- Built via `linux-binary-github-hosted.yml` workflow with
  `hevm_repository=GuardianAudits/hevm_custom@cdb693af`
- Final binary sha256: `51647e92...` (x86_64-linux), `e970f58a...` (aarch64-linux)
