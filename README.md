# learningMicroVMs

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
