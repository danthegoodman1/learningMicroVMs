# learningMicroVMs

Runnable VMM demos are grouped under:

- [`firecracker/`](firecracker/) for Firecracker.
- [`cloud-hypervisor/`](cloud-hypervisor/) for Cloud Hypervisor.
- [`qemu/`](qemu/) for QEMU counterparts to the boot, metadata, overlay,
  snapshot, virtio-fs, and custom virtio-fs demos.
- [`memory-hotplug/`](memory-hotplug/) for matched virtio-mem demos across all
  three VMMs.
- [`overcommit-demo/`](overcommit-demo/) for the shared host-swap/cgroup proof
  across all three VMMs.

`snapshot-compare.sh` runs the comparable full snapshot benchmark for all three.

Use https://linux.die.net/man/8/resize2fs to shrink the filesystem to what it can really be reduced down to

## Creating the image bundle

See `image_to_fs.sh` and `make_ext4.sh`

https://umo.ci/ and https://github.com/containers/skopeo are interesting alternatives to using docker directly, can do something like:

```
# Extract OCI image
skopeo copy docker://hello-world:latest oci:./img:latest

mkdir rootfs

# Merge OCI image contents
umoci unpack --image ./img:latest rootfs
```

This is even more minimal than

```
docker export $(docker create hello-world) | sudo tar -xf - -C rootfs --same-owner --same-permissions
```

Then can run with

```
runc run -b rootfs container-name
```

## Linux namespaces

another way to control untrusted code is name spaces

https://blog.nginx.org/blog/what-are-namespaces-cgroups-how-do-they-work

can use https://man7.org/linux/man-pages/man1/unshare.1.html to create namespaces on demand that are cleaned up
