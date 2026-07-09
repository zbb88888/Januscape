#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
  set -x
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

# Only trigger against currently running VM, no recreate.
vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
poc_insmod_args="${POC_INSMOD_ARGS:-nvcpu=8 nflood=0 dwell=256 run_ms=0}"

if ! sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
  echo "Domain not found: $vm_name"
  exit 1
fi

state="$(sudo virsh domstate "$vm_name" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ "$state" != "running" ]]; then
  echo "Domain is not running: $vm_name (state=$state)"
  exit 1
fi

cd "$repo_root"

set +e
POC_INSMOD_ARGS="$poc_insmod_args" TRACE="${TRACE:-0}" ./tests/repro/run_poc_libvirt_idempotent.sh
trigger_rc=$?
set -e

./tests/repro/collect_crash_logs.sh || true

latest_dir="$(ls -1dt "$repo_root"/tests/artifacts/crash-logs-* 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_dir" ]]; then
  echo "latest_crash_logs=$latest_dir"
  echo "summary_file=$latest_dir/summary.txt"
fi

exit "$trigger_rc"
