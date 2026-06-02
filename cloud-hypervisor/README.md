# Cloud Hypervisor TAP Demos

These demos mirror the Firecracker examples with Cloud Hypervisor:

- `spawn.sh` boots a VM with TAP networking, NAT, SSH, DNS, and internet access.
- `with_metadata/spawn.sh` adds a fake IMDS-style service at `169.254.169.254`.
- `with_mounting/spawn_overlay.sh` boots a read-only rootfs with a writable overlay.

## Setup

```bash
./dl_reqs.sh
```

This downloads:

- the latest Cloud Hypervisor static binary
- `ch-remote`
- the latest Cloud Hypervisor guest kernel
- the Ubuntu rootfs and SSH key used by the Firecracker CI demos

The scripts also accept custom rootfs images:

```bash
ROOTFS=/path/to/rootfs.ext4 SSH_KEY=/path/to/id_rsa ./spawn.sh
```

Custom OCI-derived ext4 rootfs images need a working `/sbin/init` and SSH access
for these demo scripts. Cloud-init is optional boot-time provisioning only; runtime
metadata uses the TAP-backed fake IMDS service.

## Base VM

```bash
./spawn.sh
ssh -i ./ubuntu-22.04.id_rsa root@172.16.0.2
```

The guest receives `172.16.0.2`, uses `172.16.0.1` as its gateway, and reaches
the internet through host NAT.
