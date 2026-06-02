#!/usr/bin/env bash

set -euo pipefail

ARCH="$(uname -m)"
FC_VERSION="${FC_VERSION:-v1.9.0}"
CI_VERSION="${CI_VERSION:-v1.9}"
RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"

latest_kernel="$(wget "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-5.10&list-type=2" -O - 2>/dev/null \
    | grep "(?<=<Key>)(firecracker-ci/${CI_VERSION}/${ARCH}/vmlinux-5\.10\.[0-9]{3})(?=</Key>)" -o -P \
    | sort -V \
    | tail -n 1)"

if [ -z "$latest_kernel" ]; then
    echo "Error: could not find a ${CI_VERSION} vmlinux-5.10 kernel for ${ARCH}" >&2
    exit 1
fi

# Download a linux kernel binary
wget -N "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel}"

# Download a rootfs
wget -N "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-22.04.ext4"

# Download the ssh key for the rootfs
wget -N "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${CI_VERSION}/${ARCH}/ubuntu-22.04.id_rsa"

# Set user read permission on the ssh key
chmod 400 ./ubuntu-22.04.id_rsa

# Download and unpack the Firecracker binary if it is not already present
if [ ! -x ./firecracker ]; then
    wget -N "${RELEASE_URL}/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"
    tar -xzf "firecracker-${FC_VERSION}-${ARCH}.tgz"
    cp "release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" ./firecracker
    chmod +x ./firecracker
fi
