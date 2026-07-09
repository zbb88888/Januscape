#!/usr/bin/env bash
set -euo pipefail

KREL="$(uname -r)"
KDIR="/lib/modules/$KREL/build"
BOOTCFG="/boot/config-$KREL"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

ok() {
  echo "OK:$1"
}

warn() {
  echo "WARN:$1"
}

fail() {
  echo "FAIL:$1"
}

is_ubuntu=0
is_supported_release=0
has_kdir=0
has_livepatch_header=0
has_kvm_btf=0
has_kvm_symbol=0
cfg_livepatch=unknown
cfg_dyn_ftrace=unknown
cfg_ftrace_regs=unknown
cfg_ftrace_direct=unknown

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    is_ubuntu=1
    ok "os.id=ubuntu"
  else
    warn "os.id=${ID:-unknown}"
  fi

  case "${VERSION_ID:-}" in
    22.04|24.04)
      is_supported_release=1
      ok "os.version=${VERSION_ID}"
      ;;
    *)
      warn "os.version=${VERSION_ID:-unknown} (expected 22.04 or 24.04)"
      ;;
  esac
else
  fail "missing /etc/os-release"
fi

if [[ -d "$KDIR" ]]; then
  has_kdir=1
  ok "kernel.build_dir=$KDIR"
else
  fail "kernel.build_dir_missing=$KDIR"
fi

if [[ -f "$KDIR/include/linux/livepatch.h" ]]; then
  has_livepatch_header=1
  ok "livepatch.header=present"
else
  fail "livepatch.header=missing"
fi

if [[ -f "$BOOTCFG" ]]; then
  cfg_livepatch="$(grep -E '^CONFIG_LIVEPATCH=' "$BOOTCFG" | head -n1 | cut -d= -f2 || true)"
  cfg_dyn_ftrace="$(grep -E '^CONFIG_DYNAMIC_FTRACE=' "$BOOTCFG" | head -n1 | cut -d= -f2 || true)"
  cfg_ftrace_regs="$(grep -E '^CONFIG_DYNAMIC_FTRACE_WITH_REGS=' "$BOOTCFG" | head -n1 | cut -d= -f2 || true)"
  cfg_ftrace_direct="$(grep -E '^CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS=' "$BOOTCFG" | head -n1 | cut -d= -f2 || true)"

  [[ "$cfg_livepatch" == "y" ]] && ok "cfg.livepatch=y" || warn "cfg.livepatch=${cfg_livepatch:-unset}"
  [[ "$cfg_dyn_ftrace" == "y" ]] && ok "cfg.dynamic_ftrace=y" || warn "cfg.dynamic_ftrace=${cfg_dyn_ftrace:-unset}"
  [[ "$cfg_ftrace_regs" == "y" ]] && ok "cfg.ftrace_with_regs=y" || warn "cfg.ftrace_with_regs=${cfg_ftrace_regs:-unset}"
  [[ "$cfg_ftrace_direct" == "y" ]] && ok "cfg.ftrace_direct_calls=y" || warn "cfg.ftrace_direct_calls=${cfg_ftrace_direct:-unset}"
else
  warn "boot.config_missing=$BOOTCFG"
fi

if [[ -e /sys/kernel/btf/kvm ]]; then
  has_kvm_btf=1
  ok "btf.kvm=present"
else
  warn "btf.kvm=missing"
fi

if grep -q "kvm_mmu_get_child_sp" /proc/kallsyms 2>/dev/null; then
  has_kvm_symbol=1
  ok "kallsyms.kvm_mmu_get_child_sp=present"
else
  warn "kallsyms.kvm_mmu_get_child_sp=missing_or_restricted"
fi

ready_build=0
ready_validate=0

if [[ $is_ubuntu -eq 1 && $is_supported_release -eq 1 && $has_kdir -eq 1 && $has_livepatch_header -eq 1 ]]; then
  ready_build=1
fi

if [[ $ready_build -eq 1 && "$cfg_livepatch" == "y" && "$cfg_dyn_ftrace" == "y" && $has_kvm_btf -eq 1 && $has_kvm_symbol -eq 1 ]]; then
  ready_validate=1
fi

{
  echo "---"
  echo "timestamp_utc=$TS"
  echo "node=$(hostname -f 2>/dev/null || hostname)"
  echo "kernel_release=$KREL"
  echo "ready_build=$ready_build"
  echo "ready_validate=$ready_validate"
  echo "is_ubuntu=$is_ubuntu"
  echo "is_supported_release=$is_supported_release"
  echo "has_kdir=$has_kdir"
  echo "has_livepatch_header=$has_livepatch_header"
  echo "cfg_livepatch=${cfg_livepatch:-unset}"
  echo "cfg_dynamic_ftrace=${cfg_dyn_ftrace:-unset}"
  echo "cfg_ftrace_with_regs=${cfg_ftrace_regs:-unset}"
  echo "cfg_ftrace_direct_calls=${cfg_ftrace_direct:-unset}"
  echo "has_kvm_btf=$has_kvm_btf"
  echo "has_kvm_symbol=$has_kvm_symbol"
}