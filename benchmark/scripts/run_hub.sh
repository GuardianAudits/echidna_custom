#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

HUB_BIN="${REPO_DIR}/result/bin/echidna-corpus-hub"

HOST="${HUB_HOST:-127.0.0.1}"
PORT="${HUB_PORT:-9010}"
DATA_DIR="${HUB_DATA_DIR:-${PROJ_DIR}/out/hub_data}"
STATS_FILE="${HUB_STATS_FILE:-${PROJ_DIR}/out/hub_stats.json}"

NO_AUTH="${HUB_NO_AUTH:-1}"
TOKEN="${HUB_TOKEN:-}"
BROADCAST_FLEET_STOP="${BROADCAST_FLEET_STOP:-0}"

if [[ ! -x "${HUB_BIN}" ]]; then
  echo "Missing executable: ${HUB_BIN}" >&2
  exit 1
fi

if [[ "${DATA_DIR}" != /* ]]; then
  DATA_DIR="${PROJ_DIR}/${DATA_DIR}"
fi
if [[ "${STATS_FILE}" != /* ]]; then
  STATS_FILE="${PROJ_DIR}/${STATS_FILE}"
fi

mkdir -p "${DATA_DIR}"
mkdir -p "$(dirname "${STATS_FILE}")"

ARGS=(--host "${HOST}" --port "${PORT}" --data-dir "${DATA_DIR}" --stats-interval-ms 10000 --stats-file "${STATS_FILE}")
if [[ "${NO_AUTH}" == "1" ]]; then
  ARGS+=(--no-auth)
else
  if [[ -z "${TOKEN}" ]]; then
    echo "HUB_NO_AUTH=0 requires HUB_TOKEN to be set" >&2
    exit 1
  fi
  ARGS+=(--token "${TOKEN}")
fi
if [[ "${BROADCAST_FLEET_STOP}" == "1" ]]; then
  ARGS+=(--broadcast-fleet-stop)
fi

exec "${HUB_BIN}" "${ARGS[@]}"
