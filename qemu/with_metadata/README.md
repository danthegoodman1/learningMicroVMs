# QEMU metadata demo

Boot one VM and start its AWS-style link-local metadata service:

```bash
./spawn.sh
./metadata-server.sh
```

Inside the guest:

```bash
curl http://169.254.169.254/instance-id
curl http://169.254.169.254/json
```

Multiple isolated rootfs copies and TAP subnets are supported:

```bash
./spawn-multi.sh 1
./spawn-multi.sh 2
./stop-multi.sh 1
./stop-multi.sh 2
```
