#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"
HUB_BIN="${REPO_DIR}/result/bin/echidna-corpus-hub"

HUB_PORT="${HUB_PORT:-9011}"

if [[ ! -x "${ECHIDNA_BIN}" ]]; then
  echo "Missing executable: ${ECHIDNA_BIN}" >&2
  exit 1
fi
if [[ ! -x "${HUB_BIN}" ]]; then
  echo "Missing executable: ${HUB_BIN}" >&2
  exit 1
fi

RUN_ID="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

OUT_DIR="${PROJ_DIR}/out/hub_reload_${RUN_ID}"
HUB_DIR="${OUT_DIR}/hub_data"
STATS_FILE="${OUT_DIR}/hub_stats.json"

mkdir -p "${OUT_DIR}" "${HUB_DIR}"
cd "${PROJ_DIR}"

cleanup() {
  if [[ -n "${HUB_PID:-}" ]]; then
    kill "${HUB_PID}" >/dev/null 2>&1 || true
    wait "${HUB_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Starting hub (1st) on port ${HUB_PORT} ..."
"${HUB_BIN}" \
  --host 127.0.0.1 \
  --port "${HUB_PORT}" \
  --data-dir "${HUB_DIR}" \
  --no-auth \
  --stats-interval-ms 1000 \
  --stats-file "${STATS_FILE}" \
  >"${OUT_DIR}/hub_1.log" 2>&1 &
HUB_PID="$!"

sleep 0.5

echo "Running one node to publish corpus entries ..."
"${ECHIDNA_BIN}" \
  contracts/bench/CorpusMaze.sol \
  --contract CorpusMaze \
  --config echidna/bench.fleet.yaml \
  --workers 1 \
  --seed 777 \
  --test-limit 2000 \
  --seq-len 200 \
  --corpus-dir "${OUT_DIR}/node/corpus" \
  --coverage-dir "${OUT_DIR}/node/coverage" \
  --corpus-sync true \
  --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
  >"${OUT_DIR}/node.out" 2>"${OUT_DIR}/node.err" || true

echo "Stopping hub (1st) ..."
kill "${HUB_PID}" >/dev/null 2>&1 || true
wait "${HUB_PID}" >/dev/null 2>&1 || true
HUB_PID=""

python3 - <<'PY'
import json, pathlib

out = pathlib.Path("out").resolve()
dirs = sorted([p for p in out.glob("hub_reload_*") if p.is_dir()], key=lambda p: p.name)
assert dirs, "missing hub_reload_* output dir"
run = dirs[-1]
hub_dir = run / "hub_data"
assert hub_dir.exists(), "missing hub_data dir"

campaigns = [p for p in hub_dir.iterdir() if p.is_dir()]
assert campaigns, "hub_data has no campaign dirs"

ok = False
for c in campaigns:
    idx = c / "index.jsonl"
    corpus = c / "corpus"
    if idx.exists() and corpus.exists():
        corpus_files = list(corpus.glob("*.txt"))
        if corpus_files:
            ok = True
            break

assert ok, "expected at least one campaign with index.jsonl and corpus/*.txt"

stats_file = run / "hub_stats.json"
assert stats_file.exists(), "missing hub_stats.json"
json.loads(stats_file.read_text())  # parseable snapshot
print("ok: hub persisted campaign data + stats snapshot")
PY

echo "Starting hub (2nd) to validate reload ..."
"${HUB_BIN}" \
  --host 127.0.0.1 \
  --port "${HUB_PORT}" \
  --data-dir "${HUB_DIR}" \
  --no-auth \
  --stats-interval-ms 1000 \
  --stats-file "${STATS_FILE}" \
  >"${OUT_DIR}/hub_2.log" 2>&1 &
HUB_PID="$!"

sleep 0.5
kill "${HUB_PID}" >/dev/null 2>&1 || true
wait "${HUB_PID}" >/dev/null 2>&1 || true
HUB_PID=""

rg -n "campaign_loaded" "${OUT_DIR}/hub_2.log" >/dev/null
echo "ok: hub reload logged campaign_loaded"
echo "Hub reload test completed. Output in ${OUT_DIR}"

