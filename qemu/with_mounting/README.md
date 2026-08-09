# QEMU read-only-root overlay demo

Inject the common overlay init into a disposable rootfs copy, then boot it:

```bash
cp ../../firecracker/ubuntu-22.04.ext4 ./rootfs.ext4
./setup-overlay-simple.sh ./rootfs.ext4
ROOTFS=./rootfs.ext4 ./spawn_overlay.sh
```

The default upper layer is an ephemeral tmpfs. For a persistent upper layer:

```bash
./create-overlay-disk.sh 500 overlay.ext4
ROOTFS=./rootfs.ext4 OVERLAY_MODE=persistent OVERLAY_IMG=./overlay.ext4 ./spawn_overlay.sh
```

Set `DATA_IMG=/path/to/data.ext4` to attach a separate read-only data disk.
