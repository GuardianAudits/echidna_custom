#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJ_DIR}"

HUB_PORT="${HUB_PORT:-9014}"

# This test used to rely on "time-to-failure" in a short run, which is flaky.
# The deterministic fleet-stop test below isolates the behavior we actually care about:
# - failure_publish happens
# - hub broadcasts fleet_stop
# - non-origin nodes stop cleanly (exit 0) due to stopOnFleetStop
HUB_PORT="${HUB_PORT}" exec "${PROJ_DIR}/scripts/test_corpus_sync_stop_on_fleet_stop.sh"
