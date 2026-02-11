#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"
HUB_BIN="${REPO_DIR}/result/bin/echidna-corpus-hub"

HUB_PORT="${HUB_PORT:-9014}"

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

OUT_DIR="${PROJ_DIR}/out/stop_on_fleet_stop_${RUN_ID}"
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

echo "Starting hub (broadcast fleet_stop) on port ${HUB_PORT} ..."
"${HUB_BIN}" \
  --host 127.0.0.1 \
  --port "${HUB_PORT}" \
  --data-dir "${OUT_DIR}/hub_data" \
  --no-auth \
  --broadcast-fleet-stop \
  --stats-interval-ms 1000 \
  --stats-file "${OUT_DIR}/hub_stats.json" \
  >"${OUT_DIR}/hub.log" 2>&1 &
HUB_PID="$!"

sleep 0.5

echo "Starting listener node (whitelist noise()) ..."
"${ECHIDNA_BIN}" \
  contracts/bench/FleetStopTarget.sol \
  --contract FleetStopTarget \
  --config echidna/fleet_stop.listener.yaml \
  --seed 9100 \
  --workers 1 \
  --corpus-dir "${OUT_DIR}/listener/corpus" \
  --corpus-sync true \
  --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
  >"${OUT_DIR}/listener.out" 2>"${OUT_DIR}/listener.err" &
LISTENER_PID="$!"

sleep 0.5

echo "Starting origin node (should find failure and trigger broadcast) ..."
set +e
"${ECHIDNA_BIN}" \
  contracts/bench/FleetStopTarget.sol \
  --contract FleetStopTarget \
  --config echidna/fleet_stop.origin.yaml \
  --workers 1 \
  --seed 9200 \
  --corpus-dir "${OUT_DIR}/origin/corpus" \
  --corpus-sync true \
  --corpus-sync-url "ws://127.0.0.1:${HUB_PORT}/ws" \
  >"${OUT_DIR}/origin.out" 2>"${OUT_DIR}/origin.err"
ORIGIN_EC="$?"
set -e

echo "Origin exit code: ${ORIGIN_EC}"

echo "Waiting for listener to stop due to fleet_stop ..."
for _ in $(seq 1 100); do
  if ! kill -0 "${LISTENER_PID}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if kill -0 "${LISTENER_PID}" >/dev/null 2>&1; then
  echo "Listener did not stop; failing" >&2
  exit 1
fi
wait "${LISTENER_PID}" || true
LISTENER_EC="$?"

python3 - <<PY
import pathlib
hub_log = pathlib.Path("${OUT_DIR}/hub.log").read_text(errors="ignore")
assert "fleet_stop_broadcast" in hub_log, "hub log missing fleet_stop_broadcast"
assert "failure_publish" in hub_log, "hub log missing failure_publish"
print("ok: hub broadcast observed")
PY

if [[ "${ORIGIN_EC}" -ne 1 ]]; then
  echo "Expected origin to exit 1 (found failure), got ${ORIGIN_EC}" >&2
  exit 1
fi
if [[ "${LISTENER_EC}" -ne 0 ]]; then
  echo "Expected listener to exit 0 (stopped by fleet_stop without failing), got ${LISTENER_EC}" >&2
  exit 1
fi

echo "ok: stopOnFleetStop works (origin failed; listener stopped cleanly)"
echo "Stop-on-fleet-stop test completed. Output in ${OUT_DIR}"
