# Custom Rust virtio-fs QEMU hotplug demo

This reuses the Rust vhost-user backend from the Cloud Hypervisor demo and
connects it to QEMU:

```bash
sudo apt-get install libcap-ng-dev
./spawn.sh
```

The script builds the daemon, boots a `q35` VM with shared memfd-backed RAM,
starts the backend, then uses QMP `chardev-add` and `device_add` to hotplug a
`vhost-user-fs-pci` device behind a PCIe root port. It verifies bidirectional
I/O and the wrapper's `lookup`, `read`, and `write` logs before hot-unplugging.

The active mount can also survive a reusable full mapped-RAM snapshot:

```bash
./snapshot_restore.sh
```

That runner starts fresh QEMU and daemon processes for restore and asserts that
the backend logged both `serialize complete` and `deserialize_and_apply
complete`. The guest then writes through the still-mounted filesystem without
remounting it.

Use `./stop.sh` after an interrupted run. Overrides include `SHARE_DIR`,
`FS_TAG`, `CARGO_BIN`, and `CUSTOM_VIRTIOFSD_SOCK`.
