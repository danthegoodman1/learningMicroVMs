#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

# CH_VERSION and CH_KERNEL_TAG pin release tags (e.g. v53.0 and
# ch-release-v6.16.9-20260508); unset, the latest releases are used.
CH_VERSION="${CH_VERSION:-}"
CH_KERNEL_TAG="${CH_KERNEL_TAG:-}"

github_asset_url() {
    local repo="$1"
    local asset="$2"
    local tag="${3:-}"
    local release="latest"
    if [ -n "$tag" ]; then
        release="tags/$tag"
    fi

    curl -fsSL "https://api.github.com/repos/${repo}/releases/${release}" \
        | python3 -c '
import json
import sys

asset = sys.argv[1]
release = json.load(sys.stdin)
for candidate in release.get("assets", []):
    if candidate.get("name") == asset:
        print(candidate["browser_download_url"])
        break
else:
    raise SystemExit(f"asset not found: {asset}")
' "$asset"
}

download_if_missing() {
    local url="$1"
    local output="$2"
    local tmp_output="${output}.tmp"

    if [ -e "$output" ]; then
        echo "Using existing $output"
        return
    fi

    echo "Downloading $output"
    rm -f "$tmp_output"
    curl -fL --retry 3 --retry-delay 2 -o "$tmp_output" "$url"
    mv "$tmp_output" "$output"
}

require_cmd curl
require_cmd python3

ARCH="$(uname -m)"
CI_VERSION="${CI_VERSION:-v1.9}"

case "$ARCH" in
    x86_64)
        CH_ASSET="cloud-hypervisor-static"
        CH_REMOTE_ASSET="ch-remote-static"
        KERNEL_ASSET="vmlinux-x86_64"
        KERNEL_OUTPUT="vmlinux-x86_64"
        ;;
    aarch64)
        CH_ASSET="cloud-hypervisor-static-aarch64"
        CH_REMOTE_ASSET="ch-remote-static-aarch64"
        KERNEL_ASSET="Image-arm64"
        KERNEL_OUTPUT="Image-arm64"
        ;;
    *)
        echo "Error: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

# A pinned version replaces binaries of any other version.
if [ -n "$CH_VERSION" ] && [ -x cloud-hypervisor ] \
    && [ "$(./cloud-hypervisor --version | awk 'NR == 1 { print $2 }')" != "$CH_VERSION" ]; then
    rm -f cloud-hypervisor ch-remote
fi
if [ -n "$CH_KERNEL_TAG" ] && [ "$(cat "$KERNEL_OUTPUT.tag" 2>/dev/null)" != "$CH_KERNEL_TAG" ]; then
    rm -f "$KERNEL_OUTPUT"
fi

download_if_missing "$(github_asset_url cloud-hypervisor/cloud-hypervisor "$CH_ASSET" "$CH_VERSION")" cloud-hypervisor
chmod +x cloud-hypervisor

download_if_missing "$(github_asset_url cloud-hypervisor/cloud-hypervisor "$CH_REMOTE_ASSET" "$CH_VERSION")" ch-remote
chmod +x ch-remote

download_if_missing "$(github_asset_url cloud-hypervisor/linux "$KERNEL_ASSET" "$CH_KERNEL_TAG")" "$KERNEL_OUTPUT"
chmod 600 "$KERNEL_OUTPUT"
if [ -n "$CH_KERNEL_TAG" ]; then
    echo "$CH_KERNEL_TAG" > "$KERNEL_OUTPUT.tag"
fi

download_if_missing "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-22.04.ext4" ubuntu-22.04.ext4
download_if_missing "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-22.04.id_rsa" ubuntu-22.04.id_rsa
chmod 400 ubuntu-22.04.id_rsa

echo ""
echo "Cloud Hypervisor requirements are ready."
echo "  Binary: $SCRIPT_DIR/cloud-hypervisor"
echo "  Remote: $SCRIPT_DIR/ch-remote"
echo "  Kernel: $SCRIPT_DIR/$KERNEL_OUTPUT"
echo "  Rootfs: $SCRIPT_DIR/ubuntu-22.04.ext4"
