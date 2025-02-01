#!/bin/bash
set -e

# --- Configuration variables ---
NS_NAME="bwrap-net"
VETH_HOST="veth-host"
VETH_SANDBOX="veth-sandbox"
HOST_IP="192.168.1.1/24"
SANDBOX_IP="192.168.1.2/24"
GATEWAY="192.168.1.1"
CGROUP_UNIT="my-cgroup-name"

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
echo "Launching bubblewrap in namespace '$NS_NAME' with resource limits."
echo "Inside the bubblewrap shell, you should be able to run 'curl 1.1.1.1' to test Internet connectivity."
echo "Type 'exit' to quit the shell."

# --- Launch bubblewrap with systemd-run resource limits ---
# We run bubblewrap inside the preconfigured namespace (via 'ip netns exec')
# and use systemd-run --scope to apply cgroup limits.
# 1% to show that limiting works (will be super slow)
sudo ip netns exec "$NS_NAME" systemd-run --scope \
  -p "Delegate=yes" \
  -p "MemoryLimit=500M" \
  -p "CPUQuota=1%" \
  --unit="$CGROUP_UNIT" \
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

# This works too
# sudo ip netns exec "$NS_NAME" systemd-run --scope \
#   -p "Delegate=yes" \
#   -p "MemoryLimit=500M" \
#   -p "CPUQuota=1%" \
#   --unit="$CGROUP_UNIT" \
#   sudo ip netns exec "$NS_NAME" bwrap --new-session --dev-bind / / --share-net bash

# --- Cleanup instructions (optional) ---
# When finished, you can remove the namespace and veth interface with:
sudo ip netns delete "$NS_NAME"
