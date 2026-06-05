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

Compare restoring from a normal on-disk snapshot directory versus a tmpfs-backed
snapshot directory:

```bash
./snapshot_storage_bench.sh
```

By default the disk case asks Linux to evict the snapshot files from page cache
before each restore with `posix_fadvise(..., DONTNEED)`. Disable that with:

```bash
EVICT_DISK_CACHE=0 ./snapshot_storage_bench.sh
```

Observed on this host with the default `ondemand`/UFFD restore mode:

| memory | snapshot backing | restore-to-marker |
| --- | --- | --- |
| 256 MiB | disk, cache evicted | 302 ms, 277 ms, 301 ms |
| 256 MiB | tmpfs under `/dev/shm` | 302 ms, 306 ms, 275 ms |
| 1 GiB | disk, cache evicted | 300 ms |
| 1 GiB | tmpfs under `/dev/shm` | 298 ms |

The restore marker only touches a small guest working set, so disk versus tmpfs
does not move much here. That is the expected shape for on-demand restore: the VM
can resume before reading most of the memory snapshot. To force the storage path,
add a post-restore guest step that touches a large initialized memory buffer.

Use the same OCI-derived ext4 rootfs as Firecracker:

```bash
ROOTFS=/path/to/rootfs.ext4 ./snapshot_bench.sh
```
