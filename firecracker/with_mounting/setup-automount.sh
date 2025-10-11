#!/bin/bash
# This script modifies a rootfs to auto-mount a secondary drive at /mnt/somedir

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rootfs.ext4>"
    echo "This will modify the rootfs to automatically mount /dev/vdb at /mnt/somedir on boot"
    exit 1
fi

ROOTFS="$1"
MOUNT_POINT="/tmp/rootfs_mount_$$"

echo "Mounting rootfs..."
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

echo "Creating mount directory..."
sudo mkdir -p "$MOUNT_POINT/mnt/somedir"

echo "Adding fstab entry..."
# Check if entry already exists
if ! sudo grep -q "/dev/vdb" "$MOUNT_POINT/etc/fstab" 2>/dev/null; then
    echo "/dev/vdb  /mnt/somedir  ext4  defaults,nofail  0  2" | sudo tee -a "$MOUNT_POINT/etc/fstab"
    echo "✓ Added /dev/vdb to /etc/fstab"
else
    echo "✓ /dev/vdb entry already exists in /etc/fstab"
fi

echo "Unmounting rootfs..."
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo ""
echo "Done! Your rootfs will now automatically mount /dev/vdb at /mnt/somedir on boot."
echo "Run with: MOUNT_IMG=./data.ext4 ./spawn_with_mount.sh"
