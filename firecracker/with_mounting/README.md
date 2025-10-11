# Firecracker with Secure Overlay Filesystem

Run Firecracker VMs with ephemeral overlay - perfect for untrusted users. Base system stays pristine, all changes go to RAM and vanish on reboot.

## Why?

✅ **Base system immutable** - Users can't permanently modify core files  
✅ **Auto-reset on reboot** - Perfect for untrusted workloads  
✅ **No persistent malware** - Everything in RAM disappears  

## Setup (Once)

```bash
# 1. Add overlay init to your rootfs
./setup-overlay-simple.sh ./rootfs.ext4

# 2. Done! Now you can use spawn_overlay.sh
```

## Usage

**Ephemeral mode (recommended):**
```bash
./spawn_overlay.sh
```
All changes stored in RAM. Reboot = clean slate.

**Persistent mode (if you need to keep data):**
```bash
./create-overlay-disk.sh 500           # Create 500MB overlay disk once
OVERLAY_MODE=persistent OVERLAY_IMG=./overlay.ext4 ./spawn_overlay.sh
```

**With extra data drive:**
```bash
DATA_IMG=./data.ext4 ./spawn_overlay.sh
# Automatically mounted at /mnt/data inside the VM
```

## How it works

```
Base rootfs (read-only) + Overlay (writable, tmpfs) = What VM sees
```

All writes go to overlay in RAM. Base never changes. Reboot clears overlay.

## Reset to clean state

**Ephemeral**: Just reboot  
**Persistent**: `rm overlay.ext4 && ./create-overlay-disk.sh 500`
