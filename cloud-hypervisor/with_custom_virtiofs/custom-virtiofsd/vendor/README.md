# Vendored virtiofsd 1.13.2

`virtiofsd-1.13.2-ubuntu/` is derived from the crates.io `virtiofsd` 1.13.2
archive:

```text
https://static.crates.io/crates/virtiofsd/virtiofsd-1.13.2.crate
SHA-256: 3a9b54fcc6a1de125ef205f98a442c0e1d8f52977f21f80889382ec37a3bd14a
```

Only the library sources, normalized manifest, README, and license files needed
to build this demo are retained. Relative to that archive, the retained source
has these changes:

- `vhost` 0.13.0 -> 0.14.0
- `vhost-user-backend` 0.17.0 -> 0.20.0
- `virtio-queue` 0.14.0 -> 0.16
- `vmm-sys-util` 0.12.1 -> 0.14
- Explicit `DirEntry<'_>` return lifetimes in `filesystem.rs` and `read_dir.rs`

The dependency update was developed while comparing Ubuntu 26.04's
`virtiofsd` 1.13.2 package, which builds against vhost 0.14,
vhost-user-backend 0.20, and virtio-queue 0.16. The local vmm-sys-util 0.14
selection is the version resolved by this Cargo dependency graph. Together,
these changes let the wrapper and vendored library share the backend types used
by the snapshot/restore flow. Upstream Apache-2.0 and BSD-3-Clause license files
are retained beside the source.
