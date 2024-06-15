See https://github.com/opencontainers/runc/blob/main/libcontainer/SPEC.md and https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md for linux specifics to configure with the config.json

## CPU usage

run

```
bash python-server.sh
```

Then

```
bash cpu.sh
```


## Building docker right to OCI bundle

```
docker build -o rootfs .
```

Will make rootfs. Takes a while though (6-9s).

```
ctr image mount --rw docker.io/library/python:latest rootfs
ctr image unmount rootfs
```

is nearly instant, but creates a read-only mount and the `--rw` doesn't seem to work, but still works as an oci image bundle with runsc.

Realistically would likely create an ext4 filesystem out of this, then can mount it quickly with:

```
mount -o loop path_to_your_file.ext4 /mnt/my_mount_point
```

(`loop,ro` if need read-only)

That should make it fast to download the .ext4 file and mount it into an oci bundle.
(see ext4-runsc.sh)
