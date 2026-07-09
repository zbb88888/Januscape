#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
  set -x
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
vm_user="${VM_USERNAME:-januscape}"
vm_pass="${VM_PASSWORD:-januscape}"

ssh_ready_timeout_sec="${SSH_READY_TIMEOUT_SEC:-300}"
ssh_connect_timeout_sec="${SSH_CONNECT_TIMEOUT_SEC:-5}"
guest_cmd_timeout_sec="${GUEST_CMD_TIMEOUT_SEC:-1800}"
cloud_init_wait_timeout_sec="${CLOUD_INIT_WAIT_TIMEOUT_SEC:-900}"
cloud_init_ready_file="${CLOUD_INIT_READY_FILE:-/var/lib/januscape/cloud-init-ready}"
post_trigger_sleep_sec="${POST_TRIGGER_SLEEP_SEC:-120}"
poc_insmod_args="${POC_INSMOD_ARGS:-nvcpu=8 nflood=0 dwell=256 run_ms=60000}"
min_root_free_kb="${MIN_ROOT_FREE_KB:-262144}"
trace_flag="${TRACE:-0}"
insmod_timeout_sec="${POC_INSMOD_TIMEOUT_SEC:-180}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
artifacts_dir="$repo_root/tests/artifacts"
mkdir -p "$artifacts_dir"
run_log="$artifacts_dir/poc-libvirt-idempotent-$run_id.log"

guest_workdir="/tmp/januscape-poc-$run_id"

if ! command -v virsh >/dev/null 2>&1; then
  echo "Missing command: virsh"
  exit 1
fi
if ! command -v sshpass >/dev/null 2>&1; then
  echo "Missing command: sshpass"
  echo "Install: sudo apt-get install -y sshpass"
  exit 1
fi

get_guest_ip() {
  sudo virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | head -n1 | cut -d/ -f1
}

wait_guest_ready() {
  local attempts
  attempts=$((ssh_ready_timeout_sec / 3))
  if [[ "$attempts" -lt 1 ]]; then
    attempts=1
  fi

  local ip
  for _ in $(seq 1 "$attempts"); do
    ip="$(get_guest_ip || true)"
    if [[ -n "$ip" ]]; then
      if sshpass -p "$vm_pass" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$ssh_connect_timeout_sec" \
        "$vm_user@$ip" 'echo ready' >/dev/null 2>&1; then
        echo "$ip"
        return 0
      fi
    fi
    sleep 3
  done

  return 1
}

guest_ip="$(wait_guest_ready || true)"
if [[ -z "$guest_ip" ]]; then
  echo "Failed to find reachable guest IP within timeout"
  echo "vm_name=$vm_name"
  exit 1
fi

{
  echo "run_id=$run_id"
  echo "vm_name=$vm_name"
  echo "guest_ip=$guest_ip"
  echo "guest_workdir=$guest_workdir"
  echo "poc_insmod_args=$poc_insmod_args"
  echo
  echo "== wait cloud-init complete =="
} | tee "$run_log"

set +e
timeout --foreground "${cloud_init_wait_timeout_sec}s" sshpass -p "$vm_pass" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout="$ssh_connect_timeout_sec" \
  "$vm_user@$guest_ip" 'cloud-init status --wait' | tee -a "$run_log"
cloud_init_rc=$?
set -e

if [[ $cloud_init_rc -ne 0 ]]; then
  echo "cloud-init did not report clean status; rc=$cloud_init_rc (will verify sentinel)" | tee -a "$run_log"
fi

{
  echo
  echo "== wait cloud-init sentinel =="
} | tee -a "$run_log"

set +e
timeout --foreground "${cloud_init_wait_timeout_sec}s" sshpass -p "$vm_pass" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout="$ssh_connect_timeout_sec" \
  "$vm_user@$guest_ip" "while [[ ! -f '$cloud_init_ready_file' ]]; do sleep 2; done" | tee -a "$run_log"
cloud_init_ready_rc=$?
set -e

if [[ $cloud_init_ready_rc -ne 0 ]]; then
  echo "cloud-init sentinel not present in time; rc=$cloud_init_ready_rc" | tee -a "$run_log"
  exit "$cloud_init_ready_rc"
fi

{
  echo
  echo "== prepare guest workdir =="
} | tee -a "$run_log"

sshpass -p "$vm_pass" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout="$ssh_connect_timeout_sec" \
  "$vm_user@$guest_ip" "rm -rf '$guest_workdir' && mkdir -p '$guest_workdir'" | tee -a "$run_log"

{
  echo
  echo "== upload poc files =="
} | tee -a "$run_log"

sshpass -p "$vm_pass" scp \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$repo_root/poc.c" "$repo_root/Makefile" "$repo_root/tests/repro/guest_trigger_poc.sh" \
  "$vm_user@$guest_ip:$guest_workdir/" | tee -a "$run_log"

{
  echo
  echo "== run guest trigger =="
} | tee -a "$run_log"

set +e
timeout --foreground "${guest_cmd_timeout_sec}s" sshpass -p "$vm_pass" ssh -tt \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout="$ssh_connect_timeout_sec" \
  "$vm_user@$guest_ip" "
    set -euo pipefail
    cd '$guest_workdir'
    chmod +x guest_trigger_poc.sh
    POST_TRIGGER_SLEEP_SEC='$post_trigger_sleep_sec' \
    MIN_ROOT_FREE_KB='$min_root_free_kb' \
    POC_INSMOD_TIMEOUT_SEC='$insmod_timeout_sec' \
    CLOUD_INIT_READY_FILE='$cloud_init_ready_file' \
    TRACE='$trace_flag' \
    POC_INSMOD_ARGS='$poc_insmod_args' \
    ./guest_trigger_poc.sh
  " | tee -a "$run_log"
rc=$?
set -e

{
  echo
  echo "== post host quick check =="
  echo "guest_run_exit_code=$rc"
  sudo virsh list --all | sed -n '1,20p'
  sudo dmesg | egrep -i 'BUG:|panic|general protection|oops|segfault|pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation|kvm' | tail -n 120 || true
  echo
  echo "run_log=$run_log"
} | tee -a "$run_log"

if [[ $rc -ne 0 ]]; then
  echo "Run failed or timed out; see log: $run_log"
  exit $rc
fi

echo "Run finished; log: $run_log"
