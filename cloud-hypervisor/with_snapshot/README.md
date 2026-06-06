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

The restore path intentionally launches Cloud Hypervisor with only `--restore`
plus VMM plumbing such as `--api-socket` and `--log-file`. The snapshot already
contains the guest kernel, disks, TAP device, and serial configuration. Passing a
fresh boot configuration during restore makes the benchmark look like a cold
boot again.

By default the signal disk is pre-armed before restore so the guest can print
`SNAP_BENCH_GO` as soon as it resumes. To measure the older "restore, then poke
the signal disk" boundary:

```bash
PRE_SIGNAL_RESTORE=0 ./snapshot_bench.sh
```

Observed on this host after the restore-path fix:

| hypervisor | restore mode | restore-to-marker |
| --- | --- | --- |
| Firecracker | full snapshot restore | 59 ms, 59 ms, 58 ms, 57 ms, 59 ms |
| Cloud Hypervisor | `ondemand`/UFFD | 109 ms, 125 ms, 108 ms, 108 ms, 111 ms |
| Cloud Hypervisor | `copy` | 162 ms, 197 ms, 177 ms, 167 ms, 196 ms |

Cloud Hypervisor-specific knobs:

```bash
RESTORE_MODE=copy ./snapshot_bench.sh
CH_RESTORE_PATH=api ./snapshot_bench.sh
CH_SECCOMP=false ./snapshot_bench.sh
CH_THP=off ./snapshot_bench.sh
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

Observed on this host with the default `ondemand`/UFFD restore mode and the
fixed restore path:

| memory | snapshot backing | restore-to-marker |
| --- | --- | --- |
| 256 MiB | disk, cache evicted | 211 ms, 211 ms, 213 ms |
| 256 MiB | tmpfs under `/dev/shm` | 89 ms, 96 ms, 88 ms |
| 1 GiB | disk, cache evicted | 190 ms |
| 1 GiB | tmpfs under `/dev/shm` | 84 ms |

The restore marker only touches a small guest working set, so disk versus tmpfs
only reflects the pages needed to resume and perform the metadata check. To
stress UFFD page-in behavior harder, add a post-restore guest step that touches a
large initialized memory buffer.

Use the same OCI-derived ext4 rootfs as Firecracker:

```bash
ROOTFS=/path/to/rootfs.ext4 ./snapshot_bench.sh
```
