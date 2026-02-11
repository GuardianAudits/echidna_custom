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
TOTAL_WORKERS="${TOTAL_WORKERS:-4}"
REPEATS="${REPEATS:-3}"
HUB_PORT="${HUB_PORT:-9010}"
OUT_ROOT="${OUT_ROOT:-${PROJ_DIR}/out/bench}"
BROADCAST_FLEET_STOP="${BROADCAST_FLEET_STOP:-0}"

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

WORKERS_PER_NODE=$((TOTAL_WORKERS / NODES))
if [[ "${WORKERS_PER_NODE}" -lt 1 ]]; then
  WORKERS_PER_NODE=1
fi

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

mkdir -p "${OUT_ROOT}"
RESULTS="${OUT_ROOT}/results.jsonl"

cd "${PROJ_DIR}"

echo "Target: ${TARGET_CONTRACT} (${TARGET_FILE})"
echo "Baseline: 1 node, workers=${TOTAL_WORKERS}"
echo "Fleet: nodes=${NODES}, workers/node=${WORKERS_PER_NODE}, hub_port=${HUB_PORT}"
echo "Writing: ${RESULTS}"

for r in $(seq 1 "${REPEATS}"); do
  RUN_DIR="${OUT_ROOT}/run_${r}_$(now_ms)"
  mkdir -p "${RUN_DIR}"

  # ---- baseline ----
  BASE_OUT="${RUN_DIR}/baseline.json"
  BASE_LOG="${RUN_DIR}/baseline.log"
  BASE_CORPUS_DIR="${RUN_DIR}/baseline/corpus"
  BASE_COVERAGE_DIR="${RUN_DIR}/baseline/coverage"
  BASE_SEED=$((10000 + r))

  START_MS="$(now_ms)"
  set +e
  "${ECHIDNA_BIN}" \
    "${TARGET_FILE}" \
    --contract "${TARGET_CONTRACT}" \
    --config echidna/bench.single.yaml \
    --workers "${TOTAL_WORKERS}" \
    --seed "${BASE_SEED}" \
    --corpus-dir "${BASE_CORPUS_DIR}" \
    --coverage-dir "${BASE_COVERAGE_DIR}" \
    >"${BASE_OUT}" 2>"${BASE_LOG}"
  BASE_EC="$?"
  set -e
  END_MS="$(now_ms)"
  BASE_DUR_MS=$((END_MS - START_MS))

  python3 - <<PY >>"${RESULTS}"
import json, time
print(json.dumps({
  "ts_ms": int(time.time()*1000),
  "repeat": ${r},
  "mode": "baseline",
  "target_contract": "${TARGET_CONTRACT}",
  "nodes": 1,
  "total_workers": ${TOTAL_WORKERS},
  "effective_total_workers": ${TOTAL_WORKERS},
  "workers_per_node": ${TOTAL_WORKERS},
  "seed": ${BASE_SEED},
  "exit_code": ${BASE_EC},
  "duration_ms": ${BASE_DUR_MS},
  "out_json": "${BASE_OUT}",
  "corpus_dir": "${BASE_CORPUS_DIR}",
  "coverage_dir": "${BASE_COVERAGE_DIR}",
}))
PY

  # ---- fleet ----
  HUB_DIR="${RUN_DIR}/hub_data"
  HUB_LOG="${RUN_DIR}/hub.log"
  HUB_STATS="${RUN_DIR}/hub_stats.json"

  mkdir -p "${HUB_DIR}"

  HUB_ARGS=(
    --host 127.0.0.1
    --port "${HUB_PORT}"
    --data-dir "${HUB_DIR}"
    --no-auth
    --stats-interval-ms 2000
    --stats-file "${HUB_STATS}"
  )
  if [[ "${BROADCAST_FLEET_STOP}" == "1" ]]; then
    HUB_ARGS+=(--broadcast-fleet-stop)
  fi

  set +e
  "${HUB_BIN}" "${HUB_ARGS[@]}" >"${HUB_LOG}" 2>&1 &
  HUB_PID="$!"
  set -e

  # give hub a moment to bind the port
  sleep 0.5

  NODE_ECS=()
  NODE_PIDS=()
  NODE_OUTS=()
  NODE_SEEDS=()

  FLEET_START_MS="$(now_ms)"
  for i in $(seq 1 "${NODES}"); do
    NODE_DIR="${RUN_DIR}/fleet_node_${i}"
    mkdir -p "${NODE_DIR}"

    NODE_SEED=$((20000 + r * 100 + i))
    NODE_SEEDS+=("${NODE_SEED}")
    NODE_OUTS+=("${NODE_DIR}/out.json")

    set +e
    "${ECHIDNA_BIN}" \
      "${TARGET_FILE}" \
      --contract "${TARGET_CONTRACT}" \
      --config echidna/bench.fleet.yaml \
      --workers "${WORKERS_PER_NODE}" \
      --seed "${NODE_SEED}" \
      --corpus-dir "${NODE_DIR}/corpus" \
      --coverage-dir "${NODE_DIR}/coverage" \
      --corpus-sync true \
      --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
      >"${NODE_DIR}/out.json" 2>"${NODE_DIR}/err.log" &
    NODE_PIDS+=("$!")
    set -e
  done

  for idx in "${!NODE_PIDS[@]}"; do
    pid="${NODE_PIDS[$idx]}"
    set +e
    wait "${pid}"
    NODE_ECS+=("$?")
    set -e
  done
  FLEET_END_MS="$(now_ms)"
  FLEET_DUR_MS=$((FLEET_END_MS - FLEET_START_MS))

  kill "${HUB_PID}" >/dev/null 2>&1 || true
  wait "${HUB_PID}" >/dev/null 2>&1 || true

  NODE_SEEDS_JOIN="$(IFS=,; echo "${NODE_SEEDS[*]}")"
  NODE_ECS_JOIN="$(IFS=,; echo "${NODE_ECS[*]}")"

  python3 - <<PY >>"${RESULTS}"
import json, time
print(json.dumps({
  "ts_ms": int(time.time()*1000),
  "repeat": ${r},
  "mode": "fleet",
  "target_contract": "${TARGET_CONTRACT}",
  "nodes": ${NODES},
  "total_workers": ${TOTAL_WORKERS},
  "effective_total_workers": ${NODES} * ${WORKERS_PER_NODE},
  "workers_per_node": ${WORKERS_PER_NODE},
  "hub_port": ${HUB_PORT},
  "broadcast_fleet_stop": ${BROADCAST_FLEET_STOP},
  "node_seeds": [${NODE_SEEDS_JOIN}],
  "node_exit_codes": [${NODE_ECS_JOIN}],
  "duration_ms": ${FLEET_DUR_MS},
  "hub_stats_file": "${HUB_STATS}",
  "hub_log": "${HUB_LOG}",
}))
PY
done

echo "Bench complete. Results appended to ${RESULTS}"
