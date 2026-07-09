#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run this script as root"
	exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
	echo "This script currently supports apt-based systems only"
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive

packages=(
	cpu-checker
	ovmf
	qemu-kvm
	qemu-system-x86
	qemu-utils
)

apt-get update
apt-get install -y "${packages[@]}"

echo
echo "Installed packages: ${packages[*]}"
echo

if command -v qemu-system-x86_64 >/dev/null 2>&1; then
	qemu-system-x86_64 --version | head -n 1
fi

if command -v kvm-ok >/dev/null 2>&1; then
	kvm-ok || true
fi