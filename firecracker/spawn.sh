#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"

# Setup network interface
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up

# Enable ip forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

HOST_IFACE="$(fc_host_iface)"
echo "Using host interface: $HOST_IFACE"

# Set up microVM internet access
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
    || true
sudo iptables -D FORWARD -i tap0 -o "$HOST_IFACE" -j ACCEPT || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i tap0 -o "$HOST_IFACE" -j ACCEPT

API_SOCKET="${API_SOCKET:-/tmp/firecracker.socket}"
LOGFILE="${LOGFILE:-$SCRIPT_DIR/firecracker.log}"

# Create a root-owned log file. Firecracker v1.16 runs with reduced
# capabilities, so the API logger cannot open a user-owned 0600 file.
fc_prepare_logfile "$LOGFILE"

# Set log file
fc_api_put "logger" "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }"

KERNEL="$(fc_find_kernel)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"

FC_IP="172.16.0.2"
MASK_LONG="255.255.255.0"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ip=${FC_IP}::${TAP_IP}:${MASK_LONG}::eth0:off"

ARCH=$(uname -m)

if [ ${ARCH} = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

# Set boot source
fc_api_put "boot-source" "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }"

# apparently this could also be a .cpio https://www.gnu.org/software/cpio/manual/html_node/Tutorial.html#Tutorial
ROOTFS="$(fc_find_rootfs)"

# Set rootfs
fc_api_put "drives/rootfs" "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

# The IP address of a guest is derived from its MAC address with
# `fcnet-setup.sh`, this has been pre-configured in the guest rootfs. It is
# important that `TAP_IP` and `FC_MAC` match this.
FC_MAC="06:00:AC:10:00:02"

# Set network interface
fc_api_put "network-interfaces/eth0" "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }"

# API requests are handled asynchronously, it is important the configuration is
# set, before `InstanceStart`.
sleep 0.015s

# Start microVM
fc_api_put "actions" "{
        \"action_type\": \"InstanceStart\"
    }"

# API requests are handled asynchronously, it is important the microVM has been
# started before we attempt to SSH into it.
sleep 5s
fc_configure_guest_network "$FC_IP" "$TAP_IP"

# SSH into the microVM
# ssh -i "$(fc_find_ssh_key)" root@172.16.0.2
