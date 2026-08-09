#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 <vm-number>" >&2
    exit 1
fi

VM_NUM="$1"
SUBNET=$((VM_NUM - 1))
VM_ID="$(printf 'vm-%03d' "$VM_NUM")"
TAP_DEV="tap-qemu-${SUBNET}"
TAP_IP="172.16.${SUBNET}.1"
TAP_CIDR="172.16.${SUBNET}.0/30"
GUEST_IP="172.16.${SUBNET}.2"
MAC="$(printf '06:00:AC:20:%02X:02' "$SUBNET")"
QMP_SOCKET="/tmp/qemu-metadata-${VM_NUM}.qmp"
PIDFILE="$SCRIPT_DIR/qemu-${VM_NUM}.pid"
LOGFILE="$SCRIPT_DIR/qemu-${VM_NUM}.log"
CONSOLE_LOG="$SCRIPT_DIR/qemu-${VM_NUM}-console.log"
QEMU_NETWORK_STATE="$SCRIPT_DIR/qemu-${VM_NUM}.network"
WORK_DIR="$SCRIPT_DIR/work"
ROOTFS_SRC="$(qemu_find_rootfs)"
ROOTFS="$WORK_DIR/rootfs-${VM_NUM}.ext4"
export TAP_DEV TAP_IP TAP_CIDR GUEST_IP MAC QMP_SOCKET PIDFILE LOGFILE \
    CONSOLE_LOG QEMU_NETWORK_STATE ROOTFS

mkdir -p "$WORK_DIR"
if [ ! -f "$ROOTFS" ]; then
    cp "$ROOTFS_SRC" "$ROOTFS"
fi

qemu_setup_tap metadata
qemu_start_vm "$(qemu_kernel_boot_args rw)" off
qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo
echo "$VM_ID started on $GUEST_IP ($TAP_DEV)"
echo "SSH: ssh -i $(qemu_find_ssh_key) root@$GUEST_IP"
echo "Stop: $SCRIPT_DIR/stop-multi.sh $VM_NUM"
