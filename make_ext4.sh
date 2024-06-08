#!/bin/bash

# Variables
ROOTFS_DIR="./rootfs"
IMAGE_FILE="rootfs.ext4"
IMAGE_SIZE_MB=100  # Adjust size as needed, larger than image
TEMP_MOUNT_DIR="/mnt/tempfs"

echo "nameserver 8.8.8.8" >> $ROOTFS_DIR/etc/resolv.conf

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
