# Firecracker + Cloud Hypervisor Host-Swap Overcommit Demo

This demo boots four VMs into one shared host cgroup pool:

- `fc0`, `fc1`: Firecracker
- `ch0`, `ch1`: Cloud Hypervisor
- each VM: 6 GiB visible guest RAM
- parent pool: `memory.high=8GiB`, `memory.max=9GiB`
- host swap: encrypted dm-crypt swap, capped by cgroup at 24 GiB

The proof is host-side. Each guest runs a Python process that allocates and
touches real anonymous memory. The host cgroup then shows resident memory and
swap usage for each VMM process.

## Run

```bash
./overcommit-demo/demo.sh install-deps
./overcommit-demo/demo.sh run
```

In another terminal:

```bash
./overcommit-demo/demo.sh watch
```

Cleanup:

```bash
./overcommit-demo/demo.sh stop
```

Runtime state, logs, and copied root filesystems live under:

```text
/var/tmp/learningMicroVMs-overcommit
```

## What Counts As A Pass

The `prove` step checks that:

- all four guests report roughly 6 GiB of RAM
- the parent cgroup remains under the 9 GiB hard resident cap
- parent `memory.swap.current` grows substantially
- Cloud Hypervisor VMs produce cgroup swap in their staged phase
- Firecracker VMs produce cgroup swap in their staged phase
- all VMs remain SSH-responsive

## Hard Truths

- This is host Linux swapping VMM process memory, not a Firecracker-only or
  Cloud-Hypervisor-only storage tier.
- `memory.max=9GiB` is a resident memory cap. cgroup v2 accounts swap
  separately through `memory.swap.max`.
- Secure swap means encrypted host swap at rest. It does not protect against a
  compromised live host, host root, or a compromised host kernel.
- The demo disables existing host swap while it runs and refuses to call the
  setup secure if any non-demo swap is active.
- The Firecracker jailer is not used here; this demo proves real memory
  overcommit/tiering, not a complete production isolation profile.
