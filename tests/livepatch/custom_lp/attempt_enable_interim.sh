#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# This is for test-host experiments only.
sudo insmod ./januscape_lp.ko enable_patch=1 allow_interim_semantics=1
lsmod | awk '$1=="januscape_lp"{print}' || true
sudo dmesg | tail -n 30
