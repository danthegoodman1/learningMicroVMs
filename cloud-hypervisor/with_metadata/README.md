# Cloud Hypervisor with Metadata Service

This demo adds an AWS-style metadata endpoint to a Cloud Hypervisor VM using
TAP networking.

## How it works

1. The spawn script adds `169.254.169.254/32` to the TAP interface.
2. A Python HTTP server listens on that IP and serves static VM metadata.
3. The server identifies the VM by request source IP.
4. The guest accesses metadata with normal HTTP tools.

## Usage

```bash
./metadata-server.sh
```

In another terminal:

```bash
./spawn.sh
ssh -i ../ubuntu-22.04.id_rsa root@172.16.0.2
```

Inside the VM:

```bash
curl http://169.254.169.254/
curl http://169.254.169.254/instance-id
curl http://169.254.169.254/local-ipv4
curl http://169.254.169.254/json
```
