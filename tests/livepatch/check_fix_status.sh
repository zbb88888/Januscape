#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sources_root="$script_dir/sources"

latest_tree="$(find "$sources_root" -mindepth 3 -maxdepth 3 -type d -path '*/extracted/*' | head -n 1 || true)"
if [[ -z "$latest_tree" ]]; then
	echo "No extracted kernel source tree found under $sources_root"
	echo "Run ./tests/livepatch/fetch_matching_kernel_source.sh first"
	exit 1
fi

target_file="$latest_tree/arch/x86/kvm/mmu/mmu.c"
if [[ ! -f "$target_file" ]]; then
	echo "Missing target file: $target_file"
	exit 1
fi

start_line="$(grep -n '^static struct kvm_mmu_page \*kvm_mmu_get_child_sp' "$target_file" | head -n 1 | cut -d: -f1)"
if [[ -z "$start_line" ]]; then
	echo "Could not locate kvm_mmu_get_child_sp in $target_file"
	exit 1
fi

end_line=$((start_line + 18))

echo "source_tree=$latest_tree"
echo "target_file=$target_file"
echo
sed -n "${start_line},${end_line}p" "$target_file"
echo

if grep -q 'spte_to_child_sp(\*sptep)->role.word == role.word' "$target_file"; then
	echo "status=upstream_role_check_fix_present"
	exit 0
fi

if grep -q 'if (is_shadow_present_pte(\*sptep) && !is_large_pte(\*sptep))' "$target_file"; then
	echo "status=non_upstream_shape_requires_tracker_validation"
	exit 4
fi

if grep -q 'spte_to_child_sp(\*sptep)->gfn == gfn' "$target_file"; then
	echo "status=likely_vulnerable_shape"
	exit 2
fi

echo "status=unknown_shape"
	exit 3