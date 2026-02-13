#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${PROJ_DIR}/.." && pwd)"

ECHIDNA_BIN="${REPO_DIR}/result/bin/echidna"

TARGET_FILE="${TARGET_FILE:-contracts/bench/CheatcodesBench.sol}"
CONFIG_FILE="${CONFIG_FILE:-echidna/bench.cheatcodes.yaml}"

REPEATS="${REPEATS:-5}"
TEST_LIMIT="${TEST_LIMIT:-500}"
SEQ_LEN="${SEQ_LEN:-1}"
WORKERS="${WORKERS:-1}"

RUN_ID="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

OUT_ROOT="${OUT_ROOT:-${PROJ_DIR}/out/bench_cheatcodes_${RUN_ID}}"

if [[ ! -x "${ECHIDNA_BIN}" ]]; then
  echo "Missing executable: ${ECHIDNA_BIN}" >&2
  exit 1
fi

cd "${PROJ_DIR}"

if [[ ! -f "${TARGET_FILE}" ]]; then
  echo "Missing target file: ${PROJ_DIR}/${TARGET_FILE}" >&2
  exit 1
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing config file: ${PROJ_DIR}/${CONFIG_FILE}" >&2
  exit 1
fi

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

mkdir -p "${OUT_ROOT}"
RESULTS="${OUT_ROOT}/results.jsonl"

# Keep these in sync with contracts/bench/CheatcodesBench.sol
DEAL_LOOPS=10
RECORD_LOOPS=200
SLOTS=64
ACCESSES_CALLS=5

echo "Cheatcodes benchmark"
echo "Target file: ${TARGET_FILE}"
echo "Config: ${CONFIG_FILE}"
echo "Repeats: ${REPEATS}"
echo "Params: testLimit=${TEST_LIMIT} seqLen=${SEQ_LEN} workers=${WORKERS}"
echo "Output: ${OUT_ROOT}"
echo "Writing: ${RESULTS}"

run_one() {
  local bench="$1"
  local contract="$2"
  local repeat="$3"
  local seed="$4"
  local run_dir="$5"

  local out_json="${run_dir}/out.json"
  local err_log="${run_dir}/err.log"
  local corpus_dir="${run_dir}/corpus"
  local coverage_dir="${run_dir}/coverage"

  mkdir -p "${run_dir}"

  local start_ms end_ms dur_ms ec
  start_ms="$(now_ms)"

  set +e
  "${ECHIDNA_BIN}" \
    "${TARGET_FILE}" \
    --contract "${contract}" \
    --config "${CONFIG_FILE}" \
    --workers "${WORKERS}" \
    --seq-len "${SEQ_LEN}" \
    --test-limit "${TEST_LIMIT}" \
    --seed "${seed}" \
    --corpus-dir "${corpus_dir}" \
    --coverage-dir "${coverage_dir}" \
    >"${out_json}" 2>"${err_log}"
  ec="$?"
  set -e

  end_ms="$(now_ms)"
  dur_ms=$((end_ms - start_ms))

  python3 - <<PY >>"${RESULTS}"
import json, time

bench = "${bench}"
repeat = int("${repeat}")
test_limit = int("${TEST_LIMIT}")
seq_len = int("${SEQ_LEN}")
prop_calls = test_limit * seq_len

row = {
  "ts_ms": int(time.time() * 1000),
  "repeat": repeat,
  "bench": bench,
  "contract": "${contract}",
  "test_limit": test_limit,
  "seq_len": seq_len,
  "workers": int("${WORKERS}"),
  "seed": int("${seed}"),
  "exit_code": int("${ec}"),
  "duration_ms": int("${dur_ms}"),
  "out_json": "${out_json}",
  "err_log": "${err_log}",
  "corpus_dir": "${corpus_dir}",
  "coverage_dir": "${coverage_dir}",
}

if bench == "deal_erc20":
  loops = int("${DEAL_LOOPS}")
  row["ops_per_property"] = loops
  row["ops_total"] = loops * prop_calls
elif bench == "record":
  loops = int("${RECORD_LOOPS}")
  row["ops_per_property"] = loops
  row["ops_total"] = loops * prop_calls
elif bench == "accesses":
  slots = int("${SLOTS}")
  calls = int("${ACCESSES_CALLS}")
  row["slots_touched_per_property"] = slots
  row["accesses_calls_per_property"] = calls
  row["accesses_calls_total"] = calls * prop_calls

print(json.dumps(row))
PY
}

for r in $(seq 1 "${REPEATS}"); do
  base_dir="${OUT_ROOT}/run_${r}_$(now_ms)"
  run_one "deal_erc20" "DealErc20Bench" "${r}" "$((10000 + r))" "${base_dir}/deal_erc20"
  run_one "record" "RecordBench" "${r}" "$((20000 + r))" "${base_dir}/record"
  run_one "accesses" "AccessesBench" "${r}" "$((30000 + r))" "${base_dir}/accesses"
done

python3 - <<PY
import json
import statistics
from pathlib import Path

out_root = Path("${OUT_ROOT}")
rows = [json.loads(l) for l in (out_root / "results.jsonl").read_text().splitlines() if l.strip()]

def median(xs):
  return int(statistics.median(xs)) if xs else None

summary = {
  "repeats": int("${REPEATS}"),
  "test_limit": int("${TEST_LIMIT}"),
  "seq_len": int("${SEQ_LEN}"),
  "workers": int("${WORKERS}"),
  "benches": {},
}

for bench in ("deal_erc20", "record", "accesses"):
  br = [r for r in rows if r.get("bench") == bench]
  durs = [r["duration_ms"] for r in br if isinstance(r.get("duration_ms"), int)]
  entry = {
    "n": len(durs),
    "min_ms": min(durs) if durs else None,
    "median_ms": median(durs),
    "mean_ms": int(statistics.mean(durs)) if durs else None,
    "max_ms": max(durs) if durs else None,
    "any_failures": any(r.get("exit_code") not in (0, None) for r in br),
  }

  ops = [r.get("ops_total") for r in br if isinstance(r.get("ops_total"), int)]
  if ops and durs:
    ops_total = ops[0]
    med_ms = median(durs)
    entry["ops_total_per_run"] = ops_total
    entry["ops_per_sec_median"] = (ops_total * 1000.0 / med_ms) if med_ms else None

  acc_calls = [r.get("accesses_calls_total") for r in br if isinstance(r.get("accesses_calls_total"), int)]
  if acc_calls and durs:
    calls_total = acc_calls[0]
    med_ms = median(durs)
    entry["accesses_calls_total_per_run"] = calls_total
    entry["accesses_calls_per_sec_median"] = (calls_total * 1000.0 / med_ms) if med_ms else None

  summary["benches"][bench] = entry

(out_root / "summary.json").write_text(json.dumps(summary, indent=2) + "\\n")
print("Wrote:", out_root / "summary.json")
print(json.dumps(summary, indent=2))
PY

echo "Done."

