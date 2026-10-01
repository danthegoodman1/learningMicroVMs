"""Host-side client for the supervisor's vsock protocol.

Firecracker and Cloud Hypervisor both expose guest vsock ports through a Unix
socket on the host: connect, send "CONNECT <port>\\n", read "OK <n>\\n", then the
stream belongs to the guest. Frames are a 4-byte big-endian length followed by
NUL-terminated "key=value" records.
"""
import os
import socket
import struct
import time

PORT = 1024


def connect(uds_path, port=PORT, timeout=10.0, retry_s=0.0002, send=b""):
    """Connect to the supervisor, retrying until the VMM's socket exists and the
    guest is listening. `send` goes out in the same write as the CONNECT line,
    so a request reaches the guest without waiting for the VMM's OK."""
    deadline = time.monotonic() + timeout
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(max(0.001, deadline - time.monotonic()))
            s.connect(uds_path)
            s.sendall(f"CONNECT {port}\n".encode() + send)
            line = b""
            while not line.endswith(b"\n"):
                ch = s.recv(1)
                if not ch:
                    raise ConnectionError("VMM closed the vsock connection")
                line += ch
            if line.startswith(b"OK"):
                s.settimeout(None)
                return s
            raise ConnectionError(line.decode(errors="replace").strip())
        except OSError:
            s.close()
            if time.monotonic() >= deadline:
                raise TimeoutError(f"supervisor not reachable via {uds_path}")
            time.sleep(retry_s)


def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("supervisor closed the connection")
        buf += chunk
    return buf


def frame(records):
    """Encode [(key, value), ...] as one length-prefixed frame."""
    payload = b"".join(f"{k}={v}".encode() + b"\0" for k, v in records)
    return struct.pack(">I", len(payload)) + payload


def read_reply(s):
    (n,) = struct.unpack(">I", _recv_exact(s, 4))
    reply = {}
    for rec in _recv_exact(s, n).split(b"\0"):
        if rec:
            k, _, v = rec.decode().partition("=")
            reply[k] = v
    if reply.get("status") != "ok":
        raise RuntimeError(f"supervisor error: {reply}")
    return reply


def request(s, records):
    """Send [(key, value), ...]; return the reply as a dict."""
    s.sendall(frame(records))
    return read_reply(s)


def prepare(s, warm=(), warmrun=()):
    return request(s, [("cmd", "PREPARE")] + [("warm", p) for p in warm] + [("warmrun", c) for c in warmrun])


def start_records(argv, env, cwd=None, hostname=None, rootfs=None, rootfs_size=None, rootfs_fs=None,
                  rootfs_opts=None, rootfs_overlay=True, fixups=True):
    """Records for START: make this clone unique and launch argv with exactly
    `env`. With rootfs (a guest block device), argv runs from that disk.
    fixups=False leaves out the clock and RNG seed (for control experiments
    only)."""
    records = [("cmd", "START")]
    if fixups:
        records += [("time_ns", time.time_ns()), ("seed", os.urandom(32).hex())]
    if rootfs:
        records.append(("rootfs", rootfs))
        if rootfs_size:
            records.append(("rootfs_size", rootfs_size))
        if rootfs_fs:
            records.append(("rootfs_fs", rootfs_fs))
        if rootfs_opts:
            records.append(("rootfs_opts", rootfs_opts))
        if not rootfs_overlay:
            records.append(("rootfs_overlay", 0))
    if cwd:
        records.append(("cwd", cwd))
    if hostname:
        records.append(("hostname", hostname))
    records += [("env", f"{k}={v}") for k, v in env.items()]
    records += [("arg", a) for a in argv]
    return records


def start(s, argv, env, **kw):
    return request(s, start_records(argv, env, **kw))
