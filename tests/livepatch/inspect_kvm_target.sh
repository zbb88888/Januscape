#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
artifacts_dir="$script_dir/artifacts"
mkdir -p "$artifacts_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_dir="$artifacts_dir/inspect-$timestamp"
mkdir -p "$report_dir"

kernel_release="$(uname -r)"
module_path="/lib/modules/$kernel_release/kernel/arch/x86/kvm/kvm.ko.zst"
tmp_module="$report_dir/kvm.ko"

printf 'kernel_release=%s\n' "$kernel_release" | tee "$report_dir/summary.txt"
printf 'module_path=%s\n' "$module_path" | tee -a "$report_dir/summary.txt"

grep -E 'CONFIG_(LIVEPATCH|FTRACE|FUNCTION_TRACER|DYNAMIC_FTRACE|HAVE_RELIABLE_STACKTRACE|DEBUG_INFO_BTF)' \
	"/boot/config-$kernel_release" > "$report_dir/kernel-config.txt" || true

grep -E 'kvm_mmu_get_child_sp|kvm_mmu_child_role|__kvm_mmu_get_shadow_page|kallsyms_lookup_name' /proc/kallsyms \
	> "$report_dir/kallsyms-targets.txt" || true

bpftool btf dump file /sys/kernel/btf/kvm format c > "$report_dir/kvm-btf.c"

zstd -d -q -c "$module_path" > "$tmp_module"
objdump -d --no-show-raw-insn "$tmp_module" > "$report_dir/kvm-objdump.txt"
rm -f "$tmp_module"

grep -n -A80 -B20 '<kvm_mmu_get_child_sp>:' "$report_dir/kvm-objdump.txt" > "$report_dir/kvm_mmu_get_child_sp.txt" || true
grep -n -A80 -B20 '<kvm_mmu_child_role>:' "$report_dir/kvm-objdump.txt" > "$report_dir/kvm_mmu_child_role.txt" || true
grep -n -A80 -B20 '<__kvm_mmu_get_shadow_page>:' "$report_dir/kvm-objdump.txt" > "$report_dir/__kvm_mmu_get_shadow_page.txt" || true
grep -n -A80 -B20 'struct kvm_mmu_page' "$report_dir/kvm-btf.c" > "$report_dir/kvm_mmu_page_type.txt" || true
grep -n -A40 -B10 'union kvm_mmu_page_role' "$report_dir/kvm-btf.c" > "$report_dir/kvm_mmu_page_role_type.txt" || true

cat <<EOF | tee -a "$report_dir/summary.txt"
artifacts_saved_to=$report_dir
notes:
- This collects the exact live KVM module disassembly and module BTF.
- Use it before building any custom livepatch, because Ubuntu's shipped KVM code may differ from the upstream snippet in the Januscape write-up.
EOF