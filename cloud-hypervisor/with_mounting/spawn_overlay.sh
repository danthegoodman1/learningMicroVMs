#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${OVERLAY_MODE:=tmpfs}"

ch_setup_tap

extra_disks=()
if [ "$OVERLAY_MODE" = "persistent" ]; then
    if [ -z "${OVERLAY_IMG:-}" ]; then
        echo "Error: set OVERLAY_IMG when OVERLAY_MODE=persistent" >&2
        exit 1
    fi
    if [ ! -f "$OVERLAY_IMG" ]; then
        echo "Error: overlay image does not exist: $OVERLAY_IMG" >&2
        exit 1
    fi
    echo "Using persistent overlay: $OVERLAY_IMG"
    extra_disks+=("path=${OVERLAY_IMG},readonly=off")
elif [ "$OVERLAY_MODE" = "tmpfs" ]; then
    echo "Using tmpfs overlay (ephemeral, changes lost on reboot)"
else
    echo "Error: OVERLAY_MODE must be tmpfs or persistent" >&2
    exit 1
fi

if [ -n "${DATA_IMG:-}" ]; then
    if [ ! -f "$DATA_IMG" ]; then
        echo "Error: data image does not exist: $DATA_IMG" >&2
        exit 1
    fi
    echo "Adding read-only data drive: $DATA_IMG"
    extra_disks+=("path=${DATA_IMG},readonly=on")
fi

BOOT_ARGS="$(ch_kernel_boot_args ro "init=/overlay-init.sh")"
ch_start_vm "$BOOT_ARGS" on "${extra_disks[@]}"

sleep 5
ch_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo ""
echo "=========================================="
echo "Cloud Hypervisor VM started with overlay mode: $OVERLAY_MODE"
if [ "$OVERLAY_MODE" = "tmpfs" ]; then
    echo "All rootfs changes will be lost on reboot."
else
    echo "Rootfs changes persist to: $OVERLAY_IMG"
fi
echo "=========================================="
echo ""
echo "SSH into VM:"
echo "  ssh -i $(ch_find_ssh_key) root@$GUEST_IP"
echo ""
