# Benchmarking Guide (Embedded in `echidna/benchmark`)

This folder is self-contained for benchmarking the custom Echidna features, especially **Distributed Corpus Sync speed**.

## What this benchmark measures
- Target bug: `contracts/bench/CorpusMaze.sol` (`echidna_maze_unsolved()` falsifies when maze is solved)
- Metric: **time-to-failure** (milliseconds)
- Comparison modes:
  - `baseline`: 1 Echidna process with `TOTAL_WORKERS`
  - `fleet`: `NODES` Echidna processes + distributed corpus sync through hub

---

## Repos needed

### To run benchmarks (already built binaries)
- Only this repo is required: `echidna`
- Required binaries in this repo:
  - `result/bin/echidna`
  - `result/bin/echidna-corpus-hub`

### To rebuild binaries from source
- `echidna` + `hevm` (local linked custom hevm)

---

## Folder layout (inside `echidna` repo)

```text
benchmark/
  benchmarking.md
  contracts/
    bench/CorpusMaze.sol
    bench/FleetStopTarget.sol
    smoke/CoverageHitsSmoke.sol
  echidna/
    bench.single.yaml
    bench.fleet.yaml
    corpus_sync.listener.yaml
    corpus_sync.publisher.yaml
    fleet_stop.listener.yaml
    fleet_stop.origin.yaml
  scripts/
    bench_corpus_3v1.sh
    bench_distributed.sh
    run_hub.sh
    run_fleet_local.sh
    test_corpus_sync_ingest.sh
    test_corpus_sync_hub_reload.sh
    test_corpus_sync_stop_on_fleet_stop.sh
    test_corpus_sync_fleet_stop.sh
  out/
```

---

## Prerequisites
- `bash`
- `python3`
- `rg` (used by one companion test)
- built binaries (`result/bin/*`)

From repo root, quick check:

```bash
cd echidna
ls -l result/bin/echidna
ls -l result/bin/echidna-corpus-hub
```

---

## Main benchmark (Distributed Corpus Sync speed)

Run from **repo root** (`echidna/`):

### 1) Fair worker comparison
(1 process x 3 workers) vs (3 processes x 1 worker each + sync)

```bash
cd echidna
REPEATS=5 NODES=3 TOTAL_WORKERS=3 HUB_PORT=9020 ./benchmark/scripts/bench_corpus_3v1.sh
```

### 2) 3-process fleet vs 1-worker single process

```bash
cd echidna
REPEATS=5 NODES=3 TOTAL_WORKERS=1 HUB_PORT=9021 ./benchmark/scripts/bench_corpus_3v1.sh
```

### 3) Optional: keep fleet alive after first failure
(default behavior may stop fleet quickly via `fleet_stop`)

```bash
cd echidna
BROADCAST_FLEET_STOP=0 REPEATS=5 NODES=3 TOTAL_WORKERS=3 HUB_PORT=9022 ./benchmark/scripts/bench_corpus_3v1.sh
```

---

## Outputs

Each run writes to:
- `benchmark/out/bench_corpus_3v1_<timestamp>/results.jsonl`
- `benchmark/out/bench_corpus_3v1_<timestamp>/summary.json`

Quick inspect latest summary:

```bash
cd echidna
LATEST=$(ls -td benchmark/out/bench_corpus_3v1_* | head -n1)
echo "$LATEST"
cat "$LATEST/summary.json"
```

Key fields:
- `baseline.median_ms`
- `fleet.median_ms`
- `effective_total_workers_baseline`
- `effective_total_workers_fleet`

Interpretation rule:
- Compare medians across equal effective worker counts first.

---

## Companion corpus-sync validation tests

These are functional checks around sync behavior (ingest/reload/fleet stop), not pure speed benchmarks.

```bash
cd echidna
HUB_PORT=9016 ./benchmark/scripts/test_corpus_sync_ingest.sh
HUB_PORT=9011 ./benchmark/scripts/test_corpus_sync_hub_reload.sh
HUB_PORT=9014 ./benchmark/scripts/test_corpus_sync_stop_on_fleet_stop.sh
```

Alias test:

```bash
cd echidna
HUB_PORT=9014 ./benchmark/scripts/test_corpus_sync_fleet_stop.sh
```

---

## Multi-machine benchmark (optional)

### Hub node
```bash
cd echidna
HUB_HOST=0.0.0.0 HUB_PORT=9010 HUB_NO_AUTH=1 ./benchmark/scripts/run_hub.sh
```

### Worker node(s)
```bash
cd echidna
./result/bin/echidna benchmark/contracts/bench/CorpusMaze.sol \
  --contract CorpusMaze \
  --config benchmark/echidna/bench.fleet.yaml \
  --workers 1 \
  --seed 12345 \
  --corpus-dir benchmark/out/remote_node/corpus \
  --coverage-dir benchmark/out/remote_node/coverage \
  --corpus-sync true \
  --corpus-sync-url ws://<HUB_IP>:9010/ws
```

Network checklist:
- Hub port open (default 9010)
- Workers can reach `ws://<HUB_IP>:<PORT>/ws`
- Add auth/TLS proxy if not on trusted network

---

## Reproducibility tips
- Keep machine load low
- Keep `REPEATS/NODES/TOTAL_WORKERS` constant per experiment
- Use medians, not single-run results
- Run one warm-up before recording data
- Keep same contract + yaml settings across comparisons

---

## Troubleshooting

### Missing binary
If script says missing executable, check:
- `result/bin/echidna`
- `result/bin/echidna-corpus-hub`

### Port conflict
Pick another `HUB_PORT`.

```bash
lsof -iTCP:<PORT> -sTCP:LISTEN
```

### Fleet slower than baseline
Common reasons:
- target too easy/short (sync overhead dominates)
- unfair worker split (`TOTAL_WORKERS / NODES` floors to 1)
- local hub/network overhead

---

## One-command quick start

```bash
cd echidna
REPEATS=5 NODES=3 TOTAL_WORKERS=3 HUB_PORT=9020 ./benchmark/scripts/bench_corpus_3v1.sh
LATEST=$(ls -td benchmark/out/bench_corpus_3v1_* | head -n1)
cat "$LATEST/summary.json"
```

## Cheatcode smoke + microbenchmark suite

The cheatcode suite runs only property smoke checks and per-cheatcode microbenchmarks (no distributed corpus benchmark):

```bash
cd /Users/robert/Documents/audits/others/echidna_hevm_custom/echidna
ECHIDNA_BIN="$(realpath result/bin/echidna)"
./benchmark/scripts/run_cheatcodes_suite.sh "${ECHIDNA_BIN}" \
  --repeats 5 \
  --workers 1 \
  --seq-len 1 \
  --test-limit 500 \
  --smoke-test-limit 50
```
