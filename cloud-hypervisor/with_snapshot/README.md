# Cloud Hypervisor Snapshot Benchmark

This mirrors the Firecracker snapshot demo with Cloud Hypervisor:

1. Copy the rootfs and inject `/snapshot-init.sh`.
2. Boot with TAP metadata and a tiny signal disk.
3. Wait for `SNAP_BENCH_READY` on the serial console.
4. Pause and snapshot with `ch-remote snapshot`.
5. Restore with Cloud Hypervisor's `ondemand` memory restore mode, falling back to copy if needed.

```bash
./snapshot_bench.sh
```

Use the same OCI-derived ext4 rootfs as Firecracker:

```bash
ROOTFS=/path/to/rootfs.ext4 ./snapshot_bench.sh
```
