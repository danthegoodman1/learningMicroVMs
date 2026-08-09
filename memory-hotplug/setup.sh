#!/usr/bin/env bash

set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEMO_DIR/.." && pwd)"
ARCH="$(uname -m)"
FC_CI_VERSION="${FC_CI_VERSION:-v1.14}"
FC_KERNEL_VERSION="${FC_KERNEL_VERSION:-6.1.155}"
FC_KERNEL="$REPO_ROOT/firecracker/vmlinux-${FC_KERNEL_VERSION}"
FC_KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${FC_CI_VERSION}/${ARCH}/vmlinux-${FC_KERNEL_VERSION}"

(cd "$REPO_ROOT/firecracker" && ./dl_reqs.sh)
(cd "$REPO_ROOT/cloud-hypervisor" && ./dl_reqs.sh)

if [ ! -f "$FC_KERNEL" ]; then
    echo "Downloading Firecracker's virtio-mem-enabled ${FC_KERNEL_VERSION} guest kernel..."
    curl -fL --retry 3 --retry-delay 2 \
        -o "${FC_KERNEL}.tmp" "$FC_KERNEL_URL"
    mv "${FC_KERNEL}.tmp" "$FC_KERNEL"
    chmod 600 "$FC_KERNEL"
else
    echo "Using existing $FC_KERNEL"
fi

echo
echo "Memory hotplug demo assets are ready."
echo "Run either:"
echo "  $DEMO_DIR/firecracker.sh"
echo "  $DEMO_DIR/cloud-hypervisor.sh"
echo "  $DEMO_DIR/qemu.sh"
