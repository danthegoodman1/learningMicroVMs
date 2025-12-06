# Firecracker with Metadata Service

This example adds an AWS-style metadata service to Firecracker VMs.

## How it works

1. The spawn script adds `169.254.169.254` to the tap interface
2. A Python HTTP server listens on that IP and serves metadata
3. The server identifies which VM is making the request by source IP
4. Each VM gets its own metadata based on its IP address

## Usage

### Terminal 1: Start Firecracker

```bash
# Start firecracker (socket must exist before spawn.sh)
sudo firecracker --api-sock /tmp/firecracker.socket
```

### Terminal 2: Spawn the VM

```bash
./spawn.sh
```

### Terminal 3: Start the metadata service

```bash
sudo ./metadata-server.sh
```

### Terminal 4: Test from inside the VM

```bash
ssh -i ./ubuntu-22.04.id_rsa root@172.16.0.2

# Inside the VM:
curl http://169.254.169.254/
curl http://169.254.169.254/instance-id
curl http://169.254.169.254/local-ipv4
curl http://169.254.169.254/hostname
curl http://169.254.169.254/json  # all metadata as JSON
```

## Running Multiple VMs

To run multiple VMs, each needs:
- A unique tap interface (tap0, tap1, tap2, ...)
- A unique IP range (172.16.0.x, 172.16.1.x, ...)
- A unique VM_ID

See `spawn-multi.sh` for an example.

## Adding VM Metadata

Edit `metadata-server.sh` and add entries to the `VM_METADATA` dictionary:

```python
VM_METADATA = {
    "172.16.0.2": {
        "instance-id": "vm-001",
        "local-ipv4": "172.16.0.2",
        # ... more fields
    },
    "172.16.1.2": {
        "instance-id": "vm-002",
        # ...
    },
}
```

## Security Note

In production, you'd want to:
- Restrict metadata access to only the VM's own data
- Add authentication/tokens for sensitive metadata
- Rate limit requests
- Log access for auditing
