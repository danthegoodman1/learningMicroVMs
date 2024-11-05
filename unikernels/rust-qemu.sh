qemu-system-x86_64 \
    -cpu host \
    -enable-kvm \
    -m 512M \
    -kernel unikernel.cpio \
    -nographic \
    -append "console=ttyS0" \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -device virtio-net-pci,netdev=net0
