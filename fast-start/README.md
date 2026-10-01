# Fast start: Firecracker and Cloud Hypervisor

A harness and the pieces needed to reproduce the lowest cold-boot and
snapshot-restore times measured on this host (medians of 30 runs, VMM pinned to
P-cores, clock stopped at the guest's first UDP packet). Each cell gives the
full-featured `full` kernel first and the stripped-down `tiny` kernel second:

| | New VMM process | Pre-spawned VMM | Pre-restored paused VM |
| --- | --- | --- | --- |
| Firecracker cold boot | 20.7 / 17.1 ms | 19.1 / 15.3 ms | |
| Firecracker warm start | 7.7 / 7.4 ms | 5.9 / 5.9 ms | 1.3 / 1.5 ms |
| Cloud Hypervisor cold boot | 27.8 / 22.4 ms | 24.0 / 18.8 ms | |
| Cloud Hypervisor warm start | 15.0 / 13.3 ms | 12.1 / 10.2 ms | 1.6 / 1.7 ms |

`sudo ./reproduce.sh kernels` reruns this table; "Reproduce" below covers the
rest of the report.

[`REPORT.md`](REPORT.md) is the full write-up, including how to use these
pieces to start full-featured Linux VMs from a tenant's disk or OCI image in a
few milliseconds.

## Files

- `bench.py`: the harness. Its docstring lists every experiment key.
- `final.json`: the experiment matrix, one entry per optimization step.
- `kernels.json`: the best configurations on the `tiny`, `full` and `full-mit`
  kernels.
- `pagecache.json`: cold boots with their files cached and evicted.
- `profile-full.json`: `full` kernel boots that send their `initcall_debug` log
  to the host, for `tools/gaps.py`.
- `reproduce.sh`: reruns one group of measurements behind `REPORT.md`, with the
  host setup each needs.
- `fastinit.c`: static PID 1. Configures eth0 by ioctl, sends `ready` to the
  host over UDP, then answers every datagram with `pong`.
- `uffd_populate.c`: Firecracker userfaultfd handler that copies the whole
  memory snapshot into guest memory as soon as Firecracker hands it the fd.
- `kernel/`: Docker build image and the config changes applied to the
  Firecracker CI 6.1 config. `trim.sh` removes boot stalls and unused hardware
  support (`vmlinux-min`); `trim-tiny.sh` cuts further for a single-application
  guest (`vmlinux-tiny`); `trim-full.sh` adds back what a general-purpose VM
  needs: nftables/iptables, IPv6, bridge/veth/TUN/VXLAN/WireGuard, BPF with JIT,
  loop devices, XFS/EROFS/squashfs, hugetlbfs and PCI hotplug (`vmlinux-full`).
  `trim-full.sh <config> mitigations` also restores the in-guest speculation
  mitigations.
- `supervisor/`: a PID 1 that launches the customer's process after a restore,
  with env vars sent from the host, and makes each clone unique (clock, RNG,
  network). See `supervisor/README.md`.
- `tools/`: bpftrace scripts and reports used to find where time went; see
  `tools/README.md`.

## Prerequisites

- **Host:** x86_64 Linux with KVM (`/dev/kvm`), root via `sudo`, and internet
  access to GitHub, S3, cdn.kernel.org and Docker Hub. The results come from an
  Intel Core Ultra 9 285 (P-cores 0-7, E-cores 8-23) on Linux 7.0 with
  transparent hugepages set to `madvise`.
- **Kernel modules:** `kvm`, `tun`, `loop` and `dm_mod`.
- **Commands:** gcc with static glibc, cpio, curl, wget, xz, python3 (3.8 or
  later), docker, iproute2 (`ip`), e2fsprogs (`mkfs.ext4`, `e2fsck`,
  `resize2fs`), util-linux (`losetup`), dmsetup and coreutils `numfmt`.
  `setup.sh` checks for them. The tracing tools also need bpftrace and `nm`;
  the `repo-scripts` group also needs iptables and a default route.
- **CPU pinning:** `CPUS` should list performance cores; on a hybrid Intel CPU
  they are in `/sys/devices/cpu_core/cpus`, which `reproduce.sh` reads. Unpinned
  runs here were 15-35% slower.
- **Scratch space:** about 4 GB in `work/` and up to 4 GB of RAM in
  `/dev/shm/vmbench` and the THP tmpfs while benchmarks run.

## Reproduce

```bash
./setup.sh                        # fetches pinned VMMs and kernels, builds work/
sudo ./reproduce.sh kernels       # one group; `sudo ./reproduce.sh` lists them all
sudo ./reproduce.sh all           # everything, several hours
```

`setup.sh` fetches Firecracker v1.16.1 with its CI kernels (5.10.225 from the
v1.9 bucket, 6.1.155 from v1.14), Cloud Hypervisor v53.0 with its
`ch-release-v6.16.9-20260508` kernel, and the Linux 6.1.155 source. It builds
`fastinit`, the images, the four trimmed kernels and the supervisor and OCI
test images. Docker base images are pinned by digest; the packages installed
on top of them are not.

`reproduce.sh` reserves 1024 hugepages, mounts a `huge=always` tmpfs at
`/mnt/vmbench-hugetmp`, sets `/sys/kernel/rcu_expedited` for the groups that
need it, and restores all three on exit, along with `net.ipv4.ip_forward`,
which the repo's scripts turn on. Most groups write
`work/repro/<group>.jsonl`, one JSON line per configuration with its median,
p90 and every run; `sudo ./reproduce.sh` with no group lists the exceptions.

| Group | Runs | Report section |
| --- | --- | --- |
| `steps` | `bench.py final.json`, 30 runs | the four step tables |
| `pagecache` | `bench.py pagecache.json`, 20 runs | cold boots with files evicted |
| `kernels` | `bench.py kernels.json`, 30 runs | Summary; A full-featured guest kernel |
| `profile` | `bench.py profile-full.json`, 3 runs, then `tools/gaps.py` | the profiled `full` boot |
| `repo-scripts` | the repo's `*/with_snapshot/snapshot_bench.sh`, `RESTORE_RUNS=5` | the repo-script baselines |
| `supervisor`, `supervisor-tiny`, `clones` | `supervisor/bench_supervisor.py` | Launching customer code on restore |
| `rootfs`, `rootfs-rcu`, `rootfs-pipeline`, `erofs-inline`, `erofs`, `erofs-rcu`, plus `supervisor` | `supervisor/bench_supervisor.py` | Building fast-starting Linux VMs |

`RUNS=2` gives a quick check of any group. The repo-script rows in the step
tables have 5 runs, so their p90 column shows the slowest run. `bench.py` and
`bench_supervisor.py` also run on their own; their docstrings give the usage.
In the `kernels` output, names read `<vmm>_<cold|warm>_<tier>__<kernel>`; the
table at the top takes its cells from the `initramfs`, `prespawned`, `restore`
and `paused` tiers.

Some figures in `REPORT.md` come from exploratory runs whose results were not
kept: the dead ends listed under its caveats, `max_loop=1` on the 5.10 kernel,
Cloud Hypervisor's `hugepages=on`, the unpinned slowdown, and a repeat of the
step runs after a fresh `setup.sh`. The boot stalls found in the stock
kernels (528 ms of i8042 probing on Firecracker's 6.1 kernel, 530 ms when Cloud
Hypervisor gets the i8042 flags, 89 ms of `loop_init` on 5.10) and the other
figures read from traces were also exploratory; `tools/README.md` shows how to
retrace them.

## What the fastest configurations use

Kernel: `vmlinux-tiny` for the absolute minimum, `vmlinux-full` for a VM that
behaves like a normal Linux machine. `full` costs 3.6 ms (Firecracker) to
5.3 ms (Cloud Hypervisor) more on a cold boot and almost nothing on a restore.

Firecracker cold boot:

- initramfs, `"huge_pages": "2M"`, 1 vCPU, 256 MiB
- boot args `reboot=k panic=1 pci=off quiet 8250.nr_uarts=0`
- `--config-file` with `--no-api` for a fresh process; for a pre-spawned one,
  configure over the API first and time only `InstanceStart`

Firecracker warm start:

- snapshot memory file on a `huge=always` tmpfs, `File` backend
- pre-spawned process with `--no-seccomp`, then `PUT /snapshot/load` with
  `"resume_vm": true`
- paused pool: load with `"resume_vm": false` ahead of time, then
  `PATCH /vm {"state": "Resumed"}`; with `"huge_pages": "2M"` and
  `uffd_populate` the memory is resident before the request

Cloud Hypervisor cold boot:

- `--initramfs`, `--serial off --console off`
- boot args `reboot=k panic=1 quiet 8250.nr_uarts=0`; the `i8042.*` flags
  that Firecracker's stock 6.1 kernel needs stall this VMM for 530 ms
- pre-spawned `cloud-hypervisor --api-socket ... --seccomp false`, `vm.create`
  ahead of time, `vm.boot` on request

Cloud Hypervisor warm start:

- `--restore source_url=file://...,memory_restore_mode=ondemand,resume=true`
  with the snapshot on tmpfs
- pre-spawned process: `PUT /api/v1/vm.restore` on request
- paused pool: `--restore ...,memory_restore_mode=copy,resume=false` ahead of
  time, then `PUT /api/v1/vm.resume`

## Caveats

- The harness boots each configuration once, untimed, so the kernel, images,
  and VMM binary are in page cache. Add `"evict": true` to a cold experiment
  to drop them before each run; that adds 10-14 ms for a new VMM process
  (mostly paging in the VMM binary) and 3-4.5 ms for a pre-spawned one.
- `min`, `tiny` and `full` turn off in-guest speculative-execution
  mitigations. That suits one tenant per VM; host mitigations are unchanged.
  Turning them back on (`full-mit`) adds about 6 ms to a cold boot on both VMMs
  and nothing to a restore, since the boot-time code patching is already done.
- `fastinit` does almost nothing. A real workload adds its own startup time.
- Each paused VM holds memory. Firecracker's `File` backend shares clean pages
  through the page cache; pre-copied or copy-mode pools hold the full guest
  size per VM.
