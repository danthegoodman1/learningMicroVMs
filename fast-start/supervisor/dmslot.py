"""A fixed-size host block device whose contents can be swapped to another
disk image in tens of microseconds, using device-mapper.

A base VM boots with the slot attached as its tenant disk. Before a restore or
resume, swap() points the slot at a tenant image (through a read-only loop
device) and fills the rest of the slot with zeros, so the guest sees the same
device and size it had at snapshot time. No hot-add, no capacity change.

Setup and teardown use dmsetup and losetup; swap() talks to the
device-mapper control device directly.
"""
import fcntl
import os
import struct
import subprocess

_DM_IOCTL_SIZE = 312  # sizeof(struct dm_ioctl)
_DM_READONLY_FLAG = 1 << 0
_DM_SKIP_LOCKFS_FLAG = 1 << 10
_BLKFLSBUF = 0x1261


def _dm_ioc(cmd):
    return (3 << 30) | (_DM_IOCTL_SIZE << 16) | (0xFD << 8) | cmd


_DM_DEV_SUSPEND = _dm_ioc(6)
_DM_TABLE_LOAD = _dm_ioc(9)


def _dm_ioctl(ctl_fd, req, name, flags=0, targets=()):
    """targets: [(start_sector, n_sectors, type, params), ...]"""
    specs = b""
    for start, length, ttype, params in targets:
        p = params.encode() + b"\0"
        p += b"\0" * (-(40 + len(p)) % 8)
        specs += struct.pack("=QQiI16s", start, length, 0, 40 + len(p), ttype.encode()) + p
    size = _DM_IOCTL_SIZE + len(specs)
    head = struct.pack("=3IIIIiIIIQ128s129s7s", 4, 0, 0, size, _DM_IOCTL_SIZE, len(targets), 0, flags, 0, 0, 0,
                       name.encode(), b"", b"")
    fcntl.ioctl(ctl_fd, req, bytearray(head + specs))


class Slot:
    def __init__(self, name, size):
        """Create /dev/mapper/<name>, `size` bytes of zeros."""
        self.name, self.sectors = name, size // 512
        self.path = f"/dev/mapper/{name}"
        subprocess.run(["dmsetup", "remove", name], stderr=subprocess.DEVNULL)
        subprocess.run(["dmsetup", "create", name, "--readonly", "--table", f"0 {self.sectors} zero"], check=True)
        self.loops = {}
        self._ctl = os.open("/dev/mapper/control", os.O_RDWR | os.O_CLOEXEC)

    def add_image(self, image):
        """Attach an image to a read-only loop device ahead of time."""
        if image not in self.loops:
            size = os.path.getsize(image)
            assert size % 512 == 0 and size <= self.sectors * 512, f"{image}: {size} bytes"
            dev = subprocess.run(["losetup", "--find", "--show", "--read-only", image],
                                 check=True, capture_output=True, text=True).stdout.strip()
            self.loops[image] = (dev, size // 512)
        return self.loops[image]

    def swap(self, image):
        """Point the slot at `image` (already passed to add_image) and drop the
        host's cached blocks of the old contents."""
        dev, n = self.loops[image]
        targets = [(0, n, "linear", f"{dev} 0")]
        if n < self.sectors:
            targets.append((n, self.sectors - n, "zero", ""))
        self._load(targets)

    def clear(self):
        """Back to all zeros."""
        self._load([(0, self.sectors, "zero", "")])

    def _load(self, targets):
        _dm_ioctl(self._ctl, _DM_TABLE_LOAD, self.name, _DM_READONLY_FLAG, targets)
        # Resuming with a new table loaded suspends the device, swaps the table
        # and resumes it. The suspend waits for RCU grace periods: about 4 ms
        # by default, under 0.1 ms with /sys/kernel/rcu_expedited set to 1.
        _dm_ioctl(self._ctl, _DM_DEV_SUSPEND, self.name, _DM_SKIP_LOCKFS_FLAG)
        fd = os.open(self.path, os.O_RDONLY | os.O_CLOEXEC)
        try:
            fcntl.ioctl(fd, _BLKFLSBUF, 0)
        finally:
            os.close(fd)

    def close(self):
        os.close(self._ctl)
        subprocess.run(["dmsetup", "remove", "--retry", self.name], stderr=subprocess.DEVNULL)
        for dev, _ in self.loops.values():
            subprocess.run(["losetup", "--detach", dev], stderr=subprocess.DEVNULL)
        self.loops = {}
