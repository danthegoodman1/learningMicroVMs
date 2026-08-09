# Custom Rust Virtio-fs Proxy Demo

This demo replaces stock `virtiofsd` with a small Rust daemon that wraps
`virtiofsd::passthrough::PassthroughFs`. The wrapper forwards filesystem
operations to the normal passthrough implementation while logging selected
requests.

```bash
./spawn.sh
```

The quick script:

1. Builds `custom-virtiofsd`.
2. Boots Cloud Hypervisor with shared memory enabled.
3. Starts the custom vhost-user virtio-fs daemon.
4. Hotplugs it with `ch-remote add-fs`.
5. Mounts it in the guest at `/mnt/hostshare`.
6. Verifies host-to-guest read, guest-to-host write, and wrapper logs.
7. Unmounts, removes the device, and cleans up the VM, TAP, socket, and daemon.

To also prove the custom daemon works across Cloud Hypervisor
snapshot/restore, run:

```bash
./snapshot_restore.sh
```

That script mounts the custom virtio-fs device, writes a file, pauses and
snapshots the VM, stops the source VM, restores the VM, and verifies
`/mnt/hostshare` is still mounted without remounting. The shared host directory
is not part of the VM snapshot, so the same `shared/` directory must remain
available for restore.

The snapshot runner is intentionally strict: it does not hide restore failures
by remounting the filesystem. If Cloud Hypervisor cannot resume the VM with the
virtio-fs device active, the script fails and points at the daemon log entries
for `serialize` and `deserialize_and_apply`.

`custom-virtiofsd` vendors the `virtiofsd` 1.13.2 crate with updated vhost-side
dependencies and two explicit-lifetime fixes. See
[`custom-virtiofsd/vendor/README.md`](custom-virtiofsd/vendor/README.md) for
the source archive checksum and exact changes. Keeping this small source copy
in-tree makes the snapshot/restore demo reproducible.

If a run is interrupted, clean up with:

```bash
./stop.sh
```

Useful overrides:

```bash
SHARE_DIR=/tmp/custom-vfs FS_TAG=hostshare ./spawn.sh
CARGO_BIN=/path/to/cargo ./spawn.sh
WORK_DIR=/tmp/custom-vfs-work ./snapshot_restore.sh
```

For safety, `SNAPSHOT_DIR` must resolve to a child of `WORK_DIR`. The scripts
use a dedicated `tap-custom-vfs` interface and comment-tagged firewall rules;
cleanup removes only those rules and restores the previous `ip_forward` value.
