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
TAP_DEV="tap-qemu-${SUBNET}"
TAP_IP="172.16.${SUBNET}.1"
TAP_CIDR="172.16.${SUBNET}.0/30"
QMP_SOCKET="/tmp/qemu-metadata-${VM_NUM}.qmp"
PIDFILE="$SCRIPT_DIR/qemu-${VM_NUM}.pid"
QEMU_NETWORK_STATE="$SCRIPT_DIR/qemu-${VM_NUM}.network"
export TAP_DEV TAP_IP TAP_CIDR QMP_SOCKET PIDFILE QEMU_NETWORK_STATE

qemu_cleanup
echo "Stopped QEMU metadata VM $VM_NUM."
