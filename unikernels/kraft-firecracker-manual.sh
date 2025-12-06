#!/bin/bash
# Launch a Unikraft unikernel with Firecracker directly (no kraft CLI)
#
# Use this if you want more control or don't have kraft installed.
# Requires a pre-built unikernel binary compiled for Firecracker (fc-x86_64).
#
# Prerequisites:
#   - firecracker binary in PATH
#   - A unikernel binary (e.g., built with kraft build --plat fc)
#
# Usage: sudo ./kraft-firecracker-manual.sh [unikernel_binary]

set -e

# --- Configuration ---
UNIKERNEL="${1:-./app/.unikraft/build/app_fc-x86_64}"
VM_ID="${VM_ID:-uk-001}"

# Network settings
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
UK_IP="172.16.0.2"
UK_MAC="06:00:AC:10:00:02"
MASK="/30"
MASK_LONG="255.255.255.252"
METADATA_IP="169.254.169.254"

# Firecracker settings
API_SOCKET="/tmp/firecracker-uk.socket"
LOGFILE="./firecracker-uk.log"

# --- Validation ---
if [ ! -f "$UNIKERNEL" ]; then
    echo "Error: Unikernel binary not found: $UNIKERNEL"
    echo ""
    echo "Build one with:"
    echo "  cd app && kraft build --plat fc --arch x86_64"
    echo ""
    echo "Or specify path: $0 /path/to/unikernel"
    exit 1
fi

# --- Cleanup previous run ---
cleanup() {
    echo "Cleaning up..."
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    rm -f "$API_SOCKET"
}
trap cleanup EXIT

# --- Setup network interface ---
echo "Setting up network interface $TAP_DEV..."
sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK}" dev "$TAP_DEV"

# Add metadata IP to tap interface
sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"

sudo ip link set dev "$TAP_DEV" up

# Enable IP forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# --- Detect host interface for NAT ---
HOST_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$HOST_IFACE" ]; then
    HOST_IFACE="eth0"
fi
echo "Using host interface: $HOST_IFACE for NAT"

# --- Set up NAT ---
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true

sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT

# --- Start Firecracker ---
rm -f "$API_SOCKET"
touch "$LOGFILE"

echo "Starting Firecracker..."
sudo firecracker --api-sock "$API_SOCKET" &
FC_PID=$!
sleep 0.5

# --- Configure logging ---
sudo curl -s -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"

# --- Configure boot source ---
# Unikraft uses netdev.ip for network configuration
BOOT_ARGS="console=ttyS0 netdev.ip=${UK_IP}${MASK}:${TAP_IP}"

sudo curl -s -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${UNIKERNEL}\",
        \"boot_args\": \"${BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

# --- Configure network ---
sudo curl -s -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"${UK_MAC}\",
        \"host_dev_name\": \"${TAP_DEV}\"
    }" \
    "http://localhost/network-interfaces/eth0"

# --- Configure machine ---
sudo curl -s -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"vcpu_count\": 1,
        \"mem_size_mib\": 128
    }" \
    "http://localhost/machine-config"

# --- Start the microVM ---
echo ""
echo "========================================"
echo "Starting unikernel '$VM_ID'"
echo "========================================"
echo ""
echo "Network:"
echo "  Unikernel IP: $UK_IP"
echo "  Gateway: $TAP_IP"
echo "  Metadata: http://$METADATA_IP/"
echo ""
echo "Logs: tail -f $LOGFILE"
echo ""

sudo curl -s -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

# Wait for firecracker
wait $FC_PID
