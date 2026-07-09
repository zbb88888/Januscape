#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

sudo insmod ./januscape_lp.ko
lsmod | awk '$1=="januscape_lp"{print}' || true
sudo dmesg | tail -n 20
