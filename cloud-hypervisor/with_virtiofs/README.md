# Cloud Hypervisor Virtio-fs Demo

This demo mounts a host directory inside the guest with Cloud Hypervisor's
virtio-fs support.

```bash
./spawn.sh
```

The script:

1. Starts `virtiofsd` for `shared/`.
2. Boots Cloud Hypervisor with `--memory size=1024M,shared=on`.
3. Attaches the shared directory with `--fs tag=hostshare,...`.
4. Mounts it in the guest at `/mnt/hostshare`.
5. Verifies host-to-guest and guest-to-host file writes.
6. Stops the VM, TAP device, and `virtiofsd`.

If a run is interrupted, clean up with:

```bash
./stop.sh
```

Useful overrides:

```bash
SHARE_DIR=/tmp/ch-share FS_TAG=hostshare ./spawn.sh
VIRTIOFSD_BIN=/path/to/virtiofsd ./spawn.sh
```
