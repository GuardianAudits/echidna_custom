#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./run_cheatcodes_suite.sh <echidna-binary> [options]

Run cheatcode smoke checks and cheatcode microbenchmarks.
This script intentionally focuses only on cheatcode coverage; it skips
distributed corpus benchmarks.

Required:
  <echidna-binary>   Path to the Echidna executable to run.

Options:
  --repeats N             Number of repetitions per benchmark (default: 5)
  --workers N             Echidna worker count (default: 1)
  --seq-len N             Echidna sequence length (default: 1)
  --test-limit N          Test-limit for benchmarks (default: 500)
  --smoke-test-limit N     Test-limit for smoke validation (default: 50)
  --out-root DIR          Output root directory override
  --help, -h              Show this message
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

ECHIDNA_BIN="${1//$'\r'/}"
# If callers accidentally pass a wrapped/multi-line command-substitution result,
# keep only the first resolved path (this commonly happens when copy-pasting realpath
# across lines). Leading/trailing whitespace is still tolerated.
ECHIDNA_BIN="$(printf '%s' "${ECHIDNA_BIN}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
ECHIDNA_BIN="$(printf '%s\n' "${ECHIDNA_BIN}" | sed -n '1p')"
shift || true

REPEATS="${REPEATS:-5}"
WORKERS="${WORKERS:-1}"
SEQ_LEN="${SEQ_LEN:-1}"
TEST_LIMIT="${TEST_LIMIT:-500}"
SMOKE_TEST_LIMIT="${SMOKE_TEST_LIMIT:-50}"
OUT_ROOT="${OUT_ROOT:-}"

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --repeats)
      REPEATS="${2}"
      shift 2
      ;;
    --workers)
      WORKERS="${2}"
      shift 2
      ;;
    --seq-len)
      SEQ_LEN="${2}"
      shift 2
      ;;
    --test-limit)
      TEST_LIMIT="${2}"
      shift 2
      ;;
    --smoke-test-limit)
      SMOKE_TEST_LIMIT="${2}"
      shift 2
      ;;
    --out-root)
      OUT_ROOT="${2}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: ${1}"
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"
SMOKE_TARGET="${SMOKE_TARGET:-contracts/smoke/CheatcodesSmoke.sol}"
SMOKE_CONTRACT="${SMOKE_CONTRACT:-CheatcodesSmoke}"
BENCH_TARGET="${BENCH_TARGET:-contracts/bench/CheatcodesBench.sol}"
BENCH_CONFIG="${BENCH_CONFIG:-echidna/bench.cheatcodes.yaml}"
BENCH_CONFIG_FFI="${BENCH_CONFIG_FFI:-echidna/bench.cheatcodes.ffi.yaml}"

if [[ -d "${ECHIDNA_BIN}" ]]; then
  if [[ -x "${ECHIDNA_BIN}/bin/echidna" ]]; then
    echo "INFO: received directory, using ${ECHIDNA_BIN}/bin/echidna"
    ECHIDNA_BIN="${ECHIDNA_BIN}/bin/echidna"
  else
    echo "Missing or non-executable binary: ${ECHIDNA_BIN}" >&2
    echo "Expected a file path, e.g. result/bin/echidna" >&2
    exit 1
  fi
fi

if [[ ! -f "${ECHIDNA_BIN}" || ! -x "${ECHIDNA_BIN}" ]]; then
  echo "Missing or non-executable binary: ${ECHIDNA_BIN}" >&2
  exit 1
fi
resolve_path() {
  local candidate="$1"
  if [[ "${candidate}" = /* ]]; then
    echo "${candidate}"
  else
    echo "${PROJ_DIR}/${candidate}"
  fi
}

SMOKE_TARGET_PATH="$(resolve_path "${SMOKE_TARGET}")"
BENCH_TARGET_PATH="$(resolve_path "${BENCH_TARGET}")"
BENCH_CONFIG_PATH="$(resolve_path "${BENCH_CONFIG}")"
BENCH_CONFIG_FFI_PATH="$(resolve_path "${BENCH_CONFIG_FFI}")"

if [[ ! -f "${SMOKE_TARGET_PATH}" ]]; then
  echo "Missing file: ${SMOKE_TARGET_PATH}" >&2
  exit 1
fi
if [[ ! -f "${BENCH_TARGET_PATH}" ]]; then
  echo "Missing file: ${BENCH_TARGET_PATH}" >&2
  exit 1
fi
if [[ ! -f "${BENCH_CONFIG_PATH}" ]]; then
  echo "Missing file: ${BENCH_CONFIG_PATH}" >&2
  exit 1
fi
if [[ ! -f "${BENCH_CONFIG_FFI_PATH}" ]]; then
  echo "Missing file: ${BENCH_CONFIG_FFI_PATH}" >&2
  exit 1
fi

if ! [[ "${REPEATS}" =~ ^[0-9]+$ ]] || (( REPEATS <= 0 )); then
  echo "Invalid --repeats value: ${REPEATS}" >&2
  exit 1
fi
if ! [[ "${WORKERS}" =~ ^[0-9]+$ ]] || (( WORKERS <= 0 )); then
  echo "Invalid --workers value: ${WORKERS}" >&2
  exit 1
fi
if ! [[ "${SEQ_LEN}" =~ ^[0-9]+$ ]] || (( SEQ_LEN <= 0 )); then
  echo "Invalid --seq-len value: ${SEQ_LEN}" >&2
  exit 1
fi
if ! [[ "${TEST_LIMIT}" =~ ^[0-9]+$ ]] || (( TEST_LIMIT <= 0 )); then
  echo "Invalid --test-limit value: ${TEST_LIMIT}" >&2
  exit 1
fi
if ! [[ "${SMOKE_TEST_LIMIT}" =~ ^[0-9]+$ ]] || (( SMOKE_TEST_LIMIT <= 0 )); then
  echo "Invalid --smoke-test-limit value: ${SMOKE_TEST_LIMIT}" >&2
  exit 1
fi

if [[ -z "${OUT_ROOT}" ]]; then
  RUN_TS="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  OUT_ROOT="${PROJ_DIR}/out/cheatcodes_suite_${RUN_TS}"
fi

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_WHITE=$'\033[97m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_BLUE=''
  C_CYAN=''
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_WHITE=''
fi

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

LAST_EXIT_CODE=0
LAST_DURATION_MS=0

section() {
  printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"
}

log() {
  printf '%s%s%s\n' "${C_CYAN}[LOG]${C_RESET}" " $1"
}

success() {
  printf '%s%s%s\n' "${C_GREEN}[ OK ]${C_RESET}" " $1"
}

warning() {
  printf '%s%s%s\n' "${C_YELLOW}[WARN]${C_RESET}" " $1"
}

failure() {
  printf '%s%s%s\n' "${C_RED}[FAIL]${C_RESET}" " $1"
}

run_cmd() {
  local label="$1"
  local out_file="$2"
  local err_file="$3"
  local start_ms
  local end_ms

  shift 3
  start_ms="$(now_ms)"
  set +e
  "$@" >"${out_file}" 2>"${err_file}"
  local ec=$?
  set -e
  end_ms="$(now_ms)"
  LAST_EXIT_CODE=$ec
  LAST_DURATION_MS=$((end_ms - start_ms))
  if [[ ${ec} -eq 0 ]]; then
    log "${label} ${C_GREEN}passed${C_RESET} in ${LAST_DURATION_MS}ms"
  else
    failure "${label} failed (exit ${ec}) in ${LAST_DURATION_MS}ms"
  fi
}

mkdir -p "${OUT_ROOT}"
RESULTS_JSONL="${OUT_ROOT}/results.jsonl"
: > "${RESULTS_JSONL}"

DEAL_LOOPS=10
RECORD_LOOPS=200
SLOTS=64
ACCESSES_CALLS=5
SNAPSHOT_LOOPS=20
REVERT_LOOPS=20
READFILE_LOOPS=50
PARSEJSON_LOOPS=200
GETCODE_LOOPS=25
BENCH_CASES_BASE=(
    "deal_erc20 DealErc20Bench"
    "record RecordBench"
    "accesses AccessesBench"
    "snapshot SnapshotBench"
    "revert_to RevertToBench"
)
BENCH_CASES_FFI=(
    "read_file ReadFileBench"
    "parse_json ParseJsonBytesBench"
    "get_code GetCodeBench"
)

FFI_ENV_ROOT="${ECHIDNA_FS_ROOT:-${PROJ_DIR}}"
FFI_ARTIFACTS_ROOT="${ECHIDNA_ARTIFACTS_ROOT:-${PROJ_DIR}}"
FFI_ENV=(env "ECHIDNA_FS_ROOT=${FFI_ENV_ROOT}" "ECHIDNA_ARTIFACTS_ROOT=${FFI_ARTIFACTS_ROOT}")

echo "${C_BOLD}Cheatcode validation + benchmark suite${C_RESET}"
echo "${C_DIM}Generated ${C_RESET}${OUT_ROOT}"
printf '%s\n' "Binary : ${ECHIDNA_BIN}"
printf '%s\n' "Repeats: ${REPEATS}"
printf '%s\n' "Workers: ${WORKERS}"
printf '%s\n' "Seq-len: ${SEQ_LEN}"
printf '%s\n' "Bench test-limit: ${TEST_LIMIT}"
printf '%s\n' "Smoke test-limit: ${SMOKE_TEST_LIMIT}"

section "1) Smoke checks: ensuring all cheatcodes behave correctly"
SMOKE_OUT_DIR="${OUT_ROOT}/smoke"
mkdir -p "${SMOKE_OUT_DIR}"
SMOKE_OUT="${SMOKE_OUT_DIR}/cheatcodes_smoke.out"
SMOKE_ERR="${SMOKE_OUT_DIR}/cheatcodes_smoke.err"

run_cmd \
  "Smoke: ${SMOKE_TARGET} :: ${SMOKE_CONTRACT}" \
  "${SMOKE_OUT}" \
  "${SMOKE_ERR}" \
  "${FFI_ENV[@]}" \
  "${ECHIDNA_BIN}" \
  "${SMOKE_TARGET_PATH}" \
  --contract "${SMOKE_CONTRACT}" \
  --test-mode property \
  --workers "${WORKERS}" \
  --seq-len "${SEQ_LEN}" \
  --test-limit "${SMOKE_TEST_LIMIT}" \
  --shrink-limit 0 \
  --format text \
  --disable-slither \
  --config "${BENCH_CONFIG_FFI_PATH}" \
  --corpus-dir "${OUT_ROOT}/smoke/corpus" \
  --coverage-dir "${OUT_ROOT}/smoke/coverage"

if [[ "${LAST_EXIT_CODE}" -ne 0 ]]; then
  failure "Smoke tests failed. See:"
  failure "  stdout: ${SMOKE_OUT}"
  failure "  stderr: ${SMOKE_ERR}"
  exit 1
fi

python3 - <<PY >> "${RESULTS_JSONL}"
import json, time
row = {
  "ts_ms": int(time.time() * 1000),
  "bench": "smoke",
  "contract": "${SMOKE_CONTRACT}",
  "repeat": 1,
  "test_limit": ${SMOKE_TEST_LIMIT},
  "seq_len": ${SEQ_LEN},
  "workers": ${WORKERS},
  "seed": 1000,
  "exit_code": int(${LAST_EXIT_CODE}),
  "duration_ms": int(${LAST_DURATION_MS}),
  "out_file": "${SMOKE_OUT}",
  "err_file": "${SMOKE_ERR}",
  "corpus_dir": "${OUT_ROOT}/smoke/corpus",
  "coverage_dir": "${OUT_ROOT}/smoke/coverage",
}
print(json.dumps(row))
PY
success "Cheatcode smoke checks passed."

section "2) Microbenchmarks: deal, snapshot/revertTo, record, accesses, readFile, parseJsonBytes, getCode"

for bench_repeat in $(seq 1 "${REPEATS}"); do
  for bench_case in "${BENCH_CASES_BASE[@]}"; do
    IFS=' ' read -r bench_name bench_contract <<< "${bench_case}"
    benchmark_dir="${OUT_ROOT}/bench/${bench_name}/repeat_${bench_repeat}"
    mkdir -p "${benchmark_dir}"

    out_file="${benchmark_dir}/out.json"
    err_file="${benchmark_dir}/err.log"
    log "Running ${bench_name} / ${bench_contract} (repeat ${bench_repeat}/${REPEATS})"

  run_cmd \
      "Benchmark ${bench_name} (${bench_contract}) #${bench_repeat}" \
      "${out_file}" \
      "${err_file}" \
      "${ECHIDNA_BIN}" \
      "${BENCH_TARGET_PATH}" \
      --contract "${bench_contract}" \
      --config "${BENCH_CONFIG_PATH}" \
      --workers "${WORKERS}" \
      --seq-len "${SEQ_LEN}" \
      --test-limit "${TEST_LIMIT}" \
      --seed "$((10000 + bench_repeat))" \
      --corpus-dir "${benchmark_dir}/corpus" \
      --coverage-dir "${benchmark_dir}/coverage"

    python3 - <<PY >> "${RESULTS_JSONL}"
import json, time

LOOPS = {
    "deal_erc20": ${DEAL_LOOPS},
    "record": ${RECORD_LOOPS},
    "accesses": ${ACCESSES_CALLS},
    "snapshot": ${SNAPSHOT_LOOPS},
    "revert_to": ${REVERT_LOOPS},
}

row = {
    "ts_ms": int(time.time() * 1000),
    "bench": "${bench_name}",
    "contract": "${bench_contract}",
    "repeat": int(${bench_repeat}),
    "test_limit": ${TEST_LIMIT},
    "seq_len": ${SEQ_LEN},
    "workers": ${WORKERS},
    "seed": int(10000 + ${bench_repeat}),
    "exit_code": int(${LAST_EXIT_CODE}),
    "duration_ms": int(${LAST_DURATION_MS}),
    "out_file": "${out_file}",
    "err_file": "${err_file}",
    "corpus_dir": "${benchmark_dir}/corpus",
    "coverage_dir": "${benchmark_dir}/coverage",
}

if row["bench"] in LOOPS:
    row["loops_per_property"] = LOOPS[row["bench"]]
    row["ops_total"] = LOOPS[row["bench"]] * (row["test_limit"] * row["seq_len"])

if row["bench"] == "accesses":
    row["slots_touched_per_property"] = ${SLOTS}
    row["accesses_calls_per_property"] = ${ACCESSES_CALLS}

print(json.dumps(row))
PY
  done

  for bench_case in "${BENCH_CASES_FFI[@]}"; do
    IFS=' ' read -r bench_name bench_contract <<< "${bench_case}"
    benchmark_dir="${OUT_ROOT}/bench/${bench_name}/repeat_${bench_repeat}"
    mkdir -p "${benchmark_dir}"

    out_file="${benchmark_dir}/out.json"
    err_file="${benchmark_dir}/err.log"
    log "Running ${bench_name} / ${bench_contract} (repeat ${bench_repeat}/${REPEATS})"

    run_cmd \
      "Benchmark ${bench_name} (${bench_contract}) #${bench_repeat}" \
      "${out_file}" \
      "${err_file}" \
      "${FFI_ENV[@]}" \
      "${ECHIDNA_BIN}" \
      "${BENCH_TARGET_PATH}" \
      --contract "${bench_contract}" \
      --config "${BENCH_CONFIG_FFI_PATH}" \
      --workers "${WORKERS}" \
      --seq-len "${SEQ_LEN}" \
      --test-limit "${TEST_LIMIT}" \
      --seed "$((10000 + bench_repeat))" \
      --corpus-dir "${benchmark_dir}/corpus" \
      --coverage-dir "${benchmark_dir}/coverage"

    python3 - <<PY >> "${RESULTS_JSONL}"
import json, time

LOOPS = {
    "read_file": ${READFILE_LOOPS},
    "parse_json": ${PARSEJSON_LOOPS},
    "get_code": ${GETCODE_LOOPS},
}

row = {
  "ts_ms": int(time.time() * 1000),
  "bench": "${bench_name}",
  "contract": "${bench_contract}",
  "repeat": int(${bench_repeat}),
  "test_limit": ${TEST_LIMIT},
  "seq_len": ${SEQ_LEN},
  "workers": ${WORKERS},
  "seed": int(10000 + ${bench_repeat}),
  "exit_code": int(${LAST_EXIT_CODE}),
  "duration_ms": int(${LAST_DURATION_MS}),
  "out_file": "${out_file}",
  "err_file": "${err_file}",
  "corpus_dir": "${benchmark_dir}/corpus",
  "coverage_dir": "${benchmark_dir}/coverage",
}

if row["bench"] in LOOPS:
    row["loops_per_property"] = LOOPS[row["bench"]]
    row["ops_total"] = LOOPS[row["bench"]] * (row["test_limit"] * row["seq_len"])

print(json.dumps(row))
PY
  done
done

section "3) Summary"
SUMMARY_JSON="${OUT_ROOT}/summary.json"
python3 - <<PY
import json
import statistics
from pathlib import Path

rows = [
    json.loads(line)
    for line in Path("${RESULTS_JSONL}").read_text().splitlines()
    if line.strip()
]

def median(values):
    return int(statistics.median(values)) if values else None

def bench_rows(bench):
    return [r for r in rows if r["bench"] == bench]

def summarize(bench):
    br = bench_rows(bench)
    durs = [r["duration_ms"] for r in br if isinstance(r.get("duration_ms"), int)]
    entry = {
        "n": len(br),
        "min_ms": min(durs) if durs else None,
        "median_ms": median(durs),
        "mean_ms": int(statistics.mean(durs)) if durs else None,
        "max_ms": max(durs) if durs else None,
        "any_failures": any(r.get("exit_code", 0) not in (0, None) for r in br),
    }
    if bench == "smoke":
      entry["status"] = "pass" if not entry["any_failures"] else "fail"
    else:
      ops = [r.get("ops_total") for r in br if isinstance(r.get("ops_total"), int)]
      if ops:
        med_ops = ops[0]
        med_ms = entry["median_ms"]
        entry["ops_total_per_run"] = med_ops
        entry["ops_per_sec_median"] = (med_ops * 1000 / med_ms) if med_ms else None
    return entry

summary = {
    "echidna_bin": "${ECHIDNA_BIN}",
    "repeats": ${REPEATS},
    "workers": ${WORKERS},
    "seq_len": ${SEQ_LEN},
    "bench_test_limit": ${TEST_LIMIT},
    "smoke_test_limit": ${SMOKE_TEST_LIMIT},
  "benches": {
      "smoke": summarize("smoke"),
      "deal_erc20": summarize("deal_erc20"),
      "record": summarize("record"),
      "accesses": summarize("accesses"),
      "snapshot": summarize("snapshot"),
      "revert_to": summarize("revert_to"),
      "read_file": summarize("read_file"),
      "parse_json": summarize("parse_json"),
      "get_code": summarize("get_code"),
    },
}

summary["overall_success"] = (
    not summary["benches"]["smoke"]["any_failures"]
    and not summary["benches"]["deal_erc20"]["any_failures"]
    and not summary["benches"]["record"]["any_failures"]
    and not summary["benches"]["accesses"]["any_failures"]
    and not summary["benches"]["snapshot"]["any_failures"]
    and not summary["benches"]["revert_to"]["any_failures"]
    and not summary["benches"]["read_file"]["any_failures"]
    and not summary["benches"]["parse_json"]["any_failures"]
    and not summary["benches"]["get_code"]["any_failures"]
)

Path("${SUMMARY_JSON}").write_text(json.dumps(summary, indent=2) + "\\n")
print(json.dumps(summary, indent=2))
PY

OVERALL_SUCCESS=0
if [[ -f "${SUMMARY_JSON}" ]]; then
  OVERALL_SUCCESS="$(python3 - "${SUMMARY_JSON}" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(1 if summary.get("overall_success") else 0)
PY
)"
fi

if [[ "${OVERALL_SUCCESS}" == "1" ]]; then
  success "All cheatcode smoke + benchmark runs completed successfully."
  printf '%s\n' "Summary written to: ${SUMMARY_JSON}"
  exit 0
else
  failure "One or more runs failed. Review:"
  failure "${SUMMARY_JSON}"
  exit 1
fi
