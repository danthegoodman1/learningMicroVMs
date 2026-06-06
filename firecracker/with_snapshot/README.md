# Firecracker Snapshot Benchmark

This is a small SnapStart-style demo:

1. Copy the rootfs and inject `/snapshot-init.sh`.
2. Boot Firecracker with TAP metadata and a tiny signal disk.
3. Wait for `SNAP_BENCH_READY` on the serial console.
4. Pause, create a full snapshot, restore into a fresh Firecracker process.
5. Wait for `SNAP_BENCH_GO`.

```bash
./snapshot_bench.sh
```

By default the signal disk is pre-armed before restore so the guest can report as
soon as it resumes. To measure the older "restore, then poke the signal disk"
boundary:

```bash
PRE_SIGNAL_RESTORE=0 ./snapshot_bench.sh
```

Use a custom OCI-derived ext4 rootfs:

```bash
ROOTFS=/path/to/rootfs.ext4 ./snapshot_bench.sh
```
