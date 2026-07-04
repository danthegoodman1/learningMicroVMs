#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# This script boots a Firecracker VM with an overlay filesystem for security
# Base rootfs is read-only, changes go to overlay (tmpfs or persistent disk)

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
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off init=/overlay-init.sh"

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

ROOTFS="$(fc_find_rootfs)"

# Set rootfs as READ-ONLY for security
fc_api_put "drives/rootfs" "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": true
    }"

# OVERLAY_MODE can be: "tmpfs" (ephemeral, in-memory) or "persistent" (disk-backed)
# Default to tmpfs for maximum security
OVERLAY_MODE="${OVERLAY_MODE:-tmpfs}"

if [ "${OVERLAY_MODE}" = "persistent" ] && [ -n "${OVERLAY_IMG}" ]; then
    echo "Using persistent overlay: ${OVERLAY_IMG}"
    fc_api_put "drives/overlay" "{
            \"drive_id\": \"overlay\",
            \"path_on_host\": \"${OVERLAY_IMG}\",
            \"is_root_device\": false,
            \"is_read_only\": false
        }"
else
    echo "Using tmpfs overlay (ephemeral, changes lost on reboot)"
    OVERLAY_MODE="tmpfs"
fi

# Optional: Add an extra data drive to mount at /mnt/data (or wherever you want)
# Set DATA_IMG to mount an additional drive (will be /dev/vdb with tmpfs, or /dev/vdc with persistent overlay)
if [ -n "${DATA_IMG:-}" ]; then
    if [ "${OVERLAY_MODE}" = "tmpfs" ]; then
        DRIVE_DEVICE="vdb"
    else
        DRIVE_DEVICE="vdc"
    fi
    echo "Adding data drive: ${DATA_IMG} (will appear as /dev/${DRIVE_DEVICE})"
    fc_api_put "drives/data" "{
            \"drive_id\": \"data\",
            \"path_on_host\": \"${DATA_IMG}\",
            \"is_root_device\": false,
            \"is_read_only\": true
        }"
fi

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

echo ""
echo "=========================================="
echo "Firecracker VM started with overlay mode: ${OVERLAY_MODE}"
if [ "${OVERLAY_MODE}" = "tmpfs" ]; then
    echo "⚠️  All changes will be LOST on reboot (ephemeral)"
else
    echo "💾 Changes will persist to: ${OVERLAY_IMG}"
fi
echo "=========================================="
echo ""

# SSH into the microVM
# ssh -i ./ubuntu-22.04.id_rsa root@172.16.0.2

# ===== USAGE INSTRUCTIONS =====
#
# EPHEMERAL MODE (default, most secure for untrusted users):
#   ./spawn_overlay.sh
#   - Rootfs is read-only
#   - All changes stored in RAM (tmpfs)
#   - Everything resets on reboot
#
# PERSISTENT MODE (if you need to keep some data):
#   OVERLAY_MODE=persistent OVERLAY_IMG=./overlay.ext4 ./spawn_overlay.sh
#   - Rootfs is read-only
#   - Changes stored on disk
#   - Persists across reboots
#
# WITH EXTRA DATA DRIVE:
#   DATA_IMG=./data.ext4 ./spawn_overlay.sh
#   - Automatically mounts at /mnt/data inside the VM
#   - Uses /dev/vdb (tmpfs mode) or /dev/vdc (persistent mode)
#   - Use for separate data volumes that persist independently
#
# SECURITY BENEFITS:
# - Base system cannot be modified permanently
# - Easy to reset: just reboot (tmpfs) or delete overlay disk
# - No way for untrusted user to persist malware in base system
# - Fast rollback to clean state
