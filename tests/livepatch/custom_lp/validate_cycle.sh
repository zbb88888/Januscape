#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$ROOT_DIR/artifacts"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ARTIFACT_ROOT/validate-$STAMP"

mkdir -p "$RUN_DIR"

cleanup() {
  "$ROOT_DIR/disable_and_unload.sh" >"$RUN_DIR/final_cleanup.txt" 2>&1 || true
}
trap cleanup EXIT

cd "$ROOT_DIR"

uname -a >"$RUN_DIR/uname.txt"
{
  echo "run_dir=$RUN_DIR"
  echo "started_at_utc=$STAMP"
  echo "kernel_release=$(uname -r)"
} >"$RUN_DIR/summary.txt"

make >"$RUN_DIR/build.log" 2>&1
sha256sum ./januscape_lp.ko >"$RUN_DIR/januscape_lp.ko.sha256"

./disable_and_unload.sh >"$RUN_DIR/pre_cleanup.txt" 2>&1 || true

./load_dry_run.sh >"$RUN_DIR/dry_run.log" 2>&1
./disable_and_unload.sh >"$RUN_DIR/dry_run_cleanup.log" 2>&1

./attempt_enable_interim.sh >"$RUN_DIR/enable_interim.log" 2>&1
./disable_and_unload.sh >"$RUN_DIR/enable_cleanup.log" 2>&1

sudo dmesg | grep -E "januscape_lp|livepatch:" | tail -n 200 >"$RUN_DIR/kernel_excerpt.log" || true

{
  echo "build=pass"
  echo "dry_run_cycle=pass"
  echo "enable_interim_cycle=pass"
  echo "final_state=$(head -n 1 "$RUN_DIR/enable_cleanup.log")"
  echo "livepatch_state=$(tail -n 1 "$RUN_DIR/enable_cleanup.log")"
} >>"$RUN_DIR/summary.txt"

cat "$RUN_DIR/summary.txt"
