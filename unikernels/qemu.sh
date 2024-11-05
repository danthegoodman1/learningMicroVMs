# Untested claude written script
# can probably generate .cpio from docker like image_to_fs.sh (or unoci and skopeo) plus https://www.gnu.org/software/cpio/manual/html_node/Tutorial.html#Tutorial

#!/bin/bash

# Default values
UNIKERNEL_IMAGE="${1:-unikernel.cpio}"
DISK_IMAGE="${2:-disk.img}"
DISK_SIZE="1G"
RAM_SIZE="512M"
NET_DRIVER="virtio-net-pci"

# Check if disk image exists, if not create it
if [ ! -f "$DISK_IMAGE" ]; then
    echo "Creating disk image of size $DISK_SIZE..."
    qemu-img create -f raw "$DISK_IMAGE" "$DISK_SIZE"
fi

# Check if unikernel image exists
if [ ! -f "$UNIKERNEL_IMAGE" ]; then
    echo "Error: Unikernel image $UNIKERNEL_IMAGE not found!"
    exit 1
fi

# Network configuration
NET_OPTIONS="-netdev user,id=net0,hostfwd=tcp::8080-:80 \
            -device $NET_DRIVER,netdev=net0"

# Storage configuration
DISK_OPTIONS="-drive file=$DISK_IMAGE,if=virtio,format=raw"

# Run the unikernel
exec qemu-system-x86_64 \
    -cpu host \
    -enable-kvm \
    -m "$RAM_SIZE" \
    -kernel "$UNIKERNEL_IMAGE" \
    -nographic \
    -no-reboot \
    -append "console=ttyS0" \
    $NET_OPTIONS \
    $DISK_OPTIONS
