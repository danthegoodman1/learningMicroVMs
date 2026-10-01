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

`results-2026-10-01-kernels.jsonl` holds these runs; `results-2026-09-30.jsonl`
holds the step-by-step optimization runs.

[`REPORT.md`](REPORT.md) is the full write-up, including how to use these
pieces to start full-featured Linux VMs from a tenant's disk or OCI image in a
few milliseconds.

## Files

- `bench.py`: the harness. Its docstring lists every experiment key.
- `final.json`: the experiment matrix, one entry per optimization step.
- `kernels.json`: the best configurations on the `tiny`, `full` and `full-mit`
  kernels.
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
- `tools/`: bpftrace scripts and reports used to find where time went.
  `exits.bt` + `symprof.py` sample guest RIPs at VM exits; `sys.bt` + `sysrep.py`
  time VMM syscalls and KVM ioctls; `gaps.py` ranks slow steps in a guest
  `initcall_debug` log.

## Run it

```bash
../firecracker/dl_reqs.sh
../cloud-hypervisor/dl_reqs.sh
./setup.sh                                  # builds work/: images, init, kernels

sudo sysctl -w vm.nr_hugepages=1024         # Firecracker "huge": true rows
sudo mkdir -p /mnt/vmbench-hugetmp          # THP tmpfs for snapshot memory
sudo mount -t tmpfs -o huge=always,size=4G tmpfs /mnt/vmbench-hugetmp

sudo CPUS=0,1,2,3,4,5,6,7 python3 bench.py final.json 30
sudo CPUS=0,1,2,3,4,5,6,7 python3 bench.py final.json 30 fc_cold_7_tiny_kernel,ch_warm_5_paused_pool_copy
```

`CPUS` should list performance cores; on this hybrid CPU unpinned runs are
15-35% slower. Results append to `work/results.jsonl`.

Afterwards:

```bash
sudo umount /mnt/vmbench-hugetmp
sudo sysctl -w vm.nr_hugepages=0
```

## What the fastest configurations use

Kernel: `vmlinux-tiny` for the absolute minimum, `vmlinux-full` for a VM that
behaves like a normal Linux machine. `full` costs 3.6 ms (Firecracker) to
5.4 ms (Cloud Hypervisor) more on a cold boot and almost nothing on a restore.

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
  (mostly paging in the VMM binary) and 3-4 ms for a pre-spawned one.
- `min`, `tiny` and `full` turn off in-guest speculative-execution
  mitigations. That suits one tenant per VM; host mitigations are unchanged.
  Turning them back on (`full-mit`) adds about 6 ms to a cold boot on both VMMs
  and nothing to a restore, since the boot-time code patching is already done.
- `fastinit` does almost nothing. A real workload adds its own startup time.
- Each paused VM holds memory. Firecracker's `File` backend shares clean pages
  through the page cache; pre-copied or copy-mode pools hold the full guest
  size per VM.
