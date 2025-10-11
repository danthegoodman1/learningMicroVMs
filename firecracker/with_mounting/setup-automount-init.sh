#!/bin/bash
# This script modifies a rootfs to auto-mount a secondary drive using an init script
# This approach is more flexible than fstab as it can handle the drive not being present

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rootfs.ext4>"
    echo "This will add an init script to auto-mount /dev/vdb at /mnt/somedir on boot"
    exit 1
fi

ROOTFS="$1"
MOUNT_POINT="/tmp/rootfs_mount_$$"

echo "Mounting rootfs..."
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

echo "Creating mount directory..."
sudo mkdir -p "$MOUNT_POINT/mnt/somedir"

# Create the mount init script
echo "Creating init script..."
sudo tee "$MOUNT_POINT/usr/local/bin/mount-secondary.sh" > /dev/null << 'EOF'
#!/bin/sh
# Auto-mount secondary drive if present

if [ -b /dev/vdb ]; then
    echo "Mounting /dev/vdb at /mnt/somedir..."
    mkdir -p /mnt/somedir
    mount /dev/vdb /mnt/somedir && echo "✓ Mounted /dev/vdb" || echo "✗ Failed to mount /dev/vdb"
else
    echo "No secondary drive (/dev/vdb) detected, skipping mount"
fi
EOF

sudo chmod +x "$MOUNT_POINT/usr/local/bin/mount-secondary.sh"

# Add to rc.local (if it exists) or create it
echo "Setting up boot script..."
if [ -f "$MOUNT_POINT/etc/rc.local" ]; then
    # Remove existing entry if present
    sudo sed -i '/mount-secondary.sh/d' "$MOUNT_POINT/etc/rc.local"
    # Insert before 'exit 0' if present, or at end
    if sudo grep -q "^exit 0" "$MOUNT_POINT/etc/rc.local"; then
        sudo sed -i '/^exit 0/i /usr/local/bin/mount-secondary.sh' "$MOUNT_POINT/etc/rc.local"
    else
        echo "/usr/local/bin/mount-secondary.sh" | sudo tee -a "$MOUNT_POINT/etc/rc.local" > /dev/null
    fi
else
    # Create rc.local
    sudo tee "$MOUNT_POINT/etc/rc.local" > /dev/null << 'EOF'
#!/bin/sh -e
/usr/local/bin/mount-secondary.sh
exit 0
EOF
    sudo chmod +x "$MOUNT_POINT/etc/rc.local"
fi

# For systemd-based systems, also create a systemd service
if [ -d "$MOUNT_POINT/etc/systemd/system" ]; then
    echo "Creating systemd service..."
    sudo tee "$MOUNT_POINT/etc/systemd/system/mount-secondary.service" > /dev/null << 'EOF'
[Unit]
Description=Mount secondary drive at /mnt/somedir
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-secondary.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service (create symlink)
    sudo mkdir -p "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/mount-secondary.service \
        "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/mount-secondary.service" 2>/dev/null || true
    echo "✓ Created and enabled systemd service"
fi

echo "Unmounting rootfs..."
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo ""
echo "Done! Your rootfs will now automatically mount /dev/vdb at /mnt/somedir on boot."
echo "The script gracefully handles the case where no secondary drive is attached."
echo ""
echo "Run with: MOUNT_IMG=./data.ext4 ./spawn_with_mount.sh"
