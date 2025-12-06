#!/bin/bash
# This example creates a sandboxed network that can:
# 1. Access the internet
# 2. Access a metadata service API on the host (e.g., hypervisor metadata)
# 3. NOT access any other local services on the host or private networks
#
# Uses nftables instead of iptables for cleaner rule management.

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

# nftables table name (makes cleanup easy - just delete the whole table)
NFT_TABLE="sandbox_filter"

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

# --- Set up nftables rules ---
# All rules go in a dedicated table for easy cleanup
sudo nft -f - <<EOF
table ip $NFT_TABLE {
    # NAT chain for internet access
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 192.168.100.0/24 oifname "$EXT_IF" masquerade
    }

    # Filter traffic TO the host (input)
    chain input {
        type filter hook input priority filter; policy accept;

        # Only process traffic from the sandbox interface
        iifname != "$VETH_HOST" accept

        # Allow metadata service
        tcp dport $METADATA_PORT accept

        # Drop everything else from sandbox
        drop
    }

    # Filter forwarded traffic (through the host)
    chain forward {
        type filter hook forward priority filter; policy accept;

        # Allow return traffic to sandbox
        oifname "$VETH_HOST" ct state established,related accept

        # Allow sandbox -> internet (external interface only)
        iifname "$VETH_HOST" oifname "$EXT_IF" accept

        # Drop all other traffic from sandbox
        iifname "$VETH_HOST" drop
    }
}
EOF

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
echo "View active rules: sudo nft list table ip $NFT_TABLE"
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

# Delete the entire nftables table (removes all rules at once)
sudo nft delete table ip "$NFT_TABLE" 2>/dev/null || true

# Delete namespace (this also removes the veth pair)
sudo ip netns delete "$NS_NAME" 2>/dev/null || true

echo "Cleanup complete."
