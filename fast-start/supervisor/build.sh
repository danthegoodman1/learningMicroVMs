#!/usr/bin/env bash
# Builds the supervisor images into ../work:
#   initramfs-supervisor.cpio  /init = supervisor, plus /child_probe
#   ubuntu-supervisor.ext4     the demo Ubuntu rootfs plus /supervisor,
#                              /child_probe and /py_child.py (boot with init=/supervisor)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/../work"
mkdir -p "$WORK"

gcc -O2 -Wall -static -s -o "$WORK/supervisor" "$HERE/supervisor.c"
gcc -O2 -Wall -static -s -o "$WORK/child_probe" "$HERE/child_probe.c"

rm -rf "$WORK/initramfs-sv"
mkdir -p "$WORK/initramfs-sv/dev"
cp "$WORK/supervisor" "$WORK/initramfs-sv/init"
cp "$WORK/child_probe" "$WORK/initramfs-sv/child_probe"
sudo mknod -m 600 "$WORK/initramfs-sv/dev/console" c 5 1
(cd "$WORK/initramfs-sv" && sudo find . | sudo cpio -o -H newc --quiet > "$WORK/initramfs-supervisor.cpio")

ROOTFS="$WORK/ubuntu-supervisor.ext4"
cp "$HERE/../../firecracker/ubuntu-22.04.ext4" "$ROOTFS"
truncate -s +64M "$ROOTFS"
e2fsck -fp "$ROOTFS" >/dev/null || [ $? -le 1 ]
resize2fs -p "$ROOTFS" >/dev/null 2>&1
mkdir -p "$WORK/mnt"
sudo mount -o loop "$ROOTFS" "$WORK/mnt"
sudo install -m 755 "$WORK/supervisor" "$WORK/mnt/supervisor"
sudo install -m 755 "$WORK/child_probe" "$WORK/mnt/child_probe"
sudo install -m 644 "$HERE/py_child.py" "$WORK/mnt/py_child.py"
sudo umount "$WORK/mnt"
# Stand-in disk that Firecracker base snapshots carry until a tenant disk replaces it
truncate -s 1M "$WORK/placeholder.img"
echo "supervisor images ready in $WORK"
