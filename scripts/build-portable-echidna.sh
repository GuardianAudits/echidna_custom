#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HEVM_DEFAULT="${HEVM_SRC:-${PROJECT_ROOT}/hevm}"

usage() {
  cat <<'EOF'
Usage: build-portable-echidna.sh [options]

Builds a portable Echidna binary using the flake redistributable output.

Options:
  -o, --output DIR        Output directory for artifacts (default: ./portable-binaries)
  -t, --tag TAG           Tag/version string used in output filename
      --system SYSTEM     Nix system to build (default: auto-detected)
      --hevm-src PATH     Path to hevm checkout (default: HEVM_SRC env or ./hevm)
      --with-hub           Include portable echidna-corpus-hub (redistributable output)
      --skip-check         Skip runtime portability checks
  -v, --verbose           Print executed commands and verbose nix build logs
  -h, --help              Show this help text

Examples:
  ./scripts/build-portable-echidna.sh
  ./scripts/build-portable-echidna.sh --tag "2.3.1" --output ./dist --with-hub
EOF
}

OUTPUT_DIR="${PROJECT_ROOT}/portable-binaries"
TAG=""
SYSTEM=""
HEVM_SRC_PATH="$HEVM_DEFAULT"
WITH_HUB=0
SKIP_CHECK=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -t|--tag)
      TAG="$2"
      shift 2
      ;;
    --system)
      SYSTEM="$2"
      shift 2
      ;;
    --hevm-src)
      HEVM_SRC_PATH="$2"
      shift 2
      ;;
    --with-hub)
      WITH_HUB=1
      shift
      ;;
    --skip-check)
      SKIP_CHECK=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${PROJECT_ROOT}/flake.nix" ]]; then
  echo "Error: script must be run from the echidna repo root (or nearby with this script)." >&2
  exit 1
fi

if [[ -z "$TAG" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    TAG="$(git -C "$PROJECT_ROOT" describe --tags --dirty --abbrev=7 2>/dev/null || true)"
    TAG="${TAG#v}"
    if [[ -z "$TAG" ]]; then
      TAG="dev-$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)"
    fi
  else
    TAG="$(date +%Y%m%d-%H%M%S)"
  fi
fi

if [[ ! -d "$HEVM_SRC_PATH" ]]; then
  echo "Error: HEVM source not found at $HEVM_SRC_PATH" >&2
  echo "Set --hevm-src or HEVM_SRC to a valid directory." >&2
  exit 1
fi

if ! command -v nix >/dev/null 2>&1; then
  echo "Error: nix is required in PATH." >&2
  exit 1
fi

if [[ -z "$SYSTEM" ]]; then
  SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem')"
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  set -x
  PS4='+ [cmd] '
fi

log() {
  echo "[build-portable-echidna] $*"
}

run() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo
    echo "[cmd] $*"
  fi
  env HEVM_SRC="$HEVM_SRC_PATH" "$@"
}

NIX_BUILD_ARGS=()
if [[ "$VERBOSE" -eq 1 ]]; then
  NIX_BUILD_ARGS+=("--print-build-logs")
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

release_name="echidna-portable-${TAG}-${SYSTEM}"
STAGE_DIR="${WORKDIR}/${release_name}"
mkdir -p "$STAGE_DIR" "$OUTPUT_DIR"

build_and_collect() {
  local package_attr="$1"
  local output_var="$2"
  local binary="$3"

  log "Building ${package_attr}..."
  local out_path="${WORKDIR}/.build-${binary}"
  run nix build --impure "${NIX_BUILD_ARGS[@]}" ".#packages.${SYSTEM}.${package_attr}" --out-link "$out_path"

  if [[ ! -x "${out_path}/bin/${binary}" ]]; then
    echo "Error: ${binary} not produced by ${package_attr} output." >&2
    exit 1
  fi

  run cp "${out_path}/bin/${binary}" "${WORKDIR}/${binary}"
  printf -v "${output_var}" '%s' "${WORKDIR}/${binary}"
}

collect_binary() {
  local src="$1"
  local name="$2"
  if [[ ! -x "$src" ]]; then
    echo "Error: cannot stage $name from $src" >&2
    exit 1
  fi
  run cp "$src" "$STAGE_DIR/$name"
  run chmod +x "$STAGE_DIR/$name"
}

check_portability_macos() {
  local binary="$1"
  if [[ $SKIP_CHECK -eq 1 ]]; then
    return 0
  fi
  if ! command -v otool >/dev/null 2>&1; then
    echo "Warning: otool not found; skipping macOS portability check for $(basename "$binary")." >&2
    return 0
  fi
  if otool -L "$binary" | awk '{print $1}' | grep -q "/nix/store"; then
    echo "Error: portability check failed for $(basename "$binary") (still references /nix/store)." >&2
    echo "Hint: build again on a machine where Nix can access these paths, or inspect dependencies manually." >&2
    exit 1
  fi
}

check_portability_linux() {
  local binary="$1"
  if [[ $SKIP_CHECK -eq 1 ]]; then
    return 0
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    echo "Warning: ldd not found; skipping Linux portability check for $(basename "$binary")." >&2
    return 0
  fi
  local ldd_output
  ldd_output="$(ldd "$binary" 2>&1 || true)"
  if echo "$ldd_output" | grep -q "not found"; then
    echo "Error: portability check failed for $(basename "$binary") (missing shared libraries)." >&2
    echo "$ldd_output" >&2
    exit 1
  fi
  if echo "$ldd_output" | grep -q "/nix/store"; then
    echo "Error: portability check failed for $(basename "$binary") (still references /nix/store)." >&2
    echo "$ldd_output" >&2
    exit 1
  fi
}

checksum_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file"
    return
  fi

  echo "Warning: no sha256sum or shasum found; skipping checksum generation."
}

# Redistributable build includes the portable echidna binary only.
REDIST_PATH="${WORKDIR}/redistributable"
run nix build --impure "${NIX_BUILD_ARGS[@]}" ".#packages.${SYSTEM}.echidna-redistributable" --out-link "$REDIST_PATH"

if [[ ! -x "${REDIST_PATH}/bin/echidna" ]]; then
  echo "Error: redistributable echidna binary not found at ${REDIST_PATH}/bin/echidna" >&2
  exit 1
fi

run cp "${REDIST_PATH}/bin/echidna" "$STAGE_DIR/echidna"

if [[ "$WITH_HUB" -eq 1 ]]; then
  HUB_BIN_PATH=""
  build_and_collect "echidna-corpus-hub-redistributable" HUB_BIN_PATH "echidna-corpus-hub"
  collect_binary "$HUB_BIN_PATH" "echidna-corpus-hub"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  check_portability_macos "$STAGE_DIR/echidna"
  if [[ "$WITH_HUB" -eq 1 ]]; then
    check_portability_macos "$STAGE_DIR/echidna-corpus-hub"
  fi
else
  check_portability_linux "$STAGE_DIR/echidna"
  if [[ "$WITH_HUB" -eq 1 ]]; then
    check_portability_linux "$STAGE_DIR/echidna-corpus-hub"
  fi
fi

OUTPUT_ARCHIVE="${OUTPUT_DIR}/${release_name}.tar.gz"
tar -czf "$OUTPUT_ARCHIVE" -C "$STAGE_DIR" .
checksum_file "$OUTPUT_ARCHIVE" > "${OUTPUT_ARCHIVE}.sha256"

echo "Built portable package: ${OUTPUT_ARCHIVE}"
echo "Checksum: ${OUTPUT_ARCHIVE}.sha256"
