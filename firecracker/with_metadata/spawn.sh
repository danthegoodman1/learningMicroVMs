#!/usr/bin/env bash
# Firecracker VM spawn script with metadata service support
#
# The VM can access a metadata service at 169.254.169.254:80
# similar to AWS EC2's instance metadata service.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# --- VM Identity (change this per VM instance) ---
VM_ID="${VM_ID:-vm-001}"

# --- Network Configuration ---
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
FC_IP="172.16.0.2"
MASK_SHORT="/30"
MASK_LONG="255.255.255.0"

# Metadata service IP (classic AWS-style link-local address)
METADATA_IP="169.254.169.254"
METADATA_PORT="80"

# --- Setup network interface ---
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"

# Add the metadata IP to the tap interface
# This makes 169.254.169.254 reachable from the VM via the tap
sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"

sudo ip link set dev "$TAP_DEV" up

# Enable ip forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# --- Detect host interface for NAT ---
HOST_IFACE="$(fc_host_iface)"
echo "Using host interface: $HOST_IFACE"

# --- Set up NAT for internet access ---
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT

# --- Firecracker API setup ---
API_SOCKET="${API_SOCKET:-/tmp/firecracker.socket}"
LOGFILE="${LOGFILE:-$SCRIPT_DIR/firecracker.log}"

touch $LOGFILE

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

# --- Root filesystem ---
ROOTFS="$(fc_find_rootfs)"

fc_api_put "drives/rootfs" "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

# --- Network interface ---
FC_MAC="06:00:AC:10:00:02"

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
echo "========================================"
echo "VM '$VM_ID' started"
echo "========================================"
echo ""
echo "Network:"
echo "  VM IP: $FC_IP"
echo "  Gateway: $TAP_IP"
echo "  Metadata: http://$METADATA_IP/"
echo ""
echo "Start the metadata service (in another terminal):"
echo "  ./metadata-server.sh"
echo ""
echo "From inside the VM, test with:"
echo "  curl http://$METADATA_IP/"
echo "  curl http://$METADATA_IP/instance-id"
echo ""
echo "SSH into VM:"
echo "  ssh -i $(fc_find_ssh_key) root@$FC_IP"
echo ""
