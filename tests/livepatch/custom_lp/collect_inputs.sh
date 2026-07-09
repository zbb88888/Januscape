#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
artifacts_dir="$script_dir/artifacts"
mkdir -p "$artifacts_dir"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="$artifacts_dir/$ts"
mkdir -p "$out_dir"

kernel_rel="$(uname -r)"
kmod_path="/lib/modules/$kernel_rel/kernel/arch/x86/kvm/kvm.ko.zst"

echo "kernel_release=$kernel_rel" | tee "$out_dir/summary.txt"
echo "kmod_path=$kmod_path" | tee -a "$out_dir/summary.txt"

grep -E 'CONFIG_(LIVEPATCH|DYNAMIC_FTRACE|FUNCTION_TRACER|DEBUG_INFO_BTF|HAVE_RELIABLE_STACKTRACE)' \
	"/boot/config-$kernel_rel" > "$out_dir/kernel-config.txt" || true

grep -E 'kvm_mmu_get_child_sp|__kvm_mmu_get_shadow_page|kvm_mmu_child_role|__pfx_kvm_mmu_get_child_sp' /proc/kallsyms \
	> "$out_dir/kallsyms-targets.txt" || true

bpftool btf dump file /sys/kernel/btf/kvm format raw > "$out_dir/kvm-btf-raw.txt"
grep -n 'kvm_mmu_get_child_sp\|__kvm_mmu_get_shadow_page\|kvm_mmu_child_role' "$out_dir/kvm-btf-raw.txt" \
	> "$out_dir/btf-target-lines.txt" || true

tmp_ko="$out_dir/kvm.ko"
zstd -d -q -c "$kmod_path" > "$tmp_ko"
objdump -d --no-show-raw-insn "$tmp_ko" > "$out_dir/kvm-objdump.txt"
rm -f "$tmp_ko"

grep -n -A80 -B20 '<kvm_mmu_get_child_sp>:' "$out_dir/kvm-objdump.txt" > "$out_dir/kvm_mmu_get_child_sp.txt" || true
grep -n -A80 -B20 '<__kvm_mmu_get_shadow_page>:' "$out_dir/kvm-objdump.txt" > "$out_dir/__kvm_mmu_get_shadow_page.txt" || true
grep -n -A80 -B20 '<kvm_mmu_child_role>:' "$out_dir/kvm-objdump.txt" > "$out_dir/kvm_mmu_child_role.txt" || true

echo "artifacts=$out_dir" | tee -a "$out_dir/summary.txt"
