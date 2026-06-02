#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${VM_ID:=vm-001}"
: "${METADATA_IP:=169.254.169.254}"
: "${METADATA_PORT:=80}"

ch_setup_tap metadata

BOOT_ARGS="$(ch_kernel_boot_args rw)"
ch_start_vm "$BOOT_ARGS" off

sleep 5
ch_configure_guest_network "$GUEST_IP" "$TAP_IP"

echo ""
echo "========================================"
echo "Cloud Hypervisor VM '$VM_ID' started"
echo "========================================"
echo ""
echo "Network:"
echo "  VM IP: $GUEST_IP"
echo "  Gateway: $TAP_IP"
echo "  Metadata: http://$METADATA_IP/"
echo ""
echo "Start the metadata service in another terminal:"
echo "  ./metadata-server.sh"
echo ""
echo "From inside the VM, test with:"
echo "  curl http://$METADATA_IP/"
echo "  curl http://$METADATA_IP/instance-id"
echo "  curl http://$METADATA_IP/json"
echo ""
echo "SSH into VM:"
echo "  ssh -i $(ch_find_ssh_key) root@$GUEST_IP"
echo ""
