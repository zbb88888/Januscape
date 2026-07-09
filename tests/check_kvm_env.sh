#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
artifacts_dir="$script_dir/artifacts"
mkdir -p "$artifacts_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_file="$artifacts_dir/kvm-env-$timestamp.txt"

exec > >(tee "$report_file") 2>&1

echo "# Januscape host virtualization report"
echo "repo_root=$repo_root"
echo "timestamp_utc=$timestamp"
echo

echo "## Kernel"
uname -a
echo

echo "## CPU virtualization flags"
if grep -E -m1 'vmx|svm' /proc/cpuinfo; then
	:
else
	echo "No vmx/svm flag found in /proc/cpuinfo"
fi
echo

echo "## Loaded KVM modules"
if lsmod | grep '^kvm'; then
	:
else
	echo "No kvm modules are currently loaded"
fi
echo

echo "## Nested virtualization parameters"
found_nested=0
for nested_file in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
	if [[ -f "$nested_file" ]]; then
		printf '%s=%s\n' "$nested_file" "$(cat "$nested_file")"
		found_nested=1
	fi
done
if [[ "$found_nested" -eq 0 ]]; then
	echo "No nested virtualization parameter file was found"
fi
echo

echo "## /dev/kvm"
if [[ -e /dev/kvm ]]; then
	ls -l /dev/kvm
else
	echo "/dev/kvm is missing"
fi
echo

echo "## Validation helpers"
if command -v kvm-ok >/dev/null 2>&1; then
	kvm-ok || true
else
	echo "kvm-ok is not installed"
fi

if command -v virt-host-validate >/dev/null 2>&1; then
	virt-host-validate qemu || true
else
	echo "virt-host-validate is not installed"
fi
echo

echo "## QEMU/KVM binaries"
for binary in qemu-system-x86_64 qemu-img qemu-nbd; do
	if command -v "$binary" >/dev/null 2>&1; then
		printf '%s=%s\n' "$binary" "$(command -v "$binary")"
		"$binary" --version | head -n 1 || true
	else
		echo "$binary is not installed"
	fi
done
echo

echo "Report written to $report_file"