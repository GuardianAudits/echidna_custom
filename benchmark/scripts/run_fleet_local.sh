#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"
HUB_BIN="${REPO_DIR}/result/bin/echidna-corpus-hub"

TARGET_CONTRACT="${TARGET_CONTRACT:-CorpusMaze}"
TARGET_FILE="${TARGET_FILE:-contracts/bench/CorpusMaze.sol}"

NODES="${NODES:-2}"
WORKERS_PER_NODE="${WORKERS_PER_NODE:-2}"
HUB_PORT="${HUB_PORT:-9010}"

OUT_ROOT="${OUT_ROOT:-${PROJ_DIR}/out/fleet_local}"

if [[ ! -x "${ECHIDNA_BIN}" ]]; then
  echo "Missing executable: ${ECHIDNA_BIN}" >&2
  exit 1
fi
if [[ ! -x "${HUB_BIN}" ]]; then
  echo "Missing executable: ${HUB_BIN}" >&2
  exit 1
fi

if [[ "${OUT_ROOT}" != /* ]]; then
  OUT_ROOT="${PROJ_DIR}/${OUT_ROOT}"
fi

mkdir -p "${OUT_ROOT}"
cd "${PROJ_DIR}"

cleanup() {
  if [[ -n "${HUB_PID:-}" ]]; then
    kill "${HUB_PID}" >/dev/null 2>&1 || true
    wait "${HUB_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${NODE_PIDS:-}" ]]; then
    for pid in ${NODE_PIDS}; do
      kill "${pid}" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

echo "Starting corpus hub on port ${HUB_PORT} ..."
HUB_DIR="${OUT_ROOT}/hub_data"
mkdir -p "${HUB_DIR}"
"${HUB_BIN}" \
  --host 127.0.0.1 \
  --port "${HUB_PORT}" \
  --data-dir "${HUB_DIR}" \
  --no-auth \
  --stats-interval-ms 2000 \
  --stats-file "${OUT_ROOT}/hub_stats.json" \
  >"${OUT_ROOT}/hub.log" 2>&1 &
HUB_PID="$!"

sleep 0.5

echo "Starting ${NODES} nodes (workers/node=${WORKERS_PER_NODE}) ..."
NODE_PIDS=""
for i in $(seq 1 "${NODES}"); do
  NODE_DIR="${OUT_ROOT}/node_${i}"
  mkdir -p "${NODE_DIR}"
  "${ECHIDNA_BIN}" \
    "${TARGET_FILE}" \
    --contract "${TARGET_CONTRACT}" \
    --config echidna/bench.fleet.yaml \
    --workers "${WORKERS_PER_NODE}" \
    --seed "$((1000 + i))" \
    --corpus-dir "${NODE_DIR}/corpus" \
    --coverage-dir "${NODE_DIR}/coverage" \
    --corpus-sync true \
    --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
    >"${NODE_DIR}/out.json" 2>"${NODE_DIR}/err.log" &
  NODE_PIDS="${NODE_PIDS} $!"
done

for pid in ${NODE_PIDS}; do
  wait "${pid}" || true
done

echo "Fleet run complete. Outputs in ${OUT_ROOT}"
