#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
images_dir="$script_dir/images"
mkdir -p "$images_dir"

image_url="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
image_name="${IMAGE_NAME:-$(basename "$image_url")}"
image_path="$images_dir/$image_name"
download_timeout_sec="${DOWNLOAD_TIMEOUT_SEC:-1800}"

if command -v curl >/dev/null 2>&1; then
	timeout "${download_timeout_sec}s" curl -L --fail --output "$image_path" "$image_url"
elif command -v wget >/dev/null 2>&1; then
	timeout "${download_timeout_sec}s" wget -O "$image_path" "$image_url"
else
	echo "curl or wget is required"
	exit 1
fi

echo "Downloaded guest image to $image_path"