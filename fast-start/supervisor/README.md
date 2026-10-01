# Supervisor: launch customer code on restore

`supervisor` is a static PID 1 for microVMs that are prepared once, snapshotted,
and restored many times. After a restore it receives the customer's argv and
env vars over vsock, makes the clone unique, optionally switches root into the
customer's own disk, and launches the customer's process. Nothing per-instance
ever lands in the snapshot.

## Lifecycle

1. **Boot and prepare.** The supervisor mounts `/dev`, `/proc`, `/sys`, `/run`
   and `/tmp`, brings up `lo` and `eth0` with a default route, and listens on
   vsock port 1024. The host sends `PREPARE` with paths to read (`warm=`) and
   shell commands to run (`warmrun=`), so the customer's files sit in the
   guest page cache.
2. **Snapshot.** The host closes the connection, pauses the VM, and snapshots
   it while the supervisor waits in `accept()`.
3. **Restore and start.** The host restores, optionally attaches the
   customer's disk, connects, and sends `START`. The supervisor:
   - sets `CLOCK_REALTIME` from the host's time;
   - mixes the host's 32-byte seed into the kernel RNG and forces a reseed
     (`RNDADDENTROPY` + `RNDRESEEDCRNG`);
   - drops the cached gateway MAC, since a clone may sit behind a new TAP;
   - sets the hostname, if given;
   - with `rootfs=`, waits for that disk to appear at its expected size, drops
     any blocks cached from a placeholder (`BLKFLSBUF`), and mounts it
     read-only. By default a tmpfs overlay makes the whole tree writable; with
     `rootfs_overlay=0` the image is the root as it stands, and only `/tmp`,
     `/run` and `/dev` are writable. It then moves `/dev`, `/proc`, `/sys`,
     `/run` and `/tmp` into the new root and switches root the way
     `switch_root` does;
   - `posix_spawn`s argv in a new session with exactly the given env (plus a
     default `PATH`). The customer's process starts after the restore, so it
     seeds its own PRNGs from the reseeded kernel and opens every connection
     fresh.

   It replies with the child's pid and how long each step took. `START` is
   accepted once per boot.

## Protocol

The host reaches guest port 1024 through the VMM's vsock Unix socket: connect,
send `CONNECT 1024\n`, read `OK ...\n`. Each request and reply is a 4-byte
big-endian length followed by NUL-terminated `key=value` records:

| Request | Records |
| --- | --- |
| `cmd=PREPARE` | `warm=<path>` (file or directory, repeatable), `warmrun=<shell command>` (repeatable) |
| `cmd=START` | `time_ns=<unix ns>`, `seed=<hex>`, `env=K=V` and `arg=<argv element>` (repeatable), optional `cwd=`, `hostname=`, `rootfs=<device>`, `rootfs_size=<bytes>`, `rootfs_fs=<type>` (default `ext4`), `rootfs_opts=<mount options>`, `rootfs_overlay=0` |
| `cmd=PING` | none |

Replies carry `status=ok` or `status=error` plus `error=`. `ctl.py` implements
the host side: `connect()`, `prepare()`, `start()`. `connect(..., send=...)`
sends a request in the same write as the `CONNECT` line instead of waiting for
the VMM's `OK`; it measured no faster.

Boot parameters, read from init's environment: `sv_ip`, `sv_mask`, `sv_gw`
(default `172.16.0.2`, `255.255.255.252`, `172.16.0.1`) and `sv_port` (`1024`).

## Giving a restored base VM the customer's disk

A generic base snapshot holds only the kernel and the supervisor. The
customer's disk arrives after T0 in one of three ways; `bench_supervisor.py`
calls them `path`, `hotadd` and `dm`:

- **Point the disk path at the image before restoring (`path`).** The base VM
  boots with a disk at a fixed host path, a symlink to an empty placeholder.
  Before each restore, the host points that symlink at the customer's image;
  the VMM opens the image while it restores, and the guest finds it on the
  same device it saw at snapshot time. It works on both VMMs and costs nothing
  on the host. Two conditions:
  - Every image has the placeholder's size, so the guest never sees a
    capacity change. The harness pads a copy of each image with sparse zeros
    (`../work/slot/`); a host with mixed sizes would keep a base snapshot per
    size class.
  - Each concurrent VM needs its own path. Firecracker's jailer gives each VM
    its own chroot, so the same path resolves per VM; for Cloud Hypervisor, a
    mount namespace per VMM or a per-restore copy of the snapshot's
    `config.json` would do. Neither is built here.
- **Attach a disk after the restore (`hotadd`).** Firecracker swaps a 1 MiB
  placeholder drive's backing file with `PATCH /drives/tenant` (0.15 ms); the
  guest sees a capacity change on `/dev/vda`. Cloud Hypervisor hot-adds a PCI
  disk with `vm.add-disk` after polling `vm.info` until the restore finishes;
  the guest kernel needs `HOTPLUG_PCI_ACPI`. That costs 5–7 ms.
- **Swap a device-mapper table (`dm`).** The base VM's disk is a
  device-mapper device (`dmslot.py`). The host loads a new table pointing it at
  the customer's image through a read-only loop device, so a running or paused
  VMM keeps its open device. The swap waits for RCU grace periods: 4–5 ms by
  default, 0.1–0.6 ms with `/sys/kernel/rcu_expedited` set to 1, a host-wide
  setting. Reads through the loop device are slower than reads of the image
  file, which adds 4–17 ms to Python's own start.

`START` then names the device and its size, so the supervisor can wait for the
right disk. With `path` and `dm` the size already matches.

## Running OCI images

Any OCI image works as the customer's disk. `oci_to_disk.sh <image> <out>`
flattens it with `docker export` and writes `<out>.json` with the image's argv
(Entrypoint + Cmd), env and working directory. The host sends those in `START`,
with its own env vars layered on top. The output's extension picks the
filesystem:

- `.erofs` (the faster choice): built by `mkfs.erofs -Enoinline_data` in the
  `fast-start-mkfs` Docker image from `oci/mkfs/`. The precompiled Python image
  takes 141 MiB as EROFS and 185 MiB as ext4. With mkfs.erofs's default inline
  tails (`EROFS_INLINE=1`), Python started 3–4 ms slower.
- `.ext4`: built by `mkfs.ext4 -d`, with no loop mount.

The converter adds empty `/dev`, `/proc`, `/sys`, `/run` and `/tmp`, so the
image can serve as the root without an overlay. The image needs no init or
kernel, so even `FROM scratch` images run. `USER` is not applied yet: every
image runs as root.

`oci/build.sh` builds the three test images used below, in both formats:
`python:3.12-slim` with the HTTP server, the same image with its bytecode
precompiled, and a `FROM scratch` image holding only the C probe. It also
builds inline-tail EROFS copies of the last two, for comparison.

## Files

- `supervisor.c`: the PID 1.
- `ctl.py`: host-side client.
- `child_probe.c`, `py_child.py`: test children. Each reports its
  `INSTANCE_ID`, a random value and its wall clock: the C probe over UDP, the
  Python one as an HTTP response.
- `build.sh`: builds into `../work`:
  - `initramfs-supervisor.cpio`: supervisor as `/init`, plus the C probe;
  - `ubuntu-supervisor.ext4`: the demo Ubuntu rootfs plus `/supervisor`, the C
    probe and `py_child.py`. Boot it with `init=/supervisor`; it also serves as
    the customer disk in the attach tiers;
  - `placeholder.img`: the 1 MiB stand-in drive.

  `../setup.sh` runs it.
- `oci_to_disk.sh`, `oci/`: OCI image to EROFS or ext4 conversion, the
  `mkfs.erofs` Docker image, and the test images.
- `dmslot.py`: the device-mapper slot used by the `dm` attach mode.
- `bench_supervisor.py`: timing matrix and clone checks. Its `SETS` name the
  variants each `../reproduce.sh` group runs.
- `../reproduce.sh` groups `supervisor`, `supervisor-tiny` and `clones` rerun
  the tiers and clone checks below; `rootfs`, `rootfs-rcu`, `rootfs-pipeline`,
  `erofs-inline`, `erofs` and `erofs-rcu` rerun the OCI tables.

## Results

Medians of 20 runs, 1 vCPU, 256 MiB, VMM pinned to P-cores. The clock starts at
T0 and stops when the host hears from the customer's process: a UDP report from
the C probe, or the first HTTP response from the Python server.

### Customer files baked into the snapshot

| T0 is when the host... | Firecracker, C | Firecracker, Python | Cloud Hypervisor, C | Cloud Hypervisor, Python |
| --- | --- | --- | --- | --- |
| spawns the VMM and boots (no snapshot) | 20.4 ms | 50.7 ms | 27.5 ms | 63.8 ms |
| spawns the VMM and restores | 9.1 ms | 41.6 ms | 15.1 ms | 61.8 ms |
| restores into an already-running VMM | 8.1 ms | 40.0 ms | 13.5 ms | 60.3 ms |
| resumes an already-restored, paused VM | 2.2 ms | 25.0 ms | 2.3 ms | 24.9 ms |

These use the `full` kernel. With the `tiny` kernel, the same rows measured
16.6 / 8.8 / 7.6 / 2.7 ms (Firecracker, C) and 23.3 / 13.1 / 11.4 / 2.1 ms
(Cloud Hypervisor, C). The kernel's extra features cost about 4 ms on a cold
boot and 0–2 ms once restoring.

### Generic base snapshot plus the customer's disk

The customer's files live on their own disk: `ubuntu-supervisor.ext4`, a stock
Ubuntu 22.04 image. The base snapshot holds no customer files, so the guest page
cache starts empty for them.

| T0 is when the host... | Firecracker, C | Firecracker, Python | Cloud Hypervisor, C | Cloud Hypervisor, Python |
| --- | --- | --- | --- | --- |
| spawns the VMM and boots the customer disk (no snapshot) | 21.9 ms | 50.7 ms | 30.8 ms | 63.8 ms |
| spawns the VMM, restores the base, attaches the disk | 11.6 ms | 54.3 ms | 23.2 ms | 72.0 ms |
| resumes a paused base VM and attaches the disk | 3.4 ms | 35.0 ms | 8.2 ms | 37.2 ms |

Mounting the disk and switching root takes about 0.8 ms on Firecracker. Cloud
Hypervisor's hot-add costs several ms more, mostly the guest probing the new
PCI device on its single vCPU. Python reads its files from the disk here, which
adds 10–12 ms over the snapshot that baked them in.

### OCI images on a restored base VM

T0 is when the host starts a new VMM process. The host then gives the VM the
image, restores the base snapshot, and sends `START`. The static binary is the
`FROM scratch` image; Python is `python:3.12-slim` with precompiled bytecode.

| Disk arrives by, filesystem | Firecracker, static binary | Firecracker, Python | Cloud Hypervisor, static binary | Cloud Hypervisor, Python |
| --- | --- | --- | --- | --- |
| Drive swap or hot-add, ext4 + overlay | 12.6 ms | 63.2 ms | 23.3 ms | 81.5 ms |
| Drive swap or hot-add, EROFS read-only | 10.8 ms | 59.2 ms | 21.0 ms | 78.0 ms |
| Path swap, ext4 + overlay | 12.4 ms | 62.6 ms | 17.9 ms | 81.1 ms |
| Path swap, EROFS + overlay | 10.7 ms | 60.5 ms | 15.9 ms | 74.6 ms |
| Path swap, EROFS read-only | 10.6 ms | 59.8 ms | 16.6 ms | 76.7 ms |
| dm swap, EROFS read-only | 16.5 ms | 80.0 ms | 24.8 ms | 88.8 ms |
| dm swap, EROFS read-only, expedited RCU | 11.0 ms | 70.2 ms | 16.8 ms | 82.3 ms |

The ext4 rows come from the `rootfs` group, the EROFS rows from `erofs`, and
the expedited-RCU row from `erofs-rcu`. Configurations are named
`<vmm>_<c|py>_oci_<hotadd|path|dm>_<fs>_<overlay|ro>_restore`.

- **Path swap** removes Cloud Hypervisor's hot-add: the host no longer waits
  for the restore to finish before attaching, and the guest probes no new
  device. On Firecracker the drive swap already cost only 0.15 ms.
- **EROFS** mounts in 0.6 ms on a freshly restored Firecracker guest and
  1.1–1.3 ms on Cloud Hypervisor; ext4 takes 2.4–3.2 ms.
- **The overlay** costs the guest 0.3–0.4 ms to mount, within the run-to-run
  noise of these totals. Choose it for the semantics: a writable root, or a
  read-only root with writable `/tmp`, `/run` and extra volumes.
- **dm swap** loses on the restore path. With default RCU the swap alone takes
  4–5 ms, and Python's reads through the loop device add 4–17 ms.

With a paused base VM (static binary, EROFS read-only, T0 at resume):

| Disk arrives by | Firecracker | Cloud Hypervisor |
| --- | --- | --- |
| Drive swap or hot-add | 3.4 ms | 7.8 ms |
| dm swap | 7.6 ms | 8.9 ms |
| dm swap, expedited RCU | 4.2 ms | 3.3 ms |

These are the `_paused` rows of the `erofs` and `erofs-rcu` groups. A dm swap with expedited RCU replaces Cloud Hypervisor's
hot-add in a paused pool, at the cost of a host-wide RCU setting and slower reads through the loop
device.

Host round trips beyond the attach itself gave nothing measurable:

- sending `START` with the vsock `CONNECT` line changed totals by less than the
  noise;
- expedited RCU left the VMMs' own restore time unchanged.

The remaining host-side waits are Firecracker's process start until its API
socket answers (1.2 ms; a pre-spawned VMM removes it) and Cloud Hypervisor's
restore before the guest answers on vsock (9–12 ms).

The official Python images ship no `.pyc` files (1,097 `.py` files, zero
compiled), so every start recompiles the standard library. As shipped,
`python:3.12-slim` took 143 ms from a paused Firecracker base and 173 ms from a
restore (ext4, drive swap); running `python3 -m compileall` on the image before
flattening it brought those to 40 and 63 ms. Conversion is the place for this
kind of fix: it runs once per image, not once per start.

Each row uses the fastest memory setup from `../README.md`:

- Firecracker cold boots and paused pools run on 2 MiB hugepages; the pool
  pre-copies memory with `uffd_populate`.
- Firecracker restores read the memory file from a `huge=always` tmpfs.
- Cloud Hypervisor restores on demand, and its pool uses copy mode.

The clock, reseed and network fixes take about 50 µs when memory is already
resident. Python's own startup takes 21–23 ms even in the best case, so heavy
runtimes gain little from launching on restore. Give them one snapshot per env
config, or a runtime hook that reads config after restore.

The result files also split each run into VM, `START` and child phases. With
the `full` kernel the child sometimes runs before the supervisor's reply reaches
the host, which makes that split unreliable; the totals above are not affected.

### Clone safety

`bench_supervisor.py clones` restores one snapshot three times, behind a newly
created TAP each time. It uses the `tiny` kernel, which has no VMGenID support.
On both VMMs and with both children:

- every child reported its own `INSTANCE_ID`;
- the three random values differed;
- clocks that were 2.1–2.4 s stale came within 0.6–1.8 ms of the host;
- the child reached the host through the new TAP.

`clones-control` sends `START` without the clock and seed. All three clones
then drew identical random bytes, and their clocks stayed 2.1–2.3 s behind.

The gateway-MAC flush has not been tested on its own. The clone checks pass
with it, but they don't show what happens without it.
