#!/bin/bash

# Variables
ROOTFS_DIR="./rootfs"
IMAGE_FILE="rootfs.ext4"
TEMP_MOUNT_DIR="/mnt/tempfs"

echo "nameserver 8.8.8.8" >> $ROOTFS_DIR/etc/resolv.conf

# Calculate image size dynamically based on content
CONTENT_SIZE=$(du -sm ${ROOTFS_DIR} | cut -f1)
OVERHEAD_PERCENT=20
IMAGE_SIZE_MB=$((CONTENT_SIZE * (100 + OVERHEAD_PERCENT) / 100))

echo "Content size: ${CONTENT_SIZE}MB"
echo "Creating ${IMAGE_SIZE_MB}MB image (with ${OVERHEAD_PERCENT}% overhead)"

# Step 1: Create an empty file
dd if=/dev/zero of=${IMAGE_FILE} bs=1M count=${IMAGE_SIZE_MB}

# Step 2: Format the file as ext4
mkfs.ext4 ${IMAGE_FILE}

# Step 3: Mount the ext4 file
mkdir -p ${TEMP_MOUNT_DIR}
sudo mount -o loop ${IMAGE_FILE} ${TEMP_MOUNT_DIR}

# Step 4: Copy the root filesystem
sudo cp -a ${ROOTFS_DIR}/. ${TEMP_MOUNT_DIR}

# Step 5: Unmount the ext4 file
sudo umount ${TEMP_MOUNT_DIR}

# Step 6: Clean up
rmdir ${TEMP_MOUNT_DIR}

echo "ext4 filesystem image created: ${IMAGE_FILE}"
