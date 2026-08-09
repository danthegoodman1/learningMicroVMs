# QEMU counterparts

These demos mirror the Firecracker and Cloud Hypervisor examples with QEMU.
They reuse the downloaded Linux kernel, rootfs, and SSH key in `firecracker/`.

Install the host dependencies on Ubuntu:

```bash
sudo apt-get install qemu-system-x86 qemu-utils virtiofsd
```

Download guest assets if needed, then boot the base demo:

```bash
../firecracker/dl_reqs.sh
./spawn.sh
./stop.sh
```

The base, metadata, overlay, snapshot, and overcommit demos use QEMU's
minimal `microvm` machine with virtio-mmio devices. PCI hotplug features use
`q35`, because `microvm` intentionally has no PCI bus or device hotplug.

Available counterparts:

- `with_metadata/`: link-local instance metadata, including multiple VMs.
- `with_mounting/`: read-only root with tmpfs or persistent overlay.
- `with_snapshot/`: reusable full mapped-RAM migration-file snapshots.
- `with_virtiofs/`: stock `virtiofsd` host-directory sharing.
- `with_custom_virtiofs/`: the custom Rust vhost-user backend, hotplugged via QMP.
- `../memory-hotplug/qemu.sh`: virtio-mem policy demo on `q35`.
- `../overcommit-demo/demo.sh`: QEMU participates alongside the other VMMs.

QEMU's mapped-RAM snapshot is a full reusable snapshot. It is not equivalent
to Cloud Hypervisor's offline `ondemand`/userfaultfd restore; QEMU's lazy
postcopy migration requires a live source process.

The custom Rust virtio-fs demos additionally require Cargo and the
`libcap-ng-dev` host package.
