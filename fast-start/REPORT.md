# MicroVM Start-Time Optimization: Firecracker and Cloud Hypervisor

2026-10-01 · Dan Goodman

## Summary

A full-featured Linux guest, with iptables, IPv6, containers, FUSE and BPF, cold-boots to a network-ready state in 20.7 ms on Firecracker and 27.8 ms on Cloud Hypervisor. It restores from a snapshot in 7.7 ms and 15.0 ms. A stripped-down kernel saves 3.6–5.3 ms on cold boots and almost nothing on restores. The repo's scripts measured 360, 90, 295 and 78 ms for the same cases.

Keeping a VMM process, or a restored and paused VM, ready ahead of time cuts the times further. Each cell gives the full-featured `full` kernel first and the stripped-down `tiny` kernel second:

| Case | New VMM process | Pre-spawned VMM | Pre-restored paused VM | What mattered most |
| --- | --- | --- | --- | --- |
| Firecracker cold boot | 20.7 / 17.1 ms | 19.1 / 15.3 ms |  | Serial console off; 2 MiB hugepages; a kernel without boot stalls |
| Firecracker warm start | 7.7 / 7.4 ms | 5.9 / 5.9 ms | 1.3 / 1.5 ms | Direct API calls; snapshot memory on a THP tmpfs |
| Cloud Hypervisor cold boot | 27.8 / 22.4 ms | 24.0 / 18.8 ms |  | Serial console off; a kernel without boot stalls; initramfs |
| Cloud Hypervisor warm start | 15.0 / 13.3 ms | 12.1 / 10.2 ms | 1.6 / 1.7 ms | Direct API calls; on-demand restore; copy mode for the paused pool |

All figures are medians of 30 runs from one session on 2026-10-01, with the VMM pinned to P-cores. The clock stops when the host receives the guest's first UDP packet.

For Fly-style VMs that run a tenant's OCI image, restoring a generic base snapshot with the tenant's EROFS image already in place runs a static binary 10.7 ms after the request on Firecracker and 15.9 ms on Cloud Hypervisor, including starting the VMM. From a pool of paused base VMs it takes 3.4 ms on Firecracker, and 3.3 ms on Cloud Hypervisor with a device-mapper swap and expedited RCU. The section "Building fast-starting Linux VMs" describes how.

## Setup and measurement

Every figure comes from two harnesses run on this machine on 2026-09-30 and 2026-10-01: `fast-start/bench.py` for boots and restores, and `fast-start/supervisor/bench_supervisor.py` for launching customer code. The repo-script baselines come from the repo's own snapshot scripts, described below.

- **Host:** Intel Core Ultra 9 285 (8 P-cores, 16 E-cores), 125 GiB RAM, Linux 7.0.0-30 with KVM.
- **VMMs:** Firecracker v1.16.1 and Cloud Hypervisor v53.0, pinned by `fast-start/setup.sh`.
- **Guest:** 1 vCPU, 256 MiB, one virtio-net NIC on a pre-created TAP with a permanent ARP entry.
- **Root filesystem:** the repo's Ubuntu 22.04 ext4 image mounted read-only, or a 740 KB initramfs.
- **Init:** `fastinit`, a static C program. It configures eth0 with ioctls, sends "ready" over UDP, then answers pings.
- **Guest kernels:** Firecracker CI 5.10.225 and 6.1.155, Cloud Hypervisor's 6.16.9, and four builds of 6.1.155 without the boot stalls: `min`, `tiny` (one application), `full` (a general-purpose VM) and `full-mit` (`full` plus in-guest speculation mitigations).

The clock starts just before the harness spawns the VMM. For pre-spawned tiers it starts just before the boot, restore, or resume API call. It stops when the host receives the guest's first UDP packet: "ready" for a cold boot, or the reply to a 0.5 ms ping loop for a restore.

The harness boots each configuration once, untimed, before measuring it. The kernel, initramfs or rootfs, and VMM binary are therefore in the host page cache for every timed run. The caveats section gives cold-boot times with those files evicted.

The repo's snapshot scripts measure differently. They send each API call through `sudo curl`, poll the serial log every 20 ms, and boot a shell-script init that runs `ip` and `curl`. Their Firecracker cold figure also starts at InstanceStart, after process launch and configuration.

## Firecracker cold boot

Median ms from VMM launch (or, for pre-spawned rows, from the API call) to the guest's first UDP packet, measured 2026-09-30. Below the stock setup, each row adds one change to the row above. The repo-script row uses that script's own endpoint, a serial-console marker.

| Step | Median | p90 |
| --- | --- | --- |
| Repo script (clock starts at InstanceStart) | 360 ms | 360 ms |
| Harness + fastinit; stock 5.10 kernel, console on | 240.6 ms | 244.4 ms |
| Serial console off | 169.8 ms | 171.4 ms |
| FC CI 6.1 kernel with i8042 flags | 57.6 ms | 60.9 ms |
| 2 MiB hugepages for guest memory | 37.3 ms | 38.6 ms |
| initramfs instead of ext4 rootfs | 35.1 ms | 36.6 ms |
| Trimmed 6.1 kernel (min) | 19.2 ms | 20.2 ms |
| Smaller kernel (tiny) | 17.5 ms | 18.3 ms |
| Pre-spawned, pre-configured VMM; no seccomp | 15.8 ms | 16.7 ms |

The guest kernel dominated. These changes did the work:

- **Serial console off.** Each console byte is a port-I/O VM exit. Replace `console=ttyS0` with `quiet 8250.nr_uarts=0`.
- **A kernel without boot stalls.** The 5.10 CI kernel spends 89 ms in `loop_init` building eight loop devices (`max_loop=1` fixes it: 94 ms). The 6.1 CI kernel instead waits 528 ms probing Firecracker's i8042 keyboard; `i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd` removes the wait.
- **2 MiB hugepages.** Firecracker backs guest memory with 4 KiB pages, so a boot took about 10,500 EPT faults. Set `"huge_pages": "2M"` in `machine-config` and reserve pages with `sysctl vm.nr_hugepages`.
- **A trimmed kernel.** `fast-start/kernel/trim.sh` drops the jitter-entropy self-test, in-guest speculation mitigations and their boot-time code patching, input and VT drivers, loop and SCSI, extra filesystems and I/O schedulers, and sets HZ=1000. Guest time to init fell from 24 ms to 5 ms. `trim-tiny.sh` cuts KALLSYMS, cgroups, and more, leaving 11 MB to load.

Booting the Ubuntu ext4 rootfs instead of the initramfs adds about 1 ms: 20.2 ms with `min`, 18.5 ms with `tiny`.

In a fresh-process boot, about 7 ms passes before the first guest instruction. Loading the kernel ELF into guest memory takes 3.7 ms, and `KVM_CREATE_VCPU` waits 1.3 ms on an SRCU grace period in the host kernel. The guest itself runs about 8 ms.

## Firecracker warm start

Median ms from VMM launch (or, for pre-spawned rows, from the API call) to the guest's first UDP packet, measured 2026-09-30. Below the stock setup, each row adds one change to the row above. The repo-script row uses that script's own endpoint, a serial-console marker.

| Step | Median | p90 |
| --- | --- | --- |
| Repo script (sudo curl, 20 ms polling) | 90 ms | 102 ms |
| Harness; stock 6.1 kernel, snapshot on tmpfs | 9.0 ms | 9.9 ms |
| tiny kernel, initramfs | 8.4 ms | 9.4 ms |
| Memory file on a THP tmpfs | 7.5 ms | 7.8 ms |
| Pre-spawned VMM; no seccomp | 5.8 ms | 6.2 ms |
| Pre-restored paused VM (resume only) | 1.7 ms | 2.0 ms |
| Paused, 2 MiB pages, memory pre-copied | 1.5 ms | 1.8 ms |

Most of the repo script's 90 ms was harness overhead. Each API call forked `sudo curl`, the guest polled a signal disk every 20 ms, and the host polled the serial log every 20 ms. Calling the API over its Unix socket and using a UDP ping as the ready signal brought the same restore to 9 ms.

After that, three things helped:

- **Keep the snapshot in memory.** With `mem.snap` on NVMe and out of page cache, a restore takes 25.9 ms, because the guest faults its working set in from disk.
- **Serve the memory file from a THP tmpfs** (`mount -t tmpfs -o huge=always`). Firecracker maps `mem.snap` privately, and the guest's first touch of each page is a fault. Larger page-cache pages cut that phase from 2.2 ms to 1.4 ms.
- **Pre-spawn the VMM.** Process launch and API-socket setup cost 1.3 ms; `--no-seccomp` saves 0.3 ms more.

A fresh restore still spends 4.4 ms in `PUT /snapshot/load`. About 2 ms of that is `KVM_CREATE_VCPU` waiting on an SRCU grace period while KVM adds the APIC-access page's memslot. Cloud Hypervisor makes the same call and waits under 0.1 ms; I have not pinned down why Firecracker waits longer.

A paused pool skips the load entirely. Load the snapshot ahead of time with `"resume_vm": false`, then send `PATCH /vm {"state": "Resumed"}` when a request arrives. That takes 1.7 ms, mostly about 670 first-touch page faults plus the network round trip. The last row adds 2 MiB hugepages and `fast-start/uffd_populate.c`, a userfaultfd handler that copies the whole snapshot into guest memory before the request; its best run took 0.5 ms.

Each paused VM costs memory. With the file backend, untouched pages stay shared in page cache. With the pre-copied variant, every pooled VM holds its full 256 MiB.

## Cloud Hypervisor cold boot

Median ms from VMM launch (or, for pre-spawned rows, from the API call) to the guest's first UDP packet, measured 2026-09-30. Below the stock setup, each row adds one change to the row above. The repo-script row uses that script's own endpoint, a serial-console marker.

| Step | Median | p90 |
| --- | --- | --- |
| Repo script (serial marker, shell init) | 295 ms | 295 ms |
| Harness + fastinit; stock 6.16 kernel, console on | 164.3 ms | 167.3 ms |
| Serial console off | 57.4 ms | 61.5 ms |
| FC CI 6.1 kernel | 51.2 ms | 52.8 ms |
| initramfs instead of ext4 rootfs | 46.5 ms | 48.3 ms |
| Trimmed 6.1 kernel (min) | 25.9 ms | 26.8 ms |
| Smaller kernel (tiny) | 23.2 ms | 24.9 ms |
| Pre-spawned VMM, vm.create done; no seccomp | 19.1 ms | 20.3 ms |

The serial console and the guest kernel again did most of the work:

- **Serial console off.** The stock setup spends over 100 ms writing the boot log through the emulated UART. Use `--serial off --console off` and `quiet` on the command line.
- **A leaner kernel.** Firecracker's 6.1 CI kernel boots faster than Cloud Hypervisor's own 6.16 build. The trimmed kernels help more here than under Firecracker because they also drop the ACPI PM-timer clocksource, whose boot-time check took 4.5 ms of port reads.
- **initramfs.** Mounting ext4 and loading `fastinit` through virtio-blk costs about 4 ms: the ext4 variants of the last two steps measure 29.3 and 27.2 ms.
- **Pre-spawn the VMM.** Start `cloud-hypervisor --api-socket` early and send `vm.create`; at request time send only `vm.boot`. This saves 4 ms, more than for Firecracker, because Cloud Hypervisor starts more threads and installs a seccomp filter on each.

Hugepages matter less here. Cloud Hypervisor asks for transparent huge pages by default (`thp=on`), so a boot takes about 50 EPT faults instead of Firecracker's 10,500. Adding `hugepages=on` saved about 1 ms.

The remaining gap to Firecracker is PCI. Cloud Hypervisor has no virtio-mmio on x86, so the guest enumerates PCI through port-I/O config space (about 1,000 exits, 4 ms), runs ACPI init, and programs MSI-X for each device. The kernel's `i8042.*` flags that fix Firecracker's 6.1 boot add a 530 ms stall here, so pass them only to Firecracker; the trimmed kernels drop the i8042 driver entirely.

## Cloud Hypervisor warm start

Median ms from VMM launch (or, for pre-spawned rows, from the API call) to the guest's first UDP packet, measured 2026-09-30. Below the stock setup, each row adds one change to the row above. The repo-script row uses that script's own endpoint, a serial-console marker.

| Step | Median | p90 |
| --- | --- | --- |
| Repo script (sudo, 20 ms polling) | 78 ms | 104 ms |
| Harness; stock 6.1 kernel, on-demand, tmpfs | 15.0 ms | 17.4 ms |
| tiny kernel, initramfs | 13.4 ms | 14.8 ms |
| Pre-spawned VMM, API restore; no seccomp | 10.4 ms | 11.4 ms |
| Pre-restored paused VM, copy mode | 1.7 ms | 1.9 ms |

As with Firecracker, the repo script's time went mostly to `sudo`, polling, and the shell init. Launching `cloud-hypervisor --restore source_url=...,memory_restore_mode=ondemand,resume=true` directly and pinging the guest brought a restore to 15 ms.

The memory restore mode decides the rest:

- **On-demand (userfaultfd) wins for a fresh restore.** Copy mode reads all 256 MiB before the guest runs and takes 59.6 ms. On-demand maps memory lazily, but each first-touched page costs about 8 µs: a handler-thread wake-up, a `pread`, and a `UFFDIO_COPY`. That is four times Firecracker's page-cache fault, and it leaves about 5 ms of faulting after resume.
- **Keep the snapshot in memory.** From NVMe with the page cache evicted, an on-demand restore takes 50.9 ms.
- **Pre-spawn the VMM.** Start `cloud-hypervisor --api-socket` early and send `PUT /api/v1/vm.restore` at request time. This saves 3 ms; `--seccomp false` accounts for about 1 ms of it.

**Copy mode wins for a paused pool.** Restore ahead of time with `resume=false`, wait until `vm.info` reports `Paused`, then send `PUT /api/v1/vm.resume`. Copy mode leaves all memory resident and backed by transparent huge pages, so the guest answers 0.2 ms after the resume call returns. The resume call itself takes 1.45 ms. Each pooled VM holds its full 256 MiB.

## A full-featured guest kernel

The speed came from removing a handful of boot stalls, not from removing features. The `full` kernel keeps what a general-purpose VM needs. It costs 3.6 ms more than `tiny` on a Firecracker cold boot, 5.3 ms more on Cloud Hypervisor, and almost nothing on a restore.

`full` starts from `min`, which keeps cgroups, namespaces, overlayfs, FUSE, virtio-fs, vsock, io_uring, SysV IPC, VMGenID and virtio-mem. It adds back:

- nftables and iptables with NAT and conntrack, IPv6, bridge, veth, TUN, VXLAN, WireGuard, VLAN, macvlan, ipvlan and traffic control
- BPF with the JIT, which needs loadable-module support
- loop devices, created on demand instead of eight at boot; XFS, EROFS and squashfs; hugetlbfs
- PCI hotplug, so Cloud Hypervisor can hot-add disks

| Case | `tiny` | `full` | `full-mit` |
| --- | --- | --- | --- |
| Firecracker cold boot, initramfs | 17.1 ms | 20.7 ms | 26.9 ms |
| Firecracker cold boot, ext4 rootfs | 18.0 ms | 22.0 ms | 29.0 ms |
| Firecracker warm start, new VMM process | 7.4 ms | 7.7 ms |  |
| Cloud Hypervisor cold boot, initramfs | 22.4 ms | 27.8 ms | 34.0 ms |
| Cloud Hypervisor cold boot, ext4 rootfs | 24.7 ms | 30.9 ms | 36.5 ms |
| Cloud Hypervisor warm start, new VMM process | 13.3 ms | 15.0 ms |  |

Medians of 30 runs. A profiled `full` boot showed no new stalls: each added feature initializes in well under a millisecond (IPv6 0.3 ms, XFS 0.3 ms). In-guest speculation mitigations add about 6 ms to every cold boot, from patching kernel code at boot, and nothing to a restore, where that patching is already done.

`full` still leaves out keyboard and VT drivers, legacy PC hardware, SCSI, the jitter-entropy self-test, the ACPI PM timer, LSMs and audit, NFS, Btrfs, and kernel tracing (ftrace, kprobes, BTF). Any of these can come back if a workload needs it; their boot cost is unmeasured.

## Launching customer code on restore

A static C program can be running inside a restored clone 2.2–2.3 ms after the host decides to start it, using a pre-restored paused VM and the `full` kernel. Starting from a new VMM process it takes 9.1 ms on Firecracker and 15.1 ms on Cloud Hypervisor. `fast-start/supervisor/` holds the code; its README documents the protocol.

The supervisor is a static PID 1, and every snapshot is taken while it waits for the host:

1. On boot it mounts `/dev`, `/proc` and tmpfs, configures the network, and listens on vsock port 1024.
2. A `PREPARE` request reads the customer's files into the guest page cache. The host then snapshots the VM while the supervisor waits in `accept()`.
3. After a restore, the host sends `START` with argv, env vars, its current time and a random seed. The supervisor sets the wall clock, reseeds the kernel RNG, drops the cached gateway MAC, and launches the customer's process with exactly that env.

The customer's process starts after the restore, so it seeds its own PRNGs from the reseeded kernel and opens every connection fresh. Secrets and per-instance IDs arrive only in `START`, never in the snapshot.

| T0 is when the host... | Firecracker, C | Firecracker, Python | Cloud Hypervisor, C | Cloud Hypervisor, Python |
| --- | --- | --- | --- | --- |
| spawns the VMM and boots (no snapshot) | 20.4 ms | 50.7 ms | 27.5 ms | 63.8 ms |
| spawns the VMM and restores | 9.1 ms | 41.6 ms | 15.1 ms | 61.8 ms |
| restores into an already-running VMM | 8.1 ms | 40.0 ms | 13.5 ms | 60.3 ms |
| resumes an already-restored, paused VM | 2.2 ms | 25.0 ms | 2.3 ms | 24.9 ms |

Medians of 20 runs on the `full` kernel; on `tiny`, cold boots took 4–8 ms less, restores 0–9 ms less (the most for Python on Cloud Hypervisor), and paused resumes stayed within 0.5 ms. The clock stops at the customer's process's first report: a UDP packet from the C program, or the first HTTP response from a Python `http.server`. Here the customer's files are baked into the snapshot; the next section attaches them after restore.

Launching a static binary costs about 1 ms after a fresh restore and under 0.5 ms from a paused pool. The clock, RNG and network fixes take about 50 µs once memory is resident. Python's own startup takes 21–23 ms even in the best tier, and on-demand page faults stretch it to 30–45 ms. Heavy runtimes gain little from launching on restore. They need one snapshot per env config, or a hook that reads config after restore.

A clone check confirmed the fixes. One snapshot was restored three times, each clone behind a newly created TAP, on the `tiny` kernel without VMGenID:

- Every child reported its own env-provided ID and reached the host through its new TAP.
- The three random values differed on both VMMs.
- Clocks that were 2.1–2.4 s stale came within 0.6–1.8 ms of the host.

In a control run without the clock and seed in `START`, all three clones drew identical random bytes and stayed 2.1–2.3 s behind.

## Building fast-starting Linux VMs

To start a full Linux VM on a tenant's OCI image in milliseconds, never boot it. Restore a generic base VM that has already booted, with the tenant's image already in place as its disk. On the `full` kernel, a tenant's static binary runs 10.7 ms after the request on Firecracker and 15.9 ms on Cloud Hypervisor, including starting the VMM process. Cold-booting a tenant's disk takes 21.9 ms and 30.8 ms.

Prepare one base snapshot per VM shape, and rebuild it only when the kernel or supervisor changes:

1. Boot the `full` kernel with the supervisor as PID 1 from a small initramfs. Give it a disk at a fixed host path: a symlink to an empty, sparse placeholder of a fixed size (512 MiB here).
2. Snapshot it while the supervisor waits on vsock. The snapshot holds no tenant data, so every tenant shares it.

To start a tenant VM:

1. Point the disk's symlink at the tenant's image.
2. Start the VMM and restore the base snapshot. The VMM opens the tenant's image while it restores, and the guest finds it on the same device, at the same size, that it saw at snapshot time.
3. Send `START` with the image's entrypoint, env and working directory, the platform's own env, the time and a random seed.
4. The supervisor sets the clock and reseeds the kernel RNG. It mounts the image read-only, under a tmpfs overlay if the root should be writable, switches root into it, and launches the entrypoint. It stays PID 1 to reap processes and handle shutdown.

OCI images need one conversion per image, not per start. `fast-start/supervisor/oci_to_disk.sh` flattens an image into EROFS or ext4 and records its entrypoint, env and working directory. It also adds the mount points the supervisor needs, so even a `FROM scratch` image with one static binary runs.

| Restoring a base VM for an OCI image | Firecracker, static binary | Firecracker, Python | Cloud Hypervisor, static binary | Cloud Hypervisor, Python |
| --- | --- | --- | --- | --- |
| Attach an ext4 image after the restore, overlay | 12.6 ms | 63.2 ms | 23.3 ms | 81.5 ms |
| EROFS image in place before the restore, overlay | 10.7 ms | 60.5 ms | 15.9 ms | 74.6 ms |
| EROFS image in place before the restore, read-only root | 10.6 ms | 59.8 ms | 16.6 ms | 76.7 ms |

Medians of 20 runs on the `full` kernel; the clock starts before the VMM process does. The static binary is a `FROM scratch` image. Python is `python:3.12-slim` running an HTTP server, with its bytecode compiled during conversion; the image ships none, and as shipped it took 173 ms instead of 63 ms. From a pool of paused base VMs, the static binary runs in 3.4 ms on Firecracker, and in 3.3 ms on Cloud Hypervisor with a device-mapper swap and expedited RCU (below).

The design rests on these choices:

- **Keep the kernel full-featured.** The restore path skips the kernel's boot, so its features cost almost nothing at start time.
- **Fix the vCPU count per snapshot.** It is baked into the snapshot, and Firecracker cannot hot-add vCPUs, so keep one base per vCPU count. Grow memory after restore with virtio-mem, which `full` supports (Firecracker 1.16 `/hotplug/memory`; the repo's `memory-hotplug/` demos). This was not measured here.
- **Give each VM its own network namespace** with the same guest IP and MAC, so restored clones need no guest network changes. The supervisor still drops the cached gateway MAC.
- **Put the tenant's image in place before restoring.** Pointing the base VM's disk path at the image costs nothing on the host and spares Cloud Hypervisor its PCI hot-add, which took 5–7 ms. Firecracker's own drive swap (`PATCH /drives`) takes 0.15 ms, so there it changes little. Images must share the placeholder's size: pad them sparsely, or keep a base snapshot per size class. Each concurrent VM also needs its own disk path; Firecracker's jailer gives each VM its own chroot, and Cloud Hypervisor would need a mount namespace per VMM.
- **Ship images as EROFS without inline tails.** On a freshly restored guest, EROFS mounts in 0.6–1.3 ms and ext4 in 2.4–3.2 ms, and EROFS images are about 25% smaller. With mkfs.erofs's default inline tails, Python started 3–4 ms slower; `-Enoinline_data` fixes that.
- **Choose the overlay for what it allows.** The tmpfs overlay takes 0.3–0.4 ms to mount, within the run-to-run noise. Without it the root is read-only, and only `/tmp`, `/run`, `/dev` and attached volumes are writable. Persistent data belongs on a second, writable volume.
- **For a paused pool on Cloud Hypervisor, swap a device-mapper table.** The base VM's disk is a device-mapper device that the host points at the tenant's image through a loop device. That cut the paused start from 7.8 ms with hot-add to 3.3 ms, but only with `/sys/kernel/rcu_expedited` set to 1, a host-wide setting: by default the swap waits 4–5 ms for RCU grace periods. Reads through the loop device also add 4–17 ms to Python's start, so on the restore path the device-mapper swap never beat the path swap.
- **Get clone safety from `START`:** the clock, an RNG reseed, and a tenant process that starts only after restore. The `full` kernel's VMGenID support also reseeds the kernel on Firecracker restores.

Trimming host round trips beyond the attach gained nothing measurable. Sending `START` in the same write as the vsock `CONNECT` line changed totals by less than the noise, and expedited RCU left the VMMs' own restore time unchanged. The host-side waits that remain are Firecracker's process start until its API socket answers (1.2 ms) and Cloud Hypervisor's restore before the guest answers on vsock (9–12 ms).

Not built yet, and so unmeasured:

- the pool manager and its refill policy
- per-VM jails (Firecracker's jailer), which also give each VM its own disk path, and cgroup limits
- network namespace setup
- writable persistent volumes
- the OCI `USER` setting (every image runs as root)
- `/etc/resolv.conf` and `/etc/hosts` injection
- tenant console and log streaming
- base snapshots with more than one vCPU

## Caveats, dead ends, and next steps

These changes saved 1 ms or less, or made starts slower, so the final configurations leave them out:

- `mitigations=off` on the stock kernels (the boot-time patching still runs; only a rebuilt kernel skips it)
- `acpi_pm_good`, `rcupdate.rcu_expedited=1`, and `no-kvmapf`
- 128 MiB of guest memory instead of 256 MiB
- waiting 3 s instead of 0.5 s before taking the snapshot
- a kernel without ACPI for Firecracker (18.9 ms vs 19.3 ms); Cloud Hypervisor cannot boot it
- Firecracker's `--enable-pci` with Cloud Hypervisor's kernel: 83 ms, slower than virtio-mmio

Keep these limits in mind when applying the results:

- **Real workloads add their own startup.** `fastinit` configures one NIC and answers UDP. An application, a language runtime, or a service manager adds its time on top.
- **The trimmed kernels drop in-guest speculation mitigations.** That suits one tenant per VM. Turning them back on (`full-mit`) adds about 6 ms to a cold boot and nothing to a restore. Host-side mitigations are unchanged.
- **Host setup is required.** Firecracker hugepages need `vm.nr_hugepages` reserved, and the THP tmpfs needs a root mount.
- **Pin the VMM to P-cores.** Unpinned or on E-cores, the same runs took 15–35% longer. The CPU governor stayed at its default (`powersave`, `balance_performance`), so a `performance` governor may help further.
- **Pools trade memory for latency.** A pre-copied or copy-mode paused VM holds its full 256 MiB.

**Cold boots slow down when their files leave the page cache.** Evicting the kernel, initramfs or rootfs, and VMM binary before each boot gave these medians on the tiny kernel (20 runs each):

| Cold boot | Files cached | Files evicted |
| --- | --- | --- |
| Firecracker, new process | 17.0 ms | 27.1 ms |
| Firecracker, pre-spawned VMM | 15.6 ms | 18.8 ms |
| Firecracker, ext4 rootfs | 17.9 ms | 28.9 ms |
| Cloud Hypervisor, new process | 21.7 ms | 35.4 ms |
| Cloud Hypervisor, pre-spawned VMM | 19.0 ms | 23.4 ms |
| Cloud Hypervisor, ext4 rootfs | 25.2 ms | 40.1 ms |

Most of the penalty comes from paging the VMM binary in from disk on exec, about 7 ms for Firecracker and 9 ms for Cloud Hypervisor. Reading the 20 MB `tiny` kernel adds 3–4 ms; the 44 MB stock 6.1 kernel adds about 7 ms. On a busy host these files stay cached because every VM shares them. To guarantee that, keep them on tmpfs or lock them in memory (for example `vmtouch -l`). The warm-start figures also assume a cached VMM binary; their sections give separate numbers for snapshots evicted from cache.

Worth doing next:

- [ ] Fold the harness fixes (direct API calls, UDP readiness, no serial console) into the existing `with_snapshot` demo scripts.
- [ ] Find why Firecracker's `KVM_CREATE_VCPU` waits about 2 ms on SRCU when Cloud Hypervisor's does not.
- [x] Measure a real application: Python adds 21–23 ms from a snapshot that baked its files in, and about 40 ms from an attached OCI image.
- [ ] Build what the Fly-style design still lacks, starting with per-VM jails, which give each restore its own disk path, and network namespaces.

## How to reproduce

Everything lives in `fast-start/` in the repo; `fast-start/README.md` lists the prerequisites. `setup.sh` fetches the pinned VMMs and guest kernels and builds everything else. `reproduce.sh` reruns one group of measurements with the host settings it needs, and writes each configuration's median, p90 and every run to `fast-start/work/repro/<group>.jsonl`.

```bash
cd fast-start
./setup.sh
sudo ./reproduce.sh kernels    # one group; `all` runs every group, several hours
```

| Report section | `reproduce.sh` groups |
| --- | --- |
| Summary; A full-featured guest kernel | `kernels` |
| The four step tables | `steps`, plus `repo-scripts` for the repo-script rows |
| Cold boots with files evicted (caveats) | `pagecache` |
| The profiled `full` boot | `profile` |
| Launching customer code on restore | `supervisor`, `supervisor-tiny`, `clones` |
| Building fast-starting Linux VMs | `rootfs`, `rootfs-rcu`, `rootfs-pipeline`, `erofs-inline`, `erofs`, `erofs-rcu`, plus `supervisor` for the cold boots and Python as shipped |

The repo-script rows have 5 runs, so their p90 is the slowest run. Some figures come from exploratory runs whose results were not kept: the dead ends listed under the caveats, `max_loop=1` on the 5.10 kernel, Cloud Hypervisor's `hugepages=on`, the unpinned slowdown, and a repeat of the step runs after a fresh `setup.sh`, which matched within about 1 ms. The stalls found in the stock kernels (528 ms of i8042 probing, 530 ms when Cloud Hypervisor gets the i8042 flags, 89 ms of `loop_init`) and the other figures read from traces were exploratory too; `fast-start/tools/README.md` shows how to retrace them. This file is an export of the shared report; the shared version draws the step tables as charts.
