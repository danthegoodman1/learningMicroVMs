#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${VM_ID:=vm-001}"
: "${METADATA_IP:=169.254.169.254}"

qemu_setup_tap metadata
qemu_start_vm "$(qemu_kernel_boot_args rw)" off
qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo
echo "========================================"
echo "QEMU VM '$VM_ID' started"
echo "========================================"
echo "VM IP: $GUEST_IP"
echo "Metadata: http://$METADATA_IP/"
echo "Start the server in another terminal: $SCRIPT_DIR/metadata-server.sh"
echo "SSH: ssh -i $(qemu_find_ssh_key) root@$GUEST_IP"
