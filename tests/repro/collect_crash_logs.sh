#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${CRASH_LOG_DIR:-$repo_root/tests/artifacts/crash-logs-$ts}"
mkdir -p "$out_dir"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

run_to_file() {
  local file="$1"
  shift
  {
    echo "$ $*"
    "$@"
  } >"$file" 2>&1 || true
}

run_text() {
  local file="$1"
  shift
  {
    echo "$*"
  } >"$file" 2>&1 || true
}

run_text "$out_dir/collect_meta.txt" "collector_started_utc=$ts"
run_text "$out_dir/collect_meta.txt.tmp" "output_dir=$out_dir"
cat "$out_dir/collect_meta.txt.tmp" >>"$out_dir/collect_meta.txt"
rm -f "$out_dir/collect_meta.txt.tmp"

run_to_file "$out_dir/system.txt" bash -lc "
set -e
printf 'timestamp_utc=%s\n' '$ts'
printf 'hostname=%s\n' \"$(hostname)\"
printf 'whoami=%s\n' \"$(whoami)\"
printf 'kernel=%s\n' \"$(uname -r)\"
uname -a
uptime
printf '\n== panic sysctl ==\n'
${SUDO[*]} sysctl kernel.panic kernel.panic_on_oops kernel.panic_on_warn || true
printf '\n== recent reboot records ==\n'
last -x | head -n 40 || true
"

run_to_file "$out_dir/livepatch_state.txt" bash -lc "
set -e
if [[ -d /sys/kernel/livepatch ]]; then
  ls -la /sys/kernel/livepatch
  if [[ -d /sys/kernel/livepatch/januscape_lp ]]; then
    printf '\n== januscape_lp ==\n'
    find /sys/kernel/livepatch/januscape_lp -maxdepth 3 -type f | sort | while read -r f; do
      printf '%s=' "\$f"
      cat "\$f" 2>/dev/null || true
    done
  fi
else
  echo 'livepatch_sysfs_not_present'
fi
"

run_to_file "$out_dir/dmesg_tail.txt" bash -lc "
set -e
${SUDO[*]} dmesg -T | tail -n 800
"

run_to_file "$out_dir/dmesg_filter.txt" bash -lc "
set -e
${SUDO[*]} dmesg -T | egrep -i 'BUG:|panic|Oops|general protection|segfault|pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation|kvm' | tail -n 400
"

run_to_file "$out_dir/journal_k_current.txt" bash -lc "
set -e
${SUDO[*]} journalctl -k -b --no-pager
"

run_to_file "$out_dir/journal_k_prev.txt" bash -lc "
set -e
${SUDO[*]} journalctl -k -b -1 --no-pager
"

run_to_file "$out_dir/journal_filter_prev_current.txt" bash -lc "
set -e
{
  echo '== current boot =='
  ${SUDO[*]} journalctl -k -b --no-pager || true
  echo
  echo '== previous boot =='
  ${SUDO[*]} journalctl -k -b -1 --no-pager || true
} | egrep -i 'BUG:|panic|Oops|general protection|segfault|pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation|kvm' | tail -n 800
"

run_to_file "$out_dir/virsh_list.txt" bash -lc "
set -e
${SUDO[*]} virsh list --all
"

run_to_file "$out_dir/virsh_dominfo.txt" bash -lc "
set -e
${SUDO[*]} virsh dominfo '$vm_name'
"

run_to_file "$out_dir/virsh_domifaddr.txt" bash -lc "
set -e
${SUDO[*]} virsh domifaddr '$vm_name' --source lease
"

run_to_file "$out_dir/virsh_dumpxml.txt" bash -lc "
set -e
${SUDO[*]} virsh dumpxml '$vm_name'
"

libvirt_qemu_log="/var/log/libvirt/qemu/${vm_name}.log"
if [[ -f "$libvirt_qemu_log" ]]; then
  run_to_file "$out_dir/libvirt_qemu_log_tail.txt" bash -lc "
set -e
${SUDO[*]} tail -n 1200 '$libvirt_qemu_log'
"
else
  run_text "$out_dir/libvirt_qemu_log_tail.txt" "missing: $libvirt_qemu_log"
fi

run_to_file "$out_dir/coredumpctl_recent.txt" bash -lc "
set -e
${SUDO[*]} coredumpctl list --no-pager | tail -n 80
"

run_to_file "$out_dir/var_crash_listing.txt" bash -lc "
set -e
${SUDO[*]} ls -lah /var/crash || true
"

run_to_file "$out_dir/summary.txt" bash -lc "
set -e
printf 'output_dir=%s\n' '$out_dir'
printf 'vm_name=%s\n' '$vm_name'
printf '\n== key signatures ==\n'
cat '$out_dir/dmesg_filter.txt' '$out_dir/journal_filter_prev_current.txt' 2>/dev/null | \
  egrep -i 'BUG:|panic|Oops|general protection|segfault|pte_list_remove|mmu_set_spte|kvm_mmu_page_set_translation|kvm' | tail -n 200 || true
"

echo "Collected crash logs to: $out_dir"
echo "See: $out_dir/summary.txt"
