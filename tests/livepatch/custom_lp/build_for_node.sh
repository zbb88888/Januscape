#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$ROOT_DIR/artifacts"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ARTIFACT_ROOT/node-build-$STAMP"
KREL="$(uname -r)"
KDIR="/lib/modules/$KREL/build"
WITH_VALIDATE=0
ALLOW_NON_UBUNTU=0

usage() {
  cat <<'EOF'
Usage:
  ./tests/livepatch/custom_lp/build_for_node.sh [options]

Options:
  --with-validate      Run validate_cycle.sh after build (requires sudo path)
  --allow-non-ubuntu   Skip strict Ubuntu ID/version checks
  -h, --help           Show this help

What this does:
  1. Checks node OS/kernel prerequisites
  2. Builds januscape_lp.ko for current kernel
  3. Exports per-node artifact bundle (ko, hashes, metadata)
  4. Optionally runs full load/enable/rollback validation cycle
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-validate)
      WITH_VALIDATE=1
      shift
      ;;
    --allow-non-ubuntu)
      ALLOW_NON_UBUNTU=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$RUN_DIR"
cd "$ROOT_DIR"

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
else
  echo "Missing /etc/os-release" >&2
  exit 1
fi

if [[ "${ID:-}" != "ubuntu" && $ALLOW_NON_UBUNTU -eq 0 ]]; then
  echo "This workflow is currently targeted for Ubuntu 22/24 nodes (ID=ubuntu)." >&2
  echo "Use --allow-non-ubuntu to bypass this guard intentionally." >&2
  exit 1
fi

if [[ $ALLOW_NON_UBUNTU -eq 0 ]]; then
  case "${VERSION_ID:-}" in
    22.04|24.04)
      ;;
    *)
      echo "Unsupported Ubuntu VERSION_ID=${VERSION_ID:-unknown}; expected 22.04 or 24.04." >&2
      echo "Use --allow-non-ubuntu to bypass this guard intentionally." >&2
      exit 1
      ;;
  esac
fi

if [[ ! -d "$KDIR" ]]; then
  echo "Kernel build headers directory not found: $KDIR" >&2
  exit 1
fi

if [[ ! -f "$KDIR/include/linux/livepatch.h" ]]; then
  echo "Missing livepatch header: $KDIR/include/linux/livepatch.h" >&2
  exit 1
fi

{
  echo "run_dir=$RUN_DIR"
  echo "started_at_utc=$STAMP"
  echo "node_os=${PRETTY_NAME:-unknown}"
  echo "kernel_release=$KREL"
  echo "kernel_build_dir=$KDIR"
  echo "with_validate=$WITH_VALIDATE"
} >"$RUN_DIR/summary.txt"

cp -f "$ROOT_DIR/januscape_lp.c" "$RUN_DIR/januscape_lp.c.snapshot"

make >"$RUN_DIR/build.log" 2>&1

KO_SRC="$ROOT_DIR/januscape_lp.ko"
KO_DST="$RUN_DIR/januscape_lp-${KREL}.ko"
cp -f "$KO_SRC" "$KO_DST"

sha256sum "$KO_DST" >"$RUN_DIR/januscape_lp-${KREL}.ko.sha256"
modinfo "$KO_DST" >"$RUN_DIR/modinfo.txt"

{
  echo "build=pass"
  echo "ko_file=$(basename "$KO_DST")"
  echo "vermagic=$(grep -E '^vermagic:' "$RUN_DIR/modinfo.txt" | sed 's/^vermagic:[[:space:]]*//')"
} >>"$RUN_DIR/summary.txt"

if [[ $WITH_VALIDATE -eq 1 ]]; then
  VALIDATE_OUT="$RUN_DIR/validate.log"
  ./validate_cycle.sh >"$VALIDATE_OUT" 2>&1
  VALIDATE_DIR="$(grep -E '^run_dir=' "$VALIDATE_OUT" | tail -n 1 | sed 's/^run_dir=//')"
  {
    echo "validate=pass"
    echo "validate_run_dir=${VALIDATE_DIR:-unknown}"
  } >>"$RUN_DIR/summary.txt"
else
  echo "validate=skipped" >>"$RUN_DIR/summary.txt"
fi

cat "$RUN_DIR/summary.txt"
