# QEMU virtio-fs demo

Run the stock `virtiofsd` host-directory sharing test:

```bash
./spawn.sh
```

The script boots QEMU with shared memfd-backed guest RAM, mounts `shared/` at
`/mnt/hostshare`, verifies host-to-guest and guest-to-host I/O, then stops the
VM and daemon. Use `./stop.sh` after an interrupted run.

Overrides include `SHARE_DIR`, `FS_TAG`, and `VIRTIOFSD_BIN`.
