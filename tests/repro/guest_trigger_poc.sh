#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
  set -x
fi

# Tunables for manual test loops
post_trigger_sleep_sec="${POST_TRIGGER_SLEEP_SEC:-20}"
poc_insmod_args="${POC_INSMOD_ARGS:-}"
module_dir="$(pwd)"
min_root_free_kb="${MIN_ROOT_FREE_KB:-262144}"
insmod_timeout_sec="${POC_INSMOD_TIMEOUT_SEC:-180}"
cloud_init_ready_file="${CLOUD_INIT_READY_FILE:-/var/lib/januscape/cloud-init-ready}"

echo "== guest kernel =="
uname -a

echo "== nested flags =="
grep -E -m1 'vmx|svm' /proc/cpuinfo || true

echo "== /dev/kvm =="
ls -l /dev/kvm || true

echo "== check cloud-init sentinel =="
if [[ ! -f "$cloud_init_ready_file" ]]; then
  echo "cloud-init sentinel missing: $cloud_init_ready_file"
  echo "dependencies may not be ready"
  exit 1
fi

echo "== guest pre-clean =="
current_base="$(basename -- "$module_dir")"
for d in /tmp/januscape-poc-*; do
  [[ -e "$d" ]] || continue
  if [[ "$(basename -- "$d")" != "$current_base" ]]; then
    sudo rm -rf -- "$d" || true
  fi
done
sudo rm -rf /var/tmp/* || true
sudo journalctl --vacuum-size=50M >/dev/null 2>&1 || true

echo "== disk after pre-clean =="
df -h /
root_free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ -z "$root_free_kb" || "$root_free_kb" -lt "$min_root_free_kb" ]]; then
  echo "insufficient root free space: ${root_free_kb:-0} KB (need >= $min_root_free_kb KB)"
  echo "please free space in guest / and retry"
  exit 1
fi

echo "== verify build deps =="
for bin in make gcc; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "missing required command: $bin"
    echo "dependencies should be provisioned by cloud-init"
    exit 1
  fi
done

if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
  echo "missing kernel headers for $(uname -r)"
  echo "dependencies should be provisioned by cloud-init"
  exit 1
fi

if [[ ! -f "$module_dir/poc.c" || ! -f "$module_dir/Makefile" ]]; then
  echo "missing poc.c or Makefile in module_dir=$module_dir"
  exit 1
fi

echo "== build poc =="
sudo make -C "/lib/modules/$(uname -r)/build" M="$module_dir" clean || true
sudo make -C "/lib/modules/$(uname -r)/build" M="$module_dir" modules

echo "== modinfo =="
sudo modinfo "$module_dir/poc.ko" | head -n 20

echo "== trigger intel path =="
sudo rmmod kvm_intel || true
insmod_rc=0
if [[ "$insmod_timeout_sec" -gt 0 ]]; then
  set +e
  timeout --foreground "${insmod_timeout_sec}s" sudo insmod "$module_dir/poc.ko" $poc_insmod_args
  insmod_rc=$?
  set -e
  if [[ "$insmod_rc" -eq 124 ]]; then
    echo "insmod timed out after ${insmod_timeout_sec}s"
  elif [[ "$insmod_rc" -ne 0 ]]; then
    echo "insmod failed with rc=$insmod_rc"
    exit "$insmod_rc"
  fi
else
  sudo insmod "$module_dir/poc.ko" $poc_insmod_args
fi

sleep "$post_trigger_sleep_sec"

echo "== guest modules =="
sudo lsmod | grep -E '^poc\b|^kvm_intel\b|^kvm\b' || true

echo "== guest dmesg tail =="
sudo dmesg | egrep -i 'poc|kvm|BUG|panic' | tail -n 200 || true

if [[ "$insmod_rc" -eq 124 ]]; then
  echo "guest_trigger_poc: insmod timeout"
  exit 124
fi

echo "guest_trigger_poc: done"
