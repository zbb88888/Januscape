#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
	set -x
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
images_dir="$script_dir/images"
work_dir="$script_dir/workdir"

image_path="${L1_IMAGE_PATH:-$images_dir/noble-server-cloudimg-amd64.img}"
seed_iso="${L1_SEED_ISO:-$work_dir/seed.iso}"

vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
memory_mb="${L1_MEMORY_MB:-4096}"
vcpu_count="${L1_VCPUS:-4}"
os_variant="${L1_OS_VARIANT:-ubuntu24.04}"
virt_install_timeout_sec="${VIRT_INSTALL_TIMEOUT_SEC:-300}"
dhcp_wait_timeout_sec="${DHCP_WAIT_TIMEOUT_SEC:-240}"
disk_size_gb="${L1_DISK_SIZE_GB:-100}"

storage_dir="${L1_LIBVIRT_STORAGE_DIR:-/var/lib/libvirt/images/januscape}"
overlay_path="${L1_OVERLAY_PATH:-$storage_dir/${vm_name}.qcow2}"
base_copy_path="${L1_BASE_COPY_PATH:-$storage_dir/${vm_name}-base.qcow2}"
seed_copy_path="${L1_SEED_COPY_PATH:-$storage_dir/${vm_name}-seed.iso}"

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

for bin in virsh virt-install qemu-img; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "Missing command: $bin"
		echo "Install libvirt tooling first: sudo apt-get install -y libvirt-daemon-system libvirt-clients virtinst qemu-utils"
		exit 1
	fi
done

sudo install -d -m 755 "$storage_dir"

if [[ ! -f "$base_copy_path" ]]; then
	sudo cp -f "$image_path" "$base_copy_path"
fi

sudo cp -f "$seed_iso" "$seed_copy_path"

sudo chown libvirt-qemu:kvm "$base_copy_path" "$seed_copy_path" >/dev/null 2>&1 || true
sudo chmod 644 "$base_copy_path" "$seed_copy_path"

if ! sudo virsh net-info default >/dev/null 2>&1; then
	echo "libvirt network 'default' not found"
	echo "Install and enable libvirt default network first"
	exit 1
fi

sudo virsh net-start default >/dev/null 2>&1 || true
sudo virsh net-autostart default >/dev/null 2>&1 || true

if sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
	echo "Domain $vm_name already exists; restarting it"
	sudo virsh destroy "$vm_name" >/dev/null 2>&1 || true
	sudo virsh start "$vm_name" >/dev/null
else
	if [[ ! -f "$overlay_path" ]]; then
		sudo qemu-img create -f qcow2 -F qcow2 -b "$base_copy_path" "$overlay_path" >/dev/null
	fi

	current_bytes="$(sudo qemu-img info "$overlay_path" 2>/dev/null | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -n1)"
	target_bytes=$((disk_size_gb * 1024 * 1024 * 1024))
	if [[ -n "$current_bytes" && "$current_bytes" -lt "$target_bytes" ]]; then
		sudo qemu-img resize "$overlay_path" "${disk_size_gb}G" >/dev/null
	fi

	sudo chown libvirt-qemu:kvm "$overlay_path" >/dev/null 2>&1 || true
	sudo chmod 644 "$overlay_path"

	timeout "${virt_install_timeout_sec}s" sudo virt-install \
		--name "$vm_name" \
		--memory "$memory_mb" \
		--vcpus "$vcpu_count" \
		--cpu host-passthrough \
		--machine q35 \
		--import \
		--os-variant "$os_variant" \
		--disk "path=$overlay_path,format=qcow2,bus=virtio" \
		--disk "path=$seed_copy_path,device=cdrom" \
		--network "network=default,model=virtio" \
		--graphics none \
		--noautoconsole
fi

echo "Waiting for DHCP lease..."
vm_ip=""
attempts=$((dhcp_wait_timeout_sec / 2))
if [[ "$attempts" -lt 1 ]]; then
	attempts=1
fi
for _ in $(seq 1 "$attempts"); do
	vm_ip="$(sudo virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | head -n1 | cut -d/ -f1)"
	if [[ -n "$vm_ip" ]]; then
		break
	fi
	sleep 2
done

if [[ -z "$vm_ip" ]]; then
	echo "Could not determine guest IP via libvirt lease"
	echo "Use: sudo virsh domifaddr $vm_name --source lease"
	exit 1
fi

echo "domain=$vm_name"
echo "ip=$vm_ip"
echo "disk_size_gb=$disk_size_gb"
echo "ssh_user=${VM_USERNAME:-januscape}"
echo "ssh_pass=${VM_PASSWORD:-januscape}"
