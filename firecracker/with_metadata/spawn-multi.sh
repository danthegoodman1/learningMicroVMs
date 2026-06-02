#!/usr/bin/env bash
# Spawn a Firecracker VM with a unique identity
#
# Usage: ./spawn-multi.sh <vm-number>
# Example: ./spawn-multi.sh 1   # Creates vm-001 on tap0, 172.16.0.2
#          ./spawn-multi.sh 2   # Creates vm-002 on tap1, 172.16.1.2
#
# Each VM gets its own:
#   - tap interface (tap0, tap1, ...)
#   - IP subnet (172.16.0.x, 172.16.1.x, ...)
#   - API socket (/tmp/firecracker-N.socket)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

if [ -z "$1" ]; then
    echo "Usage: $0 <vm-number>"
    echo "Example: $0 1"
    exit 1
fi

VM_NUM="$1"
VM_ID=$(printf "vm-%03d" "$VM_NUM")

# --- Network Configuration (unique per VM) ---
TAP_DEV="tap$((VM_NUM - 1))"
TAP_IP="172.16.$((VM_NUM - 1)).1"
FC_IP="172.16.$((VM_NUM - 1)).2"
MASK_SHORT="/30"
MASK_LONG="255.255.255.0"

# MAC address derived from VM number
FC_MAC=$(printf "06:00:AC:10:%02X:02" "$((VM_NUM - 1))")

# Firecracker socket (unique per VM)
API_SOCKET="${API_SOCKET:-/tmp/firecracker-${VM_NUM}.socket}"

# Metadata IP (shared across all VMs)
METADATA_IP="169.254.169.254"

echo "========================================"
echo "Spawning $VM_ID"
echo "========================================"
echo "  TAP: $TAP_DEV ($TAP_IP)"
echo "  VM:  $FC_IP (MAC: $FC_MAC)"
echo "  API: $API_SOCKET"
echo ""

# --- Check if firecracker is running ---
if [ ! -S "$API_SOCKET" ]; then
    echo "Error: Firecracker socket not found at $API_SOCKET"
    echo ""
    echo "Start firecracker first:"
    echo "  sudo $(fc_find_firecracker) --api-sock $API_SOCKET"
    exit 1
fi

# --- Setup network interface ---
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"

# Add metadata IP to this tap (if not already added to another tap)
if ! ip addr show | grep -q "$METADATA_IP"; then
    sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"
fi

sudo ip link set dev "$TAP_DEV" up

# Enable ip forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# --- Detect host interface for NAT ---
HOST_IFACE="$(fc_host_iface)"
echo "Using host interface: $HOST_IFACE"

# --- Set up NAT (only needs to be done once, but idempotent) ---
if ! sudo iptables -t nat -C POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
fi

# Add forwarding rules for this tap
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT

# --- Firecracker API setup ---
LOGFILE="${LOGFILE:-$SCRIPT_DIR/firecracker-${VM_NUM}.log}"
touch "$LOGFILE"

fc_api_put "logger" "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }"

# --- Kernel configuration ---
KERNEL="$(fc_find_kernel)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ip=${FC_IP}::${TAP_IP}:${MASK_LONG}::eth0:off"

ARCH=$(uname -m)
if [ ${ARCH} = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

fc_api_put "boot-source" "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }"

# --- Root filesystem (use a copy for each VM for isolation) ---
ROOTFS="$(fc_find_rootfs)"

fc_api_put "drives/rootfs" "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

# --- Network interface ---
fc_api_put "network-interfaces/eth0" "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }"

sleep 0.015s

# --- Start microVM ---
fc_api_put "actions" "{
        \"action_type\": \"InstanceStart\"
    }"

sleep 5s
fc_configure_guest_network "$FC_IP" "$TAP_IP"

echo ""
echo "$VM_ID started!"
echo ""
echo "SSH:      ssh -i $(fc_find_ssh_key) root@$FC_IP"
echo "Metadata: curl http://169.254.169.254/instance-id (from inside VM)"
echo ""
echo "Don't forget to add this VM to metadata-server.sh:"
echo "  \"$FC_IP\": {\"instance-id\": \"$VM_ID\", \"local-ipv4\": \"$FC_IP\", ...}"
echo ""
