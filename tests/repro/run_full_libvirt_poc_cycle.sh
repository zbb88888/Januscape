#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
  set -x
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

# Tunables
vm_vcpus="${L1_VCPUS:-16}"
vm_mem_mb="${L1_MEMORY_MB:-8192}"
disk_size_gb="${L1_DISK_SIZE_GB:-100}"
set_panic_policy="${SET_PANIC_POLICY:-1}"
panic_on_warn="${PANIC_ON_WARN:-1}"
panic_on_oops="${PANIC_ON_OOPS:-1}"
panic_delay="${PANIC_DELAY_SEC:-5}"

# Trigger defaults (safer than nflood=1, less likely to die in userspace first)
poc_insmod_args="${POC_INSMOD_ARGS:-nvcpu=8 nflood=0 dwell=256 run_ms=0}"

if [[ "$set_panic_policy" == "1" ]]; then
  sudo sysctl -w "kernel.panic_on_warn=$panic_on_warn"
  sudo sysctl -w "kernel.panic_on_oops=$panic_on_oops"
  sudo sysctl -w "kernel.panic=$panic_delay"
fi

sudo sysctl kernel.panic_on_warn kernel.panic_on_oops kernel.panic

cd "$repo_root"

TRACE="${TRACE:-0}" ./tests/repro/create_seed_iso.sh

./tests/repro/stop_l1_guest_libvirt.sh || true
REMOVE_OVERLAY=1 ./tests/repro/stop_l1_guest_libvirt.sh || true
L1_VCPUS="$vm_vcpus" L1_MEMORY_MB="$vm_mem_mb" L1_DISK_SIZE_GB="$disk_size_gb" TRACE="${TRACE:-0}" ./tests/repro/start_l1_guest_libvirt.sh

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
