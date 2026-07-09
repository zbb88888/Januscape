#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$script_dir/workdir"

vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
storage_dir="${L1_LIBVIRT_STORAGE_DIR:-/var/lib/libvirt/images/januscape}"
overlay_path="${L1_OVERLAY_PATH:-$storage_dir/${vm_name}.qcow2}"
base_copy_path="${L1_BASE_COPY_PATH:-$storage_dir/${vm_name}-base.qcow2}"
seed_copy_path="${L1_SEED_COPY_PATH:-$storage_dir/${vm_name}-seed.iso}"
remove_overlay="${REMOVE_OVERLAY:-0}"

if ! command -v virsh >/dev/null 2>&1; then
	echo "Missing command: virsh"
	exit 1
fi

if sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
	sudo virsh destroy "$vm_name" >/dev/null 2>&1 || true
	sudo virsh undefine "$vm_name" --nvram >/dev/null 2>&1 || sudo virsh undefine "$vm_name" >/dev/null
	echo "undefined=$vm_name"
else
	echo "domain_not_found=$vm_name"
fi

if [[ "$remove_overlay" == "1" ]]; then
	sudo rm -f "$overlay_path" "$base_copy_path" "$seed_copy_path"
	echo "removed_overlay=$overlay_path"
fi
