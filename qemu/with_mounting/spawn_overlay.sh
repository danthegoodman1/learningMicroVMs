#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${OVERLAY_MODE:=tmpfs}"

extra_args=()
if [ "$OVERLAY_MODE" = persistent ]; then
    if [ -z "${OVERLAY_IMG:-}" ] || [ ! -f "$OVERLAY_IMG" ]; then
        echo "Error: set OVERLAY_IMG to an existing image for persistent mode." >&2
        exit 1
    fi
    extra_args+=(
        -drive "file=${OVERLAY_IMG},format=raw,if=none,id=overlay,cache=none"
        -device "virtio-blk-device,drive=overlay"
    )
elif [ "$OVERLAY_MODE" != tmpfs ]; then
    echo "Error: OVERLAY_MODE must be tmpfs or persistent." >&2
    exit 1
fi

if [ -n "${DATA_IMG:-}" ]; then
    [ -f "$DATA_IMG" ] || { echo "Error: data image does not exist: $DATA_IMG" >&2; exit 1; }
    extra_args+=(
        -drive "file=${DATA_IMG},format=raw,if=none,id=data,readonly=on,cache=none"
        -device "virtio-blk-device,drive=data"
    )
fi

qemu_setup_tap
qemu_start_vm "$(qemu_kernel_boot_args ro 'init=/overlay-init.sh')" on "${extra_args[@]}"
qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo
echo "QEMU overlay VM started in $OVERLAY_MODE mode."
echo "SSH: ssh -i $(qemu_find_ssh_key) root@$GUEST_IP"
echo "Stop: $SCRIPT_DIR/../stop.sh"
