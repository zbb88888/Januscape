#!/usr/bin/env bash
set -euo pipefail

wait_for_transition_clear() {
  local dir="/sys/kernel/livepatch/januscape_lp"

  if [[ ! -e "$dir/transition" ]]; then
    return 0
  fi

  timeout 10 bash -lc 'while [[ $(cat /sys/kernel/livepatch/januscape_lp/transition) != 0 ]]; do :; done'
}

if [[ -e /sys/kernel/livepatch/januscape_lp/enabled ]]; then
  wait_for_transition_clear
  echo 0 | sudo tee /sys/kernel/livepatch/januscape_lp/enabled >/dev/null
  if [[ -e /sys/kernel/livepatch/januscape_lp/transition ]]; then
    timeout 10 bash -lc 'while [[ -d /sys/kernel/livepatch/januscape_lp && $(cat /sys/kernel/livepatch/januscape_lp/transition 2>/dev/null || echo 0) != 0 ]]; do :; done'
  fi
fi

if lsmod | awk '$1=="januscape_lp"{found=1} END{exit !found}'; then
  sudo rmmod januscape_lp
fi

if lsmod | awk '$1=="januscape_lp"{found=1} END{exit !found}'; then
  echo "januscape_lp:still_loaded"
  exit 1
fi

echo "januscape_lp:not_loaded"
if [[ -e /sys/kernel/livepatch/januscape_lp/enabled ]]; then
  echo -n "livepatch_enabled="
  cat /sys/kernel/livepatch/januscape_lp/enabled
else
  echo "livepatch_sysfs:not_present"
fi
