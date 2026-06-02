#!/bin/bash
# SIMPLER APPROACH: Configure rootfs to be mounted RO with overlay via kernel args
# This approach uses init kernel parameter to run a custom init script

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rootfs.ext4>"
    echo ""
    echo "This creates a custom init script for overlay filesystem."
    echo "Use with spawn_overlay_simple.sh which passes init=/overlay-init.sh"
    exit 1
fi

ROOTFS="$1"
MOUNT_POINT="/tmp/rootfs_mount_$$"

echo "Mounting rootfs..."
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

# Create the overlay init script at root level
echo "Creating overlay init script..."
sudo tee "$MOUNT_POINT/overlay-init.sh" > /dev/null << 'EOF'
#!/bin/sh
# Custom init that sets up overlay then chains to real init

echo "=== Starting overlay init ==="

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Root is already mounted read-only. Use /run as a tmpfs staging area because
# it already exists on the base image and can be mounted over without writing
# to the read-only root.
mount --make-rprivate /
mount -t tmpfs -o size=2G tmpfs /run
STAGING="/run/overlay-root"
mkdir -p "$STAGING/merged"

# Set up upper layer (writable overlay)
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

# Create the overlay
mount -t overlay overlay -o lowerdir=/,upperdir=$UPPER,workdir=$WORK "$STAGING/merged"

# Prepare for pivot
mkdir -p "$STAGING/merged/.old_root"
pivot_root "$STAGING/merged" "$STAGING/merged/.old_root"

# Move essential mounts into the new root. Keep /.old_root mounted because the
# overlay upper/work directories live under its /run tmpfs.
mount --move /.old_root/proc /proc 2>/dev/null || mount -t proc proc /proc
mount --move /.old_root/sys /sys 2>/dev/null || mount -t sysfs sysfs /sys
mount --move /.old_root/dev /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev

# Mount any additional data drives
if [ -b "$DATA_DEVICE" ]; then
    echo "=== Found data drive at $DATA_DEVICE, mounting at /mnt/data ==="
    mkdir -p /mnt/data
    mount -o ro "$DATA_DEVICE" /mnt/data && echo "✓ Mounted $DATA_DEVICE at /mnt/data (read-only)"
fi

echo "=== Overlay setup complete, starting real init ==="

# Chain to real init
exec /sbin/init "$@"
EOF

sudo chmod +x "$MOUNT_POINT/overlay-init.sh"

echo "Unmounting rootfs..."
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo ""
echo "✅ Done! Created /overlay-init.sh in rootfs"
echo ""
echo "Now use spawn_overlay.sh with this rootfs."
echo "The spawn script will pass init=/overlay-init.sh to the kernel."
