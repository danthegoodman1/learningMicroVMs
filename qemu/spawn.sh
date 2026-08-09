#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

qemu_setup_tap
qemu_start_vm "$(qemu_kernel_boot_args rw)" off
qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo
echo "========================================"
echo "QEMU microVM started"
echo "========================================"
echo "VM IP: $GUEST_IP"
echo "SSH: ssh -i $(qemu_find_ssh_key) root@$GUEST_IP"
echo "Stop: $SCRIPT_DIR/stop.sh"
