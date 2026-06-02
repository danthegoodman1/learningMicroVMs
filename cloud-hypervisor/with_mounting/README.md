# Cloud Hypervisor with Overlay Filesystem

This demo boots a Cloud Hypervisor VM with a read-only base rootfs and a writable
overlay. In the default `tmpfs` mode, writes disappear after reboot.

## Setup

Use a disposable rootfs copy because this injects `/overlay-init.sh`:

```bash
cp ../ubuntu-22.04.ext4 ./overlay-rootfs.ext4
./setup-overlay-simple.sh ./overlay-rootfs.ext4
```

## Ephemeral Overlay

```bash
ROOTFS=./overlay-rootfs.ext4 ./spawn_overlay.sh
```

## Persistent Overlay

```bash
./create-overlay-disk.sh 500
ROOTFS=./overlay-rootfs.ext4 OVERLAY_MODE=persistent OVERLAY_IMG=./overlay.ext4 ./spawn_overlay.sh
```

## Extra Read-only Data Drive

```bash
ROOTFS=./overlay-rootfs.ext4 DATA_IMG=./data.ext4 ./spawn_overlay.sh
```
