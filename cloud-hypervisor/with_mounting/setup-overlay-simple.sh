#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rootfs.ext4>"
    echo ""
    echo "This creates /overlay-init.sh in the rootfs."
    exit 1
fi

ROOTFS="$1"
MOUNT_POINT="/tmp/ch_rootfs_mount_$$"

if [ ! -f "$ROOTFS" ]; then
    echo "Error: rootfs does not exist: $ROOTFS" >&2
    exit 1
fi

cleanup() {
    if mountpoint -q "$MOUNT_POINT"; then
        sudo umount "$MOUNT_POINT"
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

echo "Mounting rootfs..."
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

echo "Creating overlay init script..."
sudo tee "$MOUNT_POINT/overlay-init.sh" > /dev/null <<'EOF'
#!/bin/sh

echo "=== Starting overlay init ==="

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

mount --make-rprivate /
mount -t tmpfs -o size=2G tmpfs /run
STAGING="/run/overlay-root"
mkdir -p "$STAGING/merged"

if [ -b /dev/vdb ]; then
    echo "Using persistent overlay on /dev/vdb"
    mkdir -p "$STAGING/persistent"
    mount /dev/vdb "$STAGING/persistent"
    mkdir -p "$STAGING/persistent/data" "$STAGING/persistent/work"
    UPPER="$STAGING/persistent/data"
    WORK="$STAGING/persistent/work"
    DATA_DEVICE="/dev/vdc"
else
    echo "Using tmpfs overlay (ephemeral)"
    mkdir -p "$STAGING/upper" "$STAGING/work"
    UPPER="$STAGING/upper"
    WORK="$STAGING/work"
    DATA_DEVICE="/dev/vdb"
fi

mount -t overlay overlay -o lowerdir=/,upperdir=$UPPER,workdir=$WORK "$STAGING/merged"

mkdir -p "$STAGING/merged/.old_root"
pivot_root "$STAGING/merged" "$STAGING/merged/.old_root"

mount --move /.old_root/proc /proc 2>/dev/null || mount -t proc proc /proc
mount --move /.old_root/sys /sys 2>/dev/null || mount -t sysfs sysfs /sys
mount --move /.old_root/dev /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev

if [ -b "$DATA_DEVICE" ]; then
    echo "=== Found data drive at $DATA_DEVICE, mounting at /mnt/data ==="
    mkdir -p /mnt/data
    mount -o ro "$DATA_DEVICE" /mnt/data && echo "Mounted $DATA_DEVICE at /mnt/data (read-only)"
fi

echo "=== Overlay setup complete, starting real init ==="
exec /sbin/init "$@"
EOF

sudo chmod +x "$MOUNT_POINT/overlay-init.sh"

echo "Unmounting rootfs..."
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
trap - EXIT

echo ""
echo "Done. Created /overlay-init.sh in $ROOTFS"
