#!/bin/bash
# This example creates a sandboxed network that can:
# 1. Access the internet
# 2. Access a metadata service API on the host (e.g., hypervisor metadata)
# 3. NOT access any other local services on the host or private networks

set -e

# --- Configuration variables ---
NS_NAME="bwrap-net"
VETH_HOST="veth-host"
VETH_SANDBOX="veth-sandbox"
HOST_IP="192.168.100.1"
HOST_CIDR="192.168.100.1/24"
SANDBOX_IP="192.168.100.2/24"
GATEWAY="192.168.100.1"

# Metadata service configuration - the sandbox can reach this endpoint
METADATA_PORT="8080"  # Port where metadata service listens on host

# --- Determine external interface for NAT ---
EXT_IF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$EXT_IF" ]; then
    echo "Could not determine external interface; please set EXT_IF manually."
    exit 1
fi

echo "Using external interface: $EXT_IF"

# --- Create the persistent network namespace ---
sudo ip netns add "$NS_NAME"

# --- Create the veth pair ---
sudo ip link add "$VETH_HOST" type veth peer name "$VETH_SANDBOX"

# --- Move one end into the namespace ---
sudo ip link set "$VETH_SANDBOX" netns "$NS_NAME"

# --- Configure host-side interface ---
sudo ip addr add "$HOST_CIDR" dev "$VETH_HOST"
sudo ip link set "$VETH_HOST" up

# --- Configure sandbox-side interface inside the network namespace ---
sudo ip netns exec "$NS_NAME" ip addr add "$SANDBOX_IP" dev "$VETH_SANDBOX"
sudo ip netns exec "$NS_NAME" ip link set "$VETH_SANDBOX" up
sudo ip netns exec "$NS_NAME" ip link set lo up
sudo ip netns exec "$NS_NAME" ip route add default via "$GATEWAY"

# --- Enable IP forwarding ---
sudo sysctl -w net.ipv4.ip_forward=1

# --- Set up NAT for internet access ---
sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$EXT_IF" -j MASQUERADE

# --- Firewall rules (default deny, explicit allow) ---

# INPUT chain: traffic destined for the host itself
# Allow: metadata service on the configured port
sudo iptables -A INPUT -i "$VETH_HOST" -p tcp --dport "$METADATA_PORT" -j ACCEPT
# Drop: everything else from sandbox to host
sudo iptables -A INPUT -i "$VETH_HOST" -j DROP

# FORWARD chain: traffic being routed through the host
# Allow: return traffic for established connections
sudo iptables -A FORWARD -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow: new outbound connections to the internet (via external interface only)
sudo iptables -A FORWARD -i "$VETH_HOST" -o "$EXT_IF" -j ACCEPT
# Drop: everything else (local networks, other interfaces, etc.)
sudo iptables -A FORWARD -i "$VETH_HOST" -j DROP

echo ""
echo "========================================"
echo "Network namespace '$NS_NAME' configured."
echo "========================================"
echo ""
echo "The sandbox can:"
echo "  - Access the internet (try: curl https://1.1.1.1)"
echo "  - Access the metadata service at $HOST_IP:$METADATA_PORT"
echo ""
echo "The sandbox CANNOT:"
echo "  - Access other services on the host"
echo "  - Access private networks (10.x, 172.16-31.x, 192.168.x)"
echo ""
echo "To test, start a metadata service on the host:"
echo "  python3 -m http.server $METADATA_PORT --bind $HOST_IP"
echo ""
echo "Then from inside the sandbox:"
echo "  curl http://$HOST_IP:$METADATA_PORT/"
echo ""

# --- Launch bubblewrap inside the preconfigured network namespace ---
sudo ip netns exec "$NS_NAME" bwrap --new-session \
    --unshare-pid \
    --unshare-uts \
    --unshare-ipc \
    --share-net \
    --chdir / \
    --ro-bind /bin /bin \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /sbin /sbin \
    --ro-bind /etc /etc \
    --proc /proc \
    /bin/bash

# --- Cleanup ---
echo ""
echo "Cleaning up..."

# Remove iptables rules (in reverse order)
sudo iptables -D FORWARD -i "$VETH_HOST" -j DROP 2>/dev/null || true
sudo iptables -D FORWARD -i "$VETH_HOST" -o "$EXT_IF" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
sudo iptables -D INPUT -i "$VETH_HOST" -j DROP 2>/dev/null || true
sudo iptables -D INPUT -i "$VETH_HOST" -p tcp --dport "$METADATA_PORT" -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 192.168.100.0/24 -o "$EXT_IF" -j MASQUERADE 2>/dev/null || true

# Delete namespace (this also removes the veth pair)
sudo ip netns delete "$NS_NAME" 2>/dev/null || true

echo "Cleanup complete."
