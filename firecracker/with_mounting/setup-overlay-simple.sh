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
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create directories
mkdir -p /overlay/lower /overlay/upper /overlay/work /overlay/merged

# Root is already mounted, move it to lower
mount --make-rprivate /
mount --bind / /overlay/lower

# Set up upper layer (writable overlay)
if [ -b /dev/vdb ]; then
    echo "Using persistent overlay on /dev/vdb"
    mount /dev/vdb /overlay/upper
    mkdir -p /overlay/upper/data /overlay/upper/work
    UPPER="/overlay/upper/data"
    WORK="/overlay/upper/work"
    DATA_DEVICE="/dev/vdc"
else
    echo "Using tmpfs overlay (ephemeral)"
    mount -t tmpfs -o size=2G tmpfs /overlay/upper
    mkdir -p /overlay/upper/data /overlay/upper/work
    UPPER="/overlay/upper/data"
    WORK="/overlay/upper/work"
    DATA_DEVICE="/dev/vdb"
fi

# Create the overlay
mount -t overlay overlay -o lowerdir=/overlay/lower,upperdir=$UPPER,workdir=$WORK /overlay/merged

# Prepare for pivot
cd /overlay/merged
mkdir -p /overlay/merged/overlay
pivot_root . overlay

# Move mounts
mount --move /overlay/lower /overlay/
mount --move /overlay/upper /overlay/
cd /

# Unmount old root
umount -l /overlay

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
