#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
images_dir="$script_dir/images"
work_dir="$script_dir/workdir"

image_path="${L1_IMAGE_PATH:-$images_dir/noble-server-cloudimg-amd64.img}"
seed_iso="${L1_SEED_ISO:-$work_dir/seed.iso}"
overlay_path="${L1_OVERLAY_PATH:-$work_dir/l1-overlay.qcow2}"

memory_mb="${L1_MEMORY_MB:-4096}"
vcpu_count="${L1_VCPUS:-4}"
ssh_port="${L1_SSH_PORT:-2222}"
l1_runtime_timeout_sec="${L1_RUNTIME_TIMEOUT_SEC:-3600}"

if [[ ! -f "$image_path" ]]; then
	echo "Missing guest image: $image_path"
	echo "Run ./tests/repro/download_guest_image.sh first"
	exit 1
fi

if [[ ! -f "$seed_iso" ]]; then
	echo "Missing seed ISO: $seed_iso"
	echo "Run ./tests/repro/create_seed_iso.sh first"
	exit 1
fi

if [[ ! -f "$overlay_path" ]]; then
	qemu-img create -f qcow2 -F qcow2 -b "$image_path" "$overlay_path" >/dev/null
fi

qemu_cmd=(
	qemu-system-x86_64
	-enable-kvm
	-cpu host
	-smp "$vcpu_count"
	-m "$memory_mb"
	-machine q35,accel=kvm
	-drive "if=virtio,file=$overlay_path,format=qcow2"
	-drive "if=virtio,file=$seed_iso,format=raw,media=cdrom"
	-nic "user,model=virtio-net-pci,hostfwd=tcp::${ssh_port}-:22"
	-virtfs "local,path=$repo_root,mount_tag=januscape-src,security_model=none,id=januscape-src"
	-serial mon:stdio
	-nographic
)

if [[ "$l1_runtime_timeout_sec" -gt 0 ]]; then
	echo "Applying runtime timeout: ${l1_runtime_timeout_sec}s"
	exec timeout --foreground "${l1_runtime_timeout_sec}s" "${qemu_cmd[@]}"
else
	exec "${qemu_cmd[@]}"
fi