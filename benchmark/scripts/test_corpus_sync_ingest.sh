#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"
HUB_BIN="${REPO_DIR}/result/bin/echidna-corpus-hub"

HUB_PORT="${HUB_PORT:-9016}"

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

OUT_DIR="${PROJ_DIR}/out/corpus_sync_ingest_${RUN_ID}"
mkdir -p "${OUT_DIR}"
cd "${PROJ_DIR}"

cleanup() {
  if [[ -n "${LISTENER_PID:-}" ]]; then
    kill -INT "${LISTENER_PID}" >/dev/null 2>&1 || true
    wait "${LISTENER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${HUB_PID:-}" ]]; then
    kill "${HUB_PID}" >/dev/null 2>&1 || true
    wait "${HUB_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Starting hub on port ${HUB_PORT} ..."
"${HUB_BIN}" \
  --host 127.0.0.1 \
  --port "${HUB_PORT}" \
  --data-dir "${OUT_DIR}/hub_data" \
  --no-auth \
  --stats-interval-ms 1000 \
  --stats-file "${OUT_DIR}/hub_stats.json" \
  >"${OUT_DIR}/hub.log" 2>&1 &
HUB_PID="$!"

sleep 0.5

echo "Starting listener node (ingest only) ..."
"${ECHIDNA_BIN}" \
  contracts/smoke/CoverageHitsSmoke.sol \
  --contract CoverageHitsSmoke \
  --config echidna/corpus_sync.listener.yaml \
  --seed 7100 \
  --test-limit 1000000000 \
  --corpus-dir "${OUT_DIR}/listener/corpus" \
  --corpus-sync true \
  --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
  >"${OUT_DIR}/listener.out" 2>"${OUT_DIR}/listener.err" &
LISTENER_PID="$!"

sleep 0.5

echo "Starting publisher node (coverage publish enabled) ..."
"${ECHIDNA_BIN}" \
  contracts/smoke/CoverageHitsSmoke.sol \
  --contract CoverageHitsSmoke \
  --config echidna/corpus_sync.publisher.yaml \
  --seed 7200 \
  --test-limit 1000000000 \
  --corpus-dir "${OUT_DIR}/publisher/corpus" \
  --coverage-dir "${OUT_DIR}/publisher/coverage" \
  --corpus-sync true \
  --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
  >"${OUT_DIR}/publisher.out" 2>"${OUT_DIR}/publisher.err" &
PUBLISHER_PID="$!"

echo "Letting nodes run for a few seconds to exchange corpus entries ..."
sleep 3

echo "Stopping publisher + listener ..."
kill -INT "${PUBLISHER_PID}" >/dev/null 2>&1 || true
kill -INT "${LISTENER_PID}" >/dev/null 2>&1 || true

wait "${PUBLISHER_PID}" >/dev/null 2>&1 || true
wait "${LISTENER_PID}" >/dev/null 2>&1 || true
PUBLISHER_PID=""
LISTENER_PID=""

python3 - <<PY
import pathlib

out = pathlib.Path("${OUT_DIR}")
hub_dir = out / "hub_data"
assert hub_dir.exists(), "missing hub_data"

campaigns = [p for p in hub_dir.iterdir() if p.is_dir()]
assert campaigns, "no campaign dirs created"

has_idx = any((c / "index.jsonl").exists() for c in campaigns)
assert has_idx, "missing index.jsonl in hub campaigns"

listener_cov = out / "listener" / "corpus" / "coverage"
files = list(listener_cov.glob("*.txt"))
assert files, f"listener did not persist any ingested entries to {listener_cov}"

print("ok: listener persisted", len(files), "ingested entries")
PY

echo "Corpus sync ingest test completed. Output in ${OUT_DIR}"
