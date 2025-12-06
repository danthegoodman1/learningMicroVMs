#!/bin/bash
# Firecracker VM spawn script with metadata service support
#
# The VM can access a metadata service at 169.254.169.254:80
# similar to AWS EC2's instance metadata service.

set -e

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
HOST_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
if [ -z "$HOST_IFACE" ]; then
    HOST_IFACE="eth0"
    echo "Warning: Could not detect default interface, using $HOST_IFACE"
fi
echo "Using host interface: $HOST_IFACE"

# --- Set up NAT for internet access ---
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT

# --- Firecracker API setup ---
API_SOCKET="/tmp/firecracker.socket"
LOGFILE="./firecracker.log"

touch $LOGFILE

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"

# --- Kernel configuration ---
KERNEL="./vmlinux-5.10.217"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ip=${FC_IP}::${TAP_IP}:${MASK_LONG}::eth0:off"

ARCH=$(uname -m)
if [ ${ARCH} = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

# --- Root filesystem ---
ROOTFS="./rootfs.ext4"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/rootfs"

# --- Network interface ---
FC_MAC="06:00:AC:10:00:02"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }" \
    "http://localhost/network-interfaces/eth0"

sleep 0.015s

# --- Start microVM ---
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

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
echo "  ssh -i ./ubuntu-22.04.id_rsa root@$FC_IP"
echo ""
