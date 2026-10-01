# Tracing tools

The scripts used to find where start time went. Each `.bt` script needs
bpftrace and root, and follows the most recently started `firecracker` or
`cloud-hypervisor` process. The reports read the last VMM in the trace.
`bench.py` boots each configuration once untimed before measuring it, so with
one run the last VMM is the timed boot.

| Script | What it records | Report |
| --- | --- | --- |
| `trace.bt` | VM creation, first `KVM_RUN`, port 0x80/0x3f0 writes, EPT faults and exit counts | read directly |
| `exits.bt` | every VM exit with its guest RIP | `symprof.py` |
| `sys.bt` | time in each VMM syscall and KVM ioctl, page faults, userfaults; prints calls over 200 µs | `sysrep.py` |
| `vcpu.bt` | Firecracker's `KVM_CREATE_VCPU` latency with on- and off-CPU kernel stacks | read directly |

Run from `fast-start/`, with hugepages reserved for configurations that use
them (`reproduce.sh` does this; by hand, `sudo sysctl -w vm.nr_hugepages=1024`).
Start bpftrace, wait for its `Attaching` line, run one configuration, then stop
it:

```bash
mkdir -p out
# Where the guest spends its boot, by kernel function:
sudo bpftrace tools/exits.bt > out/exits.out &
sudo CPUS=0,1,2,3,4,5,6,7 python3 bench.py final.json 1 fc_cold_7_tiny_kernel
sudo pkill -INT -x bpftrace
python3 tools/symprof.py out/exits.out work/vmlinux-tiny [top-n] [timeline]

# Which VMM syscalls and ioctls take the time:
sudo bpftrace tools/sys.bt > out/sys.out &
# ...run one configuration, stop bpftrace...
python3 tools/sysrep.py out/sys.out [pid] [top-n]
```

`symprof.py` attributes the time between consecutive exits to the function at
the later exit's RIP; give it the `vmlinux` that booted. A fourth argument
prints a 2 ms timeline. `sysrep.py` reports the highest pid that created a VM
unless given one.

`gaps.py` ranks the slowest steps in a guest kernel log. Boot with
`initcall_debug fi_dmesg=1` and a `dmesg` path in the experiment, and
`fastinit` sends the log to the host. `profile-full.json` does this for the
`full` kernel (`sudo ./reproduce.sh profile` runs it):

```bash
sudo CPUS=0,1,2,3,4,5,6,7 python3 bench.py profile-full.json 3
python3 tools/gaps.py /dev/shm/vmbench/fc-full.dmesg [top-n]
python3 tools/gaps.py /dev/shm/vmbench/ch-full.dmesg [top-n]
```

The stalls in the stock kernels show up the same way. In a copy of
`profile-full.json`, set the Firecracker entry's `kernel` to `fc61` to see the
528 ms i8042 probe (the step runs avoid it with `i8042.noaux i8042.nomux
i8042.nopnp i8042.dumbkbd`) or to `fc510` to see 5.10's 89 ms `loop_init`. Set
the Cloud Hypervisor entry's `kernel` to `fc61` and add those `i8042.*` flags
to see its 530 ms stall.

With `fi_bt=1` on the kernel command line, `fastinit` writes one byte to port
0x3f0 as it starts, so `trace.bt` and `exits.bt` mark when init began.
