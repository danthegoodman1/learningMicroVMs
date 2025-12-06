#!/bin/bash
# Launch a Kraft unikernel with Firecracker runtime and metadata service access
#
# This script sets up networking so the unikernel can reach:
#   - Internet (via NAT)
#   - Metadata service at 169.254.169.254
#
# Prerequisites:
#   - kraft CLI: curl -sSfL https://get.kraftkit.sh | sh
#   - A kraft project in ./app/ directory (or change APP_DIR)
#
# Usage: sudo ./kraft-firecracker.sh

set -e

# --- Configuration ---
APP_DIR="${APP_DIR:-./app}"
VM_ID="${VM_ID:-uk-001}"

# Network settings
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
UK_IP="172.16.0.2"
MASK="/30"
METADATA_IP="169.254.169.254"

# --- Cleanup previous run ---
cleanup() {
    echo "Cleaning up..."
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

# --- Setup network interface ---
echo "Setting up network interface $TAP_DEV..."
sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK}" dev "$TAP_DEV"

# Add metadata IP to tap interface (makes 169.254.169.254 reachable from unikernel)
sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"

sudo ip link set dev "$TAP_DEV" up

# Enable IP forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# --- Detect host interface for NAT ---
HOST_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$HOST_IFACE" ]; then
    HOST_IFACE="eth0"
    echo "Warning: Could not detect default interface, using $HOST_IFACE"
fi
echo "Using host interface: $HOST_IFACE for NAT"

# --- Set up NAT for internet access ---
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true

sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT

echo ""
echo "========================================"
echo "Launching Kraft unikernel '$VM_ID'"
echo "========================================"
echo ""
echo "Network:"
echo "  Unikernel IP: $UK_IP"
echo "  Gateway: $TAP_IP"
echo "  Metadata: http://$METADATA_IP/"
echo ""
echo "Start the metadata service (in another terminal):"
echo "  sudo ../firecracker/with_metadata/metadata-server.sh"
echo ""

# --- Run the unikernel with Kraft ---
# Network format: <driver>:<ip>/<mask>:<gateway>:<dns1>:<dns2>:<hostname>:<domain>
kraft run \
    --plat fc \
    --arch x86_64 \
    --memory 128M \
    --vcpus 1 \
    --network "bridge:${UK_IP}${MASK}:${TAP_IP}:8.8.8.8::${VM_ID}:local" \
    "$APP_DIR"
