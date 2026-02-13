#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"

TARGET_FILE="${TARGET_FILE:-contracts/smoke/CheatcodesSmoke.sol}"
TARGET_CONTRACT="${TARGET_CONTRACT:-CheatcodesSmoke}"

TEST_LIMIT="${TEST_LIMIT:-50}"
SEQ_LEN="${SEQ_LEN:-1}"
WORKERS="${WORKERS:-1}"

OUT_ROOT="${OUT_ROOT:-${PROJ_DIR}/out/cheatcodes_smoke}"
CORPUS_DIR="${OUT_ROOT}/corpus"
COV_DIR="${OUT_ROOT}/coverage"

if [[ ! -x "${ECHIDNA_BIN}" ]]; then
  echo "Missing executable: ${ECHIDNA_BIN}" >&2
  exit 1
fi

cd "${PROJ_DIR}"

rm -rf "${OUT_ROOT}"
mkdir -p "${OUT_ROOT}"

echo "Cheatcodes smoke test"
echo "Target: ${TARGET_CONTRACT} (${TARGET_FILE})"
echo "Limits: testLimit=${TEST_LIMIT}, seqLen=${SEQ_LEN}, workers=${WORKERS}"
echo "Output: ${OUT_ROOT}"

"${ECHIDNA_BIN}" \
  "${TARGET_FILE}" \
  --contract "${TARGET_CONTRACT}" \
  --test-mode property \
  --workers "${WORKERS}" \
  --seq-len "${SEQ_LEN}" \
  --test-limit "${TEST_LIMIT}" \
  --shrink-limit 0 \
  --format text \
  --disable-slither \
  --corpus-dir "${CORPUS_DIR}" \
  --coverage-dir "${COV_DIR}"

echo "OK"

