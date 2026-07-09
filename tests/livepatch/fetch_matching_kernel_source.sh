#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sources_dir="$script_dir/sources"
mkdir -p "$sources_dir"

if ! command -v curl >/dev/null 2>&1; then
	echo "curl is required"
	exit 1
fi

if ! command -v dpkg-source >/dev/null 2>&1; then
	echo "dpkg-source is required; install dpkg-dev first"
	exit 1
fi

kernel_release="${KERNEL_RELEASE:-$(uname -r)}"
kernel_pkg="linux-image-$kernel_release"
archive_base="${UBUNTU_ARCHIVE_BASE:-http://archive.ubuntu.com/ubuntu}"
security_base="${UBUNTU_SECURITY_BASE:-http://security.ubuntu.com/ubuntu}"
suite="${UBUNTU_SUITE:-noble}"
lookup_only="${LOOKUP_ONLY:-0}"

built_using_line="$(apt-cache show "$kernel_pkg" 2>/dev/null | awk -F': ' '/^Built-Using:/{print $2; exit}')"
if [[ -z "$built_using_line" ]]; then
	echo "Could not determine Built-Using from $kernel_pkg"
	exit 1
fi

source_pkg="$(printf '%s\n' "$built_using_line" | sed -E 's/ \(=.*$//')"
source_ver="$(printf '%s\n' "$built_using_line" | sed -nE 's/.*\(= ([^)]+)\).*/\1/p')"

if [[ -z "$source_pkg" || -z "$source_ver" ]]; then
	echo "Could not parse source package/version from Built-Using: $built_using_line"
	exit 1
fi

tmp_sources="$(mktemp)"
cleanup() {
	rm -f "$tmp_sources"
}
trap cleanup EXIT

fetch_stanza() {
	local base_url="$1"
	local pocket="$2"
	local dist_path
	if [[ -n "$pocket" ]]; then
		dist_path="$base_url/dists/$suite-$pocket/main/source/Sources.gz"
	else
		dist_path="$base_url/dists/$suite/main/source/Sources.gz"
	fi
	if ! curl -L --fail "$dist_path" | gzip -dc > "$tmp_sources"; then
		return 1
	fi
	awk -v pkg="$source_pkg" -v ver="$source_ver" 'BEGIN{RS="\n\n"} $0 ~ ("Package: " pkg "\\n") && $0 ~ ("Version: " ver "\\n") {print; found=1; exit} END{if (!found) exit 1}' "$tmp_sources"
}

stanza=""
for pocket in updates security ''; do
	if stanza="$(fetch_stanza "$archive_base" "$pocket" 2>/dev/null)"; then
		archive_root="$archive_base"
		archive_pocket="${pocket:-release}"
		break
	fi
	if stanza="$(fetch_stanza "$security_base" "$pocket" 2>/dev/null)"; then
		archive_root="$security_base"
		archive_pocket="${pocket:-release}"
		break
	fi
done

if [[ -z "$stanza" ]]; then
	echo "Could not locate source stanza for $source_pkg $source_ver"
	exit 1
fi

directory="$(printf '%s\n' "$stanza" | awk -F': ' '/^Directory:/{print $2; exit}')"
if [[ -z "$directory" ]]; then
	echo "Could not parse source Directory field"
	exit 1
fi

mapfile -t files < <(printf '%s\n' "$stanza" | awk '
		/^Files:/ { in_files=1; next }
		in_files && /^(Checksums-|Package-List:|Ubuntu-Compatible-Signing:|Vcs-Git:|Testsuite:|Testsuite-Triggers:)/ { exit }
		in_files && NF >= 3 { print $3 }
	')

if [[ "${#files[@]}" -eq 0 ]]; then
	echo "Could not parse source file list"
	exit 1
fi

target_dir="$sources_dir/${source_pkg}-${source_ver}"
mkdir -p "$target_dir"

printf 'kernel_release=%s\n' "$kernel_release"
printf 'kernel_package=%s\n' "$kernel_pkg"
printf 'source_package=%s\n' "$source_pkg"
printf 'source_version=%s\n' "$source_ver"
printf 'archive_pocket=%s\n' "$archive_pocket"
printf 'target_dir=%s\n' "$target_dir"

for filename in "${files[@]}"; do
	url="$archive_root/$directory/$filename"
	output="$target_dir/$filename"
	if [[ -f "$output" ]]; then
		echo "reuse $output"
		continue
	fi
	if [[ "$lookup_only" == "1" ]]; then
		echo "would_download $url"
		continue
	fi
	echo "download $url"
	curl -L --fail --output "$output" "$url"
done

dsc_file="$target_dir/${source_pkg}_${source_ver}.dsc"
extract_dir="$target_dir/extracted"

if [[ "$lookup_only" == "1" ]]; then
	printf 'lookup_only=1\n'
	exit 0
fi

if [[ ! -f "$dsc_file" ]]; then
	echo "Missing DSC file: $dsc_file"
	exit 1
fi

if [[ ! -d "$extract_dir" ]]; then
	mkdir -p "$extract_dir"
	(
		cd "$extract_dir"
		dpkg-source -x "$dsc_file"
	)
fi

printf 'extracted_dir=%s\n' "$extract_dir"