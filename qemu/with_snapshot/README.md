# QEMU mapped-RAM snapshot benchmark

This mirrors the Firecracker and Cloud Hypervisor SnapStart-style benchmarks:

```bash
./snapshot_bench.sh
```

It pauses the guest and writes a seekable QEMU migration file with the
`mapped-ram` capability. Each measurement starts a fresh QEMU process, restores
the reusable file, resumes the VM, and waits for the guest marker.

Compare a cache-evicted disk snapshot with a tmpfs-backed snapshot:

```bash
./snapshot_storage_bench.sh
```

Useful knobs include `RESTORE_RUNS`, `BENCH_MEM_MIB`, `BENCH_VCPUS`,
`PRE_SIGNAL_RESTORE`, and `EVICT_SNAPSHOT_CACHE`.

This is a full snapshot. QEMU postcopy is not used because it requires a live
source and therefore cannot reproduce Cloud Hypervisor's reusable offline
`ondemand`/userfaultfd snapshot semantics.
