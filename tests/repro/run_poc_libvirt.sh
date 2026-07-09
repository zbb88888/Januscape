#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

vm_name="${L1_VM_NAME:-januscape-l1-libvirt}"
vm_user="${VM_USERNAME:-januscape}"
vm_pass="${VM_PASSWORD:-januscape}"

ssh_ready_timeout_sec="${SSH_READY_TIMEOUT_SEC:-300}"
ssh_connect_timeout_sec="${SSH_CONNECT_TIMEOUT_SEC:-5}"
guest_cmd_timeout_sec="${GUEST_CMD_TIMEOUT_SEC:-1800}"
post_trigger_sleep_sec="${POST_TRIGGER_SLEEP_SEC:-20}"
apt_lock_wait_timeout_sec="${APT_LOCK_WAIT_TIMEOUT_SEC:-180}"
poc_insmod_args="${POC_INSMOD_ARGS:-}"

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

guest_ip=""
attempts=$((ssh_ready_timeout_sec / 3))
if [[ "$attempts" -lt 1 ]]; then
	attempts=1
fi

for _ in $(seq 1 "$attempts"); do
	guest_ip="$(get_guest_ip || true)"
	if [[ -n "$guest_ip" ]]; then
		if sshpass -p "$vm_pass" ssh \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null \
			-o ConnectTimeout="$ssh_connect_timeout_sec" \
			"$vm_user@$guest_ip" 'echo ready' >/dev/null 2>&1; then
			break
		fi
	fi
	sleep 3
done

if [[ -z "$guest_ip" ]]; then
	echo "Failed to determine guest IP within timeout"
	exit 1
fi

echo "domain=$vm_name"
echo "ip=$guest_ip"

sshpass -p "$vm_pass" ssh \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	"$vm_user@$guest_ip" 'mkdir -p ~/januscape-poc'

sshpass -p "$vm_pass" scp \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	"$repo_root/poc.c" "$repo_root/Makefile" \
	"$vm_user@$guest_ip:~/januscape-poc/"

if ! timeout --foreground "${guest_cmd_timeout_sec}s" sshpass -p "$vm_pass" ssh -tt \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout="$ssh_connect_timeout_sec" \
	"$vm_user@$guest_ip" 'bash -s' <<EOF
set -euo pipefail

cd ~/januscape-poc

echo "== guest kernel =="
uname -a

echo "== nested flags =="
grep -E -m1 'vmx|svm' /proc/cpuinfo || true

echo "== /dev/kvm =="
ls -l /dev/kvm || true

echo "== wait apt lock =="
start_ts=\$(date +%s)
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
	now_ts=\$(date +%s)
	if (( now_ts - start_ts > $apt_lock_wait_timeout_sec )); then
		echo "apt lock wait timeout"
		exit 1
	fi
	sleep 2
done

sudo apt-get clean || true
sudo rm -rf /var/cache/apt/archives/* /var/tmp/* || true
sudo apt-get update -y >/tmp/libvirt-apt-update.log 2>&1 || true
sudo apt-get install -y --no-install-recommends make gcc flex bison linux-headers-\$(uname -r) >/tmp/libvirt-apt-build.log 2>&1 || true

sudo make -C /lib/modules/\$(uname -r)/build M=\$HOME/januscape-poc clean || true
sudo make -C /lib/modules/\$(uname -r)/build M=\$HOME/januscape-poc modules
sudo modinfo \$HOME/januscape-poc/poc.ko | head -n 20

sudo rmmod kvm_intel || true
sudo insmod \$HOME/januscape-poc/poc.ko $poc_insmod_args
sleep $post_trigger_sleep_sec

echo "== guest modules =="
sudo lsmod | grep -E '^poc\\b|^kvm_intel\\b|^kvm\\b' || true

echo "== guest dmesg tail =="
sudo dmesg | egrep -i 'poc|kvm|BUG|panic' | tail -n 160 || true
EOF
then
	echo "Guest test command timed out or failed"
	exit 1
fi

echo "run_poc_libvirt: done"
