#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$script_dir/workdir"
mkdir -p "$work_dir"

if ! command -v cloud-localds >/dev/null 2>&1; then
	echo "cloud-localds is required. Install cloud-image-utils first."
	exit 1
fi

hostname_value="${VM_HOSTNAME:-januscape-l1}"
username_value="${VM_USERNAME:-januscape}"
password_value="${VM_PASSWORD:-januscape}"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

user_data="$work_dir/user-data"
meta_data="$work_dir/meta-data"
seed_iso="$work_dir/seed.iso"
seed_create_timeout_sec="${SEED_CREATE_TIMEOUT_SEC:-120}"
cloud_init_ready_file="${CLOUD_INIT_READY_FILE:-/var/lib/januscape/cloud-init-ready}"

cat > "$user_data" <<EOF
#cloud-config
hostname: $hostname_value
users:
  - default
  - name: $username_value
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [adm, sudo, kvm]
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
chpasswd:
  list: |
    $username_value:$password_value
  expire: false
package_update: true
mounts:
  - [januscape-src, /mnt/januscape, 9p, 'trans=virtio,version=9p2000.L,msize=104857600,_netdev', '0', '0']
runcmd:
  - mkdir -p "$(dirname "$cloud_init_ready_file")"
  - rm -f "$cloud_init_ready_file"
  - export DEBIAN_FRONTEND=noninteractive
  - apt-get update -y
  - apt-get install -y --no-install-recommends make gcc linux-headers-$(uname -r)
  - mkdir -p /mnt/januscape
  - mount -a || true
  - echo 'Repo is expected at /mnt/januscape'
  - touch "$cloud_init_ready_file"
EOF

cat > "$meta_data" <<EOF
instance-id: januscape-l1
local-hostname: $hostname_value
EOF

timeout "${seed_create_timeout_sec}s" cloud-localds "$seed_iso" "$user_data" "$meta_data"
echo "Created cloud-init seed ISO at $seed_iso"