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

is nearly instant, but creates a read-only folder and the `--rw` doesn't seem to work.
