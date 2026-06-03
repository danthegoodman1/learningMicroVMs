# Custom Rust Virtio-fs Proxy Demo

This demo replaces stock `virtiofsd` with a small Rust daemon that wraps
`virtiofsd::passthrough::PassthroughFs`. The wrapper forwards filesystem
operations to the normal passthrough implementation while logging selected
requests.

```bash
./spawn.sh
```

The script:

1. Builds `custom-virtiofsd`.
2. Boots Cloud Hypervisor with shared memory enabled.
3. Starts the custom vhost-user virtio-fs daemon.
4. Hotplugs it with `ch-remote add-fs`.
5. Mounts it in the guest at `/mnt/hostshare`.
6. Verifies host-to-guest read, guest-to-host write, and wrapper logs.
7. Unmounts, removes the device, and cleans up the VM, TAP, socket, and daemon.

If a run is interrupted, clean up with:

```bash
./stop.sh
```

Useful overrides:

```bash
SHARE_DIR=/tmp/custom-vfs FS_TAG=hostshare ./spawn.sh
CARGO_BIN=/path/to/cargo ./spawn.sh
```
