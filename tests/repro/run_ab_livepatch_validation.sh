#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

rounds="${AB_ROUNDS:-3}"
scenarios="${AB_SCENARIOS:-unpatched patched}"
trigger_timeout_sec="${AB_TRIGGER_TIMEOUT_SEC:-2700}"

vm_vcpus="${L1_VCPUS:-16}"
vm_mem_mb="${L1_MEMORY_MB:-8192}"
disk_size_gb="${L1_DISK_SIZE_GB:-100}"

set_panic_policy="${SET_PANIC_POLICY:-1}"
panic_on_warn="${PANIC_ON_WARN:-1}"
panic_on_oops="${PANIC_ON_OOPS:-1}"
panic_delay="${PANIC_DELAY_SEC:-5}"

poc_insmod_args="${POC_INSMOD_ARGS:-nvcpu=8 nflood=0 dwell=256 run_ms=0}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_root="$repo_root/tests/artifacts/ab-livepatch-$ts"
mkdir -p "$out_root/runs"

summary_csv="$out_root/summary.csv"
summary_md="$out_root/summary.md"

echo "scenario,round,run_start_utc,run_exit,vm_state,kvm_segfault_count_recent,kvm_warn_count_recent,livepatch_enabled,livepatch_transition,livepatch_kvm_patched,lp_calls,lp_eexist,lp_fallback,crash_dir,recent_kernel_file" >"$summary_csv"

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

ensure_panic_policy() {
  if [[ "$set_panic_policy" == "1" ]]; then
    sudo sysctl -w "kernel.panic_on_warn=$panic_on_warn" >/dev/null
    sudo sysctl -w "kernel.panic_on_oops=$panic_on_oops" >/dev/null
    sudo sysctl -w "kernel.panic=$panic_delay" >/dev/null
  fi
}

latest_crash_dir() {
  ls -1dt "$repo_root"/tests/artifacts/crash-logs-* 2>/dev/null | head -n1 || true
}

parse_livepatch_state() {
  local enabled="na"
  local transition="na"
  local patched="na"

  if [[ -d /sys/kernel/livepatch/januscape_lp ]]; then
    enabled="$(cat /sys/kernel/livepatch/januscape_lp/enabled 2>/dev/null || echo na)"
    transition="$(cat /sys/kernel/livepatch/januscape_lp/transition 2>/dev/null || echo na)"
    patched="$(cat /sys/kernel/livepatch/januscape_lp/kvm/patched 2>/dev/null || echo na)"
  fi

  printf '%s,%s,%s' "$enabled" "$transition" "$patched"
}

latest_lp_counter_triplet() {
  local line
  line="$(dmesg | grep -E 'counter\[module-exit\]:' | tail -n1 || true)"

  if [[ -z "$line" ]]; then
    printf 'na,na,na'
    return 0
  fi

  local calls eexist fallback
  calls="$(echo "$line" | sed -nE 's/.*calls=([0-9]+).*/\1/p')"
  eexist="$(echo "$line" | sed -nE 's/.*eexist=([0-9]+).*/\1/p')"
  fallback="$(echo "$line" | sed -nE 's/.*fallback=([0-9]+).*/\1/p')"

  calls="${calls:-na}"
  eexist="${eexist:-na}"
  fallback="${fallback:-na}"

  printf '%s,%s,%s' "$calls" "$eexist" "$fallback"
}

wait_livepatch_transition_clear() {
  local timeout_sec="${1:-20}"
  local elapsed=0

  while [[ -d /sys/kernel/livepatch/januscape_lp ]]; do
    local transition
    transition="$(cat /sys/kernel/livepatch/januscape_lp/transition 2>/dev/null || echo 0)"
    if [[ "$transition" == "0" ]]; then
      return 0
    fi
    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

enter_unpatched_state() {
  log "Switching to unpatched state"
  "$repo_root/tests/livepatch/custom_lp/disable_and_unload.sh" >/dev/null
}

enter_patched_state() {
  log "Building and enabling livepatch"
  "$repo_root/tests/livepatch/custom_lp/disable_and_unload.sh" >/dev/null
  (cd "$repo_root/tests/livepatch/custom_lp" && make >/dev/null)
  "$repo_root/tests/livepatch/custom_lp/attempt_enable_interim.sh" >/dev/null

  if ! wait_livepatch_transition_clear 30; then
    echo "livepatch transition did not clear within timeout"
    return 1
  fi

  if [[ ! -d /sys/kernel/livepatch/januscape_lp ]]; then
    echo "livepatch januscape_lp missing after enable"
    return 1
  fi

  local enabled transition patched
  enabled="$(cat /sys/kernel/livepatch/januscape_lp/enabled 2>/dev/null || echo 0)"
  transition="$(cat /sys/kernel/livepatch/januscape_lp/transition 2>/dev/null || echo 1)"
  patched="$(cat /sys/kernel/livepatch/januscape_lp/kvm/patched 2>/dev/null || echo 0)"

  if [[ "$enabled" != "1" || "$transition" != "0" || "$patched" != "1" ]]; then
    echo "livepatch not fully active: enabled=$enabled transition=$transition kvm_patched=$patched"
    return 1
  fi
}

prepare_guest_cycle() {
  (cd "$repo_root" && TRACE="${TRACE:-0}" ./tests/repro/create_seed_iso.sh >/dev/null)
  (cd "$repo_root" && ./tests/repro/stop_l1_guest_libvirt.sh >/dev/null 2>&1 || true)
  (cd "$repo_root" && REMOVE_OVERLAY=1 ./tests/repro/stop_l1_guest_libvirt.sh >/dev/null 2>&1 || true)
  (cd "$repo_root" && L1_VCPUS="$vm_vcpus" L1_MEMORY_MB="$vm_mem_mb" L1_DISK_SIZE_GB="$disk_size_gb" TRACE="${TRACE:-0}" ./tests/repro/start_l1_guest_libvirt.sh >/dev/null)
}

run_one_case() {
  local scenario="$1"
  local round="$2"
  local run_dir="$out_root/runs/${scenario}-round${round}"
  local run_start_utc
  local run_rc=0
  local vm_state="unknown"
  local crash_dir=""
  local recent_kernel="$run_dir/recent_kernel.txt"
  local segfault_count=0
  local warn_count=0
  local lp_state lp_enabled lp_transition lp_kvm_patched
  local lp_counter_state lp_calls lp_eexist lp_fallback

  mkdir -p "$run_dir"
  run_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log "Running scenario=$scenario round=$round"

  case "$scenario" in
    unpatched)
      enter_unpatched_state | tee "$run_dir/patch_state.log"
      ;;
    patched)
      enter_patched_state | tee "$run_dir/patch_state.log"
      ;;
    *)
      echo "unsupported scenario: $scenario" | tee "$run_dir/error.log"
      return 1
      ;;
  esac

  ensure_panic_policy
  prepare_guest_cycle

  set +e
  (cd "$repo_root" && POC_INSMOD_ARGS="$poc_insmod_args" TRACE="${TRACE:-0}" timeout --foreground "${trigger_timeout_sec}s" ./tests/repro/run_poc_libvirt_idempotent.sh) >"$run_dir/trigger.log" 2>&1
  run_rc=$?
  set -e

  (cd "$repo_root" && ./tests/repro/collect_crash_logs.sh >"$run_dir/collect.log" 2>&1)
  crash_dir="$(latest_crash_dir)"

  sudo virsh domstate januscape-l1-libvirt >"$run_dir/vm_state.txt" 2>&1 || true
  vm_state="$(head -n1 "$run_dir/vm_state.txt" | tr -d '\r')"

  sudo journalctl -k --since "$run_start_utc" --no-pager | egrep -i 'pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation|CPU [0-9]+/KVM\[|segfault|livepatch:' >"$recent_kernel" || true

  segfault_count="$(grep -Eic 'CPU [0-9]+/KVM\[.*segfault' "$recent_kernel" || true)"
  warn_count="$(grep -Eic 'pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation' "$recent_kernel" || true)"

  lp_state="$(parse_livepatch_state)"
  IFS=',' read -r lp_enabled lp_transition lp_kvm_patched <<< "$lp_state"

  lp_calls="na"
  lp_eexist="na"
  lp_fallback="na"

  # For patched runs, unload once to force module-exit counter emission.
  if [[ "$scenario" == "patched" ]]; then
    "$repo_root/tests/livepatch/custom_lp/disable_and_unload.sh" >"$run_dir/post_run_unload.log" 2>&1 || true
    lp_counter_state="$(latest_lp_counter_triplet)"
    IFS=',' read -r lp_calls lp_eexist lp_fallback <<< "$lp_counter_state"
    echo "$lp_counter_state" >"$run_dir/lp_counters.txt"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$scenario" "$round" "$run_start_utc" "$run_rc" "$vm_state" "$segfault_count" "$warn_count" \
    "$lp_enabled" "$lp_transition" "$lp_kvm_patched" "$lp_calls" "$lp_eexist" "$lp_fallback" \
    "$crash_dir" "$recent_kernel" >>"$summary_csv"
}

log "A/B run root: $out_root"
log "Scenarios: $scenarios"
log "Rounds per scenario: $rounds"

for scenario in $scenarios; do
  for round in $(seq 1 "$rounds"); do
    run_one_case "$scenario" "$round"
  done
done

{
  echo "# A/B Livepatch Validation"
  echo
  echo "- generated_utc: $ts"
  echo "- rounds_per_scenario: $rounds"
  echo "- scenarios: $scenarios"
  echo "- trigger_timeout_sec: $trigger_timeout_sec"
  echo "- poc_insmod_args: $poc_insmod_args"
  echo
  echo "## Raw CSV"
  echo
  echo "$(basename "$summary_csv")"
  echo
  echo "## Results"
  echo
  awk -F, 'NR==1{next} {printf("- scenario=%s round=%s run_exit=%s vm_state=%s segfault_recent=%s warn_recent=%s livepatch(enabled=%s transition=%s kvm_patched=%s calls=%s eexist=%s fallback=%s)\n  crash_dir=%s\n  recent_kernel=%s\n", $1,$2,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)}' "$summary_csv"
} >"$summary_md"

log "A/B validation complete"
log "Summary CSV: $summary_csv"
log "Summary MD:  $summary_md"
