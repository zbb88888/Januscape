#!/usr/bin/env bash
set -euo pipefail

sudo rmmod januscape_lp
if lsmod | awk '$1=="januscape_lp"{found=1} END{exit !found}'; then
	echo "januscape_lp:still_loaded"
	exit 1
fi
echo "januscape_lp:not_loaded"
sudo dmesg | tail -n 20
