# This example prepares a network namespace with a veth pair and a NAT rule.
# It then launches bubblewrap inside the namespace with the preconfigured network so that the sandbox can access the internet but not the host, and can also listen such that the host can connect to it.

#!/bin/bash
set -e

# --- Configuration variables ---
NS_NAME="bwrap-net"
VETH_HOST="veth-host"
VETH_SANDBOX="veth-sandbox"
HOST_IP="192.168.1.1/24"
SANDBOX_IP="192.168.1.2/24"
GATEWAY="192.168.1.1"

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
sudo ip addr add "$HOST_IP" dev "$VETH_HOST"
sudo ip link set "$VETH_HOST" up

# --- Configure sandbox-side interface inside the network namespace ---
sudo ip netns exec "$NS_NAME" ip addr add "$SANDBOX_IP" dev "$VETH_SANDBOX"
sudo ip netns exec "$NS_NAME" ip link set "$VETH_SANDBOX" up
sudo ip netns exec "$NS_NAME" ip link set lo up
sudo ip netns exec "$NS_NAME" ip route add default via "$GATEWAY"

# --- Enable IP forwarding and set up NAT ---
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o "$EXT_IF" -j MASQUERADE

echo "Network namespace '$NS_NAME' and veth interfaces configured."
echo "Launching bubblewrap in namespace '$NS_NAME'. Type 'curl 1.1.1.1' inside the shell to test connectivity."
echo "Type 'exit' to quit the bubblewrap shell."

# --- Launch bubblewrap inside the preconfigured network namespace ---
# We do NOT unshare the network namespace (i.e. we use --share-net) so that the preconfiguration is preserved.
# sudo ip netns exec "$NS_NAME" bwrap \
#   --unshare-pid \
#   --unshare-uts \
#   --unshare-ipc \
#   --share-net \
#   --chdir / \
#   --ro-bind /usr /usr \
#   --ro-bind /lib /lib \
#   --proc /proc \
#   bash

# this works too
sudo ip netns exec "$NS_NAME" bwrap --new-session --dev-bind / / --share-net bash

# Optionally, when done, you can clean up:
# sudo ip netns delete "$NS_NAME"
# sudo ip link delete "$VETH_HOST" # this will likely be not found since the ns is deleted
