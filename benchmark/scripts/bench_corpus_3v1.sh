#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_ID="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

# Benchmark: time-to-failure for a deep stateful target.
# Compares:
# - baseline: single Echidna instance with TOTAL_WORKERS workers
# - fleet: NODES Echidna instances with (TOTAL_WORKERS/NODES) workers each + distributed corpus sync
#
# Default is a fair "3 vs 1" comparison in terms of total workers:
# - baseline: 1 process, 3 workers
# - fleet: 3 processes, 1 worker each, corpus sync enabled, hub broadcasts fleet_stop

TARGET_CONTRACT="${TARGET_CONTRACT:-CorpusMaze}"
TARGET_FILE="${TARGET_FILE:-contracts/bench/CorpusMaze.sol}"

NODES="${NODES:-3}"
TOTAL_WORKERS="${TOTAL_WORKERS:-3}"
REPEATS="${REPEATS:-5}"
HUB_PORT="${HUB_PORT:-9020}"

OUT_ROOT="${OUT_ROOT:-${PROJ_DIR}/out/bench_corpus_3v1_${RUN_ID}}"

# Stop other nodes quickly when one finds a failure.
BROADCAST_FLEET_STOP="${BROADCAST_FLEET_STOP:-1}"

cd "${PROJ_DIR}"

echo "Benchmark: distributed corpus (fleet) vs single Echidna"
echo "Target: ${TARGET_CONTRACT} (${TARGET_FILE})"
echo "Baseline: 1 process, workers=${TOTAL_WORKERS}"
echo "Fleet: nodes=${NODES}, workers/node=floor(${TOTAL_WORKERS}/${NODES}) (min 1), hub_port=${HUB_PORT}, broadcast_fleet_stop=${BROADCAST_FLEET_STOP}"
echo "Repeats: ${REPEATS}"
echo "Output: ${OUT_ROOT}"

TARGET_CONTRACT="${TARGET_CONTRACT}" \
TARGET_FILE="${TARGET_FILE}" \
NODES="${NODES}" \
TOTAL_WORKERS="${TOTAL_WORKERS}" \
REPEATS="${REPEATS}" \
HUB_PORT="${HUB_PORT}" \
OUT_ROOT="${OUT_ROOT}" \
BROADCAST_FLEET_STOP="${BROADCAST_FLEET_STOP}" \
  "${PROJ_DIR}/scripts/bench_distributed.sh"

python3 - <<PY
import json
import statistics
from pathlib import Path

out_root = Path("${OUT_ROOT}")
results_path = out_root / "results.jsonl"
assert results_path.exists(), f"missing results: {results_path}"

rows = [json.loads(l) for l in results_path.read_text().splitlines() if l.strip()]
baseline = [r for r in rows if r.get("mode") == "baseline"]
fleet = [r for r in rows if r.get("mode") == "fleet"]

def summarize(label, xs):
    if not xs:
        return None
    durs = [x["duration_ms"] for x in xs if isinstance(x.get("duration_ms"), int)]
    if not durs:
        return None
    return {
        "label": label,
        "n": len(durs),
        "min_ms": min(durs),
        "median_ms": int(statistics.median(durs)),
        "mean_ms": int(statistics.mean(durs)),
        "max_ms": max(durs),
    }

summary = {
    "target_contract": "${TARGET_CONTRACT}",
    "nodes": int("${NODES}"),
    "total_workers": int("${TOTAL_WORKERS}"),
    "repeats": int("${REPEATS}"),
    "hub_port": int("${HUB_PORT}"),
    "broadcast_fleet_stop": int("${BROADCAST_FLEET_STOP}"),
    "effective_total_workers_baseline": baseline[0].get("effective_total_workers") if baseline else None,
    "effective_total_workers_fleet": fleet[0].get("effective_total_workers") if fleet else None,
    "baseline": summarize("baseline", baseline),
    "fleet": summarize("fleet", fleet),
}

(out_root / "summary.json").write_text(json.dumps(summary, indent=2) + "\\n")
print("Wrote:", out_root / "summary.json")
print(json.dumps(summary, indent=2))
PY

echo "Done."
