#!/usr/bin/env bash
# Fetches the VMMs and guest kernels this research used, then builds everything
# the harnesses need into work/:
#   fastinit, initramfs.cpio, ubuntu-fastinit.ext4, uffd_populate,
#   vmlinux-min, -tiny, -full and -full-mit (6.1 guest kernels, built in Docker),
#   and the supervisor and OCI test images (supervisor/build.sh, supervisor/oci/build.sh).
# README.md lists the prerequisites.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/.." && pwd)"
WORK="$HERE/work"
KVER="${KVER:-6.1.155}"
BUILD_CPUS="${BUILD_CPUS:-$(nproc)}"
mkdir -p "$WORK"

missing=()
for cmd in gcc cpio curl wget xz python3 docker sudo ip mkfs.ext4 e2fsck resize2fs losetup dmsetup numfmt; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing commands: ${missing[*]} (see README.md, Prerequisites)" >&2
    exit 1
fi

# The versions the results were measured with. Firecracker's dl_reqs.sh pins
# v1.16.1 itself; its 5.10 kernel is the newest in the frozen CI v1.9 bucket.
(cd "$REPO/firecracker" && ./dl_reqs.sh)
(cd "$REPO/cloud-hypervisor" && CH_VERSION=v53.0 CH_KERNEL_TAG=ch-release-v6.16.9-20260508 ./dl_reqs.sh)
FC61="$REPO/firecracker/vmlinux-6.1.155"
if [ ! -f "$FC61" ]; then
    curl -fL --retry 3 -o "$FC61.tmp" \
        "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.14/$(uname -m)/vmlinux-6.1.155"
    mv "$FC61.tmp" "$FC61"
fi

gcc -O2 -static -s -o "$WORK/fastinit" "$HERE/fastinit.c"
gcc -O2 -o "$WORK/uffd_populate" "$HERE/uffd_populate.c"

# initramfs: just /init and /dev/console
rm -rf "$WORK/initramfs"
mkdir -p "$WORK/initramfs/dev"
cp "$WORK/fastinit" "$WORK/initramfs/init"
sudo mknod -m 600 "$WORK/initramfs/dev/console" c 5 1
(cd "$WORK/initramfs" && sudo find . | sudo cpio -o -H newc --quiet > "$WORK/initramfs.cpio")

# Ubuntu rootfs from the Firecracker demos with /fastinit added
cp "$HERE/../firecracker/ubuntu-22.04.ext4" "$WORK/ubuntu-fastinit.ext4"
mkdir -p "$WORK/mnt"
sudo mount -o loop "$WORK/ubuntu-fastinit.ext4" "$WORK/mnt"
sudo install -m 755 "$WORK/fastinit" "$WORK/mnt/fastinit"
sudo umount "$WORK/mnt"

# Kernels: start from the Firecracker CI 6.1 config and trim it.
if [ ! -f "$WORK/vmlinux-min" ] || [ ! -f "$WORK/vmlinux-tiny" ] || [ ! -f "$WORK/vmlinux-full" ] || [ ! -f "$WORK/vmlinux-full-mit" ]; then
    if [ ! -d "$WORK/linux-$KVER" ]; then
        curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz" | tar -xJ -C "$WORK"
    fi
    "$WORK/linux-$KVER/scripts/extract-ikconfig" "$HERE/../firecracker/vmlinux-6.1.155" > "$WORK/base.config"
    sudo docker build -q -t fast-start-kbuild "$HERE/kernel" >/dev/null
    sudo docker run --rm --cpus "$BUILD_CPUS" -v "$HERE:/fs" -e KVER="$KVER" fast-start-kbuild bash -euc '
        cd /fs/work/linux-$KVER
        for name in min tiny full full-mit; do
            out=/fs/work/out-$name
            mkdir -p $out
            cp /fs/work/base.config $out/.config
            for pass in 1 2; do
                /fs/kernel/trim.sh $out/.config
                [ $name = tiny ] && /fs/kernel/trim-tiny.sh $out/.config
                [ $name = full ] && /fs/kernel/trim-full.sh $out/.config
                [ $name = full-mit ] && /fs/kernel/trim-full.sh $out/.config mitigations
                make O=$out olddefconfig >/dev/null
            done
            make O=$out -j"$(nproc)" vmlinux >$out/build.log 2>&1
            cp $out/vmlinux /fs/work/vmlinux-$name
        done'
fi

"$HERE/supervisor/build.sh"
"$HERE/supervisor/oci/build.sh"

echo "Ready. Reproduce a result group with: sudo $HERE/reproduce.sh <group> (see README.md)"
