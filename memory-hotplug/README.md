# 4 GiB to 6 GiB memory hotplug demo

These three small demos boot a VM with 4 GiB of RAM, start a 2.5 GiB allocation
inside the guest, and run a deliberately simple host-side policy loop:

```text
guest used memory > 2 GiB  ->  request 6 GiB total memory
```

All use `virtio-mem`. The scripts print the guest's `MemTotal` before and after
the resize, then clean up the VM, TAP device, and firewall rules.

## Setup

Linux with KVM, passwordless `sudo`, `curl`, `iptables`, and `ssh` is required.
Download the VMMs, rootfs, SSH key, Cloud Hypervisor kernel, and a Firecracker
kernel with `CONFIG_VIRTIO_MEM=y`:

```bash
./setup.sh
```

The QEMU runner additionally needs `qemu-system-x86_64` (the
`qemu-system-x86` package on Ubuntu).

The regular Firecracker demo kernel in this repository is Linux 5.10 and cannot
run this demo. `setup.sh` additionally downloads Firecracker's Linux 6.1.155 CI
kernel, which has the required memory-hotplug options.

On x86_64, the Firecracker demo also needs at least 40 guest physical-address
bits. Firecracker places its virtio-mem region at GPA `0x8000000000` (512 GiB),
which a 39-bit nested-KVM environment cannot address. `firecracker.sh` checks
this up front and prints a clear error. Cloud Hypervisor's layout does not have
that limitation in this demo.

## Run

```bash
./firecracker.sh
./cloud-hypervisor.sh
./qemu.sh
```

Expected output includes:

```text
Guest started with 4000... MiB visible RAM.
Waiting for guest usage to cross 2048 MiB...
Threshold crossed ...; requesting 6144 MiB...
Success: guest RAM grew from 4000... MiB to 6000... MiB.
```

Useful overrides:

```bash
TRIGGER_USED_MIB=1536 WORKLOAD_MIB=2304 ./firecracker.sh
POLL_INTERVAL_SECONDS=0.25 ./cloud-hypervisor.sh
POLL_INTERVAL_SECONDS=0.25 ./qemu.sh
```

The policy is intentionally educational, not production-ready. A real policy
should use PSI or event-driven guest telemetry, add headroom before allocations
fail, apply cooldowns and hysteresis, enforce a host cgroup ceiling, and handle
partial or refused hot-unplug operations. These demos only scale up once.

The host-side loop is the policy engine: neither VMM decides when to resize on
its own. See the upstream [Firecracker memory-hotplug documentation](https://github.com/firecracker-microvm/firecracker/blob/main/docs/memory-hotplug.md)
and [Cloud Hypervisor hotplug documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/hotplug.md),
plus the [QEMU virtio-mem guide](https://virtio-mem.gitlab.io/user-guide/user-guide-qemu.html),
for the underlying APIs.
