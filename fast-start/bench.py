#!/usr/bin/env python3
"""Start-time harness for Firecracker and Cloud Hypervisor.

Usage (as root):
    CPUS=0,1,2,3,4,5,6,7 python3 bench.py <experiments.json> [runs] [name,name,...]

Each experiment is a JSON object keyed by name. The clock starts just before the
VMM process is spawned (or, for pre-spawned tiers, just before the boot, restore,
or resume API call) and stops when the guest's first UDP datagram reaches the host:
  cold - the guest init (fastinit.c) sends "ready" after configuring eth0
  warm - the host pings the guest every 0.5 ms; the first "pong" stops the clock

Experiment keys:
  vmm            "fc" or "ch"
  kind           "cold" or "warm" (warm boots once, snapshots, then restores `runs` times)
  kernel         key of KERNELS
  cmdline        guest kernel command line
  rootfs/initrd  key of ROOTFS (read-only ext4, needs init=/fastinit) or INITRD
  mem, vcpus     guest size (default 256 MiB, 1 vCPU)
  huge           FC: back guest memory with 2 MiB hugetlbfs pages
  memory_opt     CH: raw --memory value
  no_seccomp     FC: --no-seccomp
  seccomp        CH: --seccomp value ("true"/"false")
  prespawn       true: VMM process already running (and configured, for cold)
                 "paused" (warm): VM already restored and paused; the clock covers resume only
  uffd_populate  FC paused tier: serve memory through uffd_populate, which copies the whole
                 snapshot into guest memory before the clock starts
  restore_mode   CH: "ondemand" (userfaultfd) or "copy"
  snapdir        snapshot directory; "disk" puts it under work/snapshots (default: RUN_DIR tmpfs)
  evict          drop the boot files (kernel, initramfs or rootfs, VMM binary) or, for warm
                 runs, the snapshot files from page cache before each measured run
  settle         seconds to wait after boot before snapshotting (default 0.5)
  console_log    CH: write the serial console to RUN_DIR/ch-console.log
  dmesg          path; with fi_dmesg=1 on the cmdline the guest sends its kernel log there

Env: CPUS pins the harness and its VMMs; RUN_DIR (default /dev/shm/vmbench) holds
sockets, logs, and tmpfs snapshots; FC_BIN and CH_BIN override the VMM binaries.
"""
import json
import os
import select
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WORK = os.path.join(HERE, "work")
FC_BIN = os.environ.get("FC_BIN", f"{REPO}/firecracker/firecracker")
CH_BIN = os.environ.get("CH_BIN", f"{REPO}/cloud-hypervisor/cloud-hypervisor")
TAP = "tap0"
HOST_IP, GUEST_IP, PORT = "172.16.0.1", "172.16.0.2", 7777
MAC = "06:00:AC:10:00:02"
RUN_DIR = os.environ.get("RUN_DIR", "/dev/shm/vmbench")
RESULTS = os.path.join(WORK, "results.jsonl")

KERNELS = {
    "fc510": f"{REPO}/firecracker/vmlinux-5.10.225",
    "fc61": f"{REPO}/firecracker/vmlinux-6.1.155",
    "ch616": f"{REPO}/cloud-hypervisor/vmlinux-x86_64",
    "min": f"{WORK}/vmlinux-min",
    "tiny": f"{WORK}/vmlinux-tiny",
    "full": f"{WORK}/vmlinux-full",
    "full-mit": f"{WORK}/vmlinux-full-mit",
}
ROOTFS = {
    "ubuntu": f"{WORK}/ubuntu-fastinit.ext4",
}
INITRD = {
    "tiny": f"{WORK}/initramfs.cpio",
}


def now():
    return time.perf_counter_ns()


def ms(ns):
    return round(ns / 1e6, 2)


def sh(*cmd, check=True):
    return subprocess.run(cmd, check=check, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def setup_net():
    # A pre-created TAP plus a permanent ARP entry keep TAP setup and ARP
    # resolution out of the measured path.
    sh("ip", "link", "del", TAP, check=False)
    sh("ip", "tuntap", "add", "dev", TAP, "mode", "tap")
    sh("ip", "addr", "add", f"{HOST_IP}/30", "dev", TAP)
    sh("ip", "link", "set", TAP, "up")
    sh("ip", "neigh", "replace", GUEST_IP, "lladdr", MAC.lower(), "dev", TAP, "nud", "permanent")


def udp_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST_IP, PORT))
    s.setblocking(False)
    return s


def drain(s):
    while True:
        try:
            s.recv(4096)
        except BlockingIOError:
            return


def wait_ready(s, timeout=20):
    deadline = time.monotonic() + timeout
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("guest never sent ready")
        r, _, _ = select.select([s], [], [], left)
        if r:
            data = s.recv(4096)
            if data.startswith(b"ready"):
                return now(), data.decode()


def ping_until_pong(s, interval=0.0005, timeout=20):
    deadline = time.monotonic() + timeout
    seq = 0
    while time.monotonic() < deadline:
        seq += 1
        try:
            s.sendto(f"ping {seq}".encode(), (GUEST_IP, PORT))
        except OSError:
            pass
        r, _, _ = select.select([s], [], [], interval)
        if r:
            data = s.recv(4096)
            if data.startswith(b"pong"):
                return now()
    raise TimeoutError("guest never answered ping")


def wait_socket(path, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.connect(path)
            return c
        except OSError:
            c.close()
            time.sleep(0.0001)
    raise TimeoutError(f"no API socket at {path}")


def http(conn_or_path, method, url, body=None, timeout=60):
    c = conn_or_path
    if isinstance(c, str):
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect(conn_or_path)
    c.settimeout(timeout)
    b = json.dumps(body).encode() if body is not None else b""
    req = (f"{method} {url} HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n"
           f"Content-Type: application/json\r\nContent-Length: {len(b)}\r\n\r\n").encode() + b
    c.sendall(req)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1])
    clen = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            clen = int(v)
    while len(rest) < clen:
        rest += c.recv(65536)
    if status >= 300:
        raise RuntimeError(f"{method} {url} -> {status}: {rest.decode(errors='replace')}")
    return c, rest


def kill(p):
    if p and p.poll() is None:
        p.kill()
    if p:
        p.wait()


def kill_stray_vmms():
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if argv[0].decode() in (FC_BIN, CH_BIN) and any(RUN_DIR.encode() in a for a in argv):
            os.kill(int(pid), signal.SIGKILL)


def boot_files(v, include_vmm=True):
    files = [KERNELS[v["kernel"]]]
    if v.get("initrd"):
        files.append(INITRD[v["initrd"]])
    if v.get("rootfs"):
        files.append(ROOTFS[v["rootfs"]])
    if include_vmm:
        files.append(FC_BIN if v["vmm"] == "fc" else CH_BIN)
    return files


def drop_file_cache(paths):
    for path in paths:
        if os.path.isdir(path):
            for d, _, fs in os.walk(path):
                drop_file_cache([os.path.join(d, f) for f in fs])
            continue
        fd = os.open(path, os.O_RDONLY)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        os.close(fd)


# ---------------------------------------------------------------- Firecracker

def fc_config(v):
    cfg = {
        "boot-source": {
            "kernel_image_path": KERNELS[v["kernel"]],
            "boot_args": v["cmdline"],
        },
        "drives": [],
        "machine-config": {
            "vcpu_count": v.get("vcpus", 1),
            "mem_size_mib": v.get("mem", 256),
            "smt": False,
        },
        "network-interfaces": [
            {"iface_id": "eth0", "guest_mac": MAC, "host_dev_name": TAP}
        ],
    }
    if v.get("huge"):
        cfg["machine-config"]["huge_pages"] = "2M"
    if v.get("initrd"):
        cfg["boot-source"]["initrd_path"] = INITRD[v["initrd"]]
    if v.get("rootfs"):
        cfg["drives"].append({
            "drive_id": "rootfs",
            "path_on_host": ROOTFS[v["rootfs"]],
            "is_root_device": True,
            "is_read_only": True,
        })
    return cfg


def fc_args(v, sock=None):
    args = [FC_BIN]
    if sock:
        args += ["--api-sock", sock]
    else:
        args += ["--no-api"]
    if v.get("no_seccomp"):
        args.append("--no-seccomp")
    if v.get("boot_timer"):
        args.append("--boot-timer")
    if v.get("pci"):
        args.append("--enable-pci")
    if v.get("level"):
        args += ["--level", v["level"]]
    return args


def collect_dmesg(s, path, quiet=0.3):
    chunks = []
    while True:
        r, _, _ = select.select([s], [], [], quiet)
        if not r:
            break
        data = s.recv(4096)
        if data.startswith(b"dmesg"):
            chunks.append(data[5:])
    with open(path, "wb") as f:
        f.write(b"".join(chunks))


def fc_cold(v, s, run):
    os.makedirs(RUN_DIR, exist_ok=True)
    cfg_path = f"{RUN_DIR}/fc-{run}.json"
    with open(cfg_path, "w") as f:
        json.dump(fc_config(v), f)
    log = open(f"{RUN_DIR}/fc-console.log", "w")
    drain(s)
    if v.get("prespawn"):
        sock = f"{RUN_DIR}/fc.sock"
        if os.path.exists(sock):
            os.unlink(sock)
        p = subprocess.Popen(fc_args(v, sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            c = wait_socket(sock)
            cfg = fc_config(v)
            c, _ = http(c, "PUT", "/boot-source", cfg["boot-source"])
            for d in cfg["drives"]:
                c, _ = http(c, "PUT", f"/drives/{d['drive_id']}", d)
            c, _ = http(c, "PUT", "/machine-config", cfg["machine-config"])
            for n in cfg["network-interfaces"]:
                c, _ = http(c, "PUT", f"/network-interfaces/{n['iface_id']}", n)
            if v.get("evict"):
                drop_file_cache(boot_files(v, include_vmm=False))
            t0 = now()
            http(c, "PUT", "/actions", {"action_type": "InstanceStart"})
            t_cfg = now()
            t1, msg = wait_ready(s)
        finally:
            kill(p)
            log.close()
        return {"total_ms": ms(t1 - t0), "config_ms": ms(t_cfg - t0), "guest": msg, "t0": t0, "t1": t1}
    if v.get("evict"):
        drop_file_cache(boot_files(v))
    t0 = now()
    if v.get("api_config"):
        sock = f"{RUN_DIR}/fc.sock"
        if os.path.exists(sock):
            os.unlink(sock)
        p = subprocess.Popen(fc_args(v, sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        c = wait_socket(sock)
        cfg = fc_config(v)
        c, _ = http(c, "PUT", "/boot-source", cfg["boot-source"])
        for d in cfg["drives"]:
            c, _ = http(c, "PUT", f"/drives/{d['drive_id']}", d)
        c, _ = http(c, "PUT", "/machine-config", cfg["machine-config"])
        for n in cfg["network-interfaces"]:
            c, _ = http(c, "PUT", f"/network-interfaces/{n['iface_id']}", n)
        t_cfg = now()
        c, _ = http(c, "PUT", "/actions", {"action_type": "InstanceStart"})
    else:
        p = subprocess.Popen(fc_args(v) + ["--config-file", cfg_path],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        t_cfg = t0
    try:
        t1, msg = wait_ready(s)
        if v.get("dmesg"):
            collect_dmesg(s, v["dmesg"])
    finally:
        kill(p)
        log.close()
    return {"total_ms": ms(t1 - t0), "config_ms": ms(t_cfg - t0), "guest": msg, "t0": t0, "t1": t1}


def fc_make_snapshot(v, s, snapdir):
    shutil.rmtree(snapdir, ignore_errors=True)
    os.makedirs(snapdir)
    cfg_path = f"{snapdir}/config.json"
    with open(cfg_path, "w") as f:
        json.dump(fc_config(v), f)
    sock = f"{RUN_DIR}/fc-snap.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    log = open(f"{RUN_DIR}/fc-snap-console.log", "w")
    drain(s)
    p = subprocess.Popen(fc_args(v, sock) + ["--config-file", cfg_path],
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        _, msg = wait_ready(s)
        time.sleep(v.get("settle", 0.5))
        c = wait_socket(sock)
        c, _ = http(c, "PATCH", "/vm", {"state": "Paused"})
        c, _ = http(c, "PUT", "/snapshot/create", {
            "snapshot_type": "Full",
            "snapshot_path": f"{snapdir}/vm.snap",
            "mem_file_path": f"{snapdir}/mem.snap",
        })
    finally:
        kill(p)
        log.close()


def fc_restore(v, s, snapdir, run, prespawn=False):
    sock = f"{RUN_DIR}/fc-restore.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    log = open(f"{RUN_DIR}/fc-restore-console.log", "w")
    drain(s)
    if v.get("evict"):
        drop_file_cache([snapdir])
    body = {
        "snapshot_path": f"{snapdir}/vm.snap",
        "mem_backend": {"backend_path": f"{snapdir}/mem.snap", "backend_type": "File"},
        "resume_vm": True,
    }
    p = None
    handlers = []
    try:
        if prespawn == "paused":
            p = subprocess.Popen(fc_args(v, sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            c = wait_socket(sock)
            if v.get("uffd_populate"):
                usock = f"{RUN_DIR}/uffd.sock"
                h = subprocess.Popen([f"{WORK}/uffd_populate", usock, f"{snapdir}/mem.snap"],
                                     stdout=subprocess.PIPE, text=True)
                handlers.append(h)
                assert h.stdout.readline().startswith("listening")
                body = dict(body, mem_backend={"backend_path": usock, "backend_type": "Uffd"})
            c, _ = http(c, "PUT", "/snapshot/load", dict(body, resume_vm=False))
            if v.get("uffd_populate"):
                line = h.stdout.readline()
                assert line.startswith("populated"), line
            t0 = now()
            t_sock = t0
            http(c, "PATCH", "/vm", {"state": "Resumed"})
            t_load = now()
            t1 = ping_until_pong(s)
            return {"total_ms": ms(t1 - t0), "t0": t0, "t1": t1, "spawn_ms": 0.0,
                    "load_ms": ms(t_load - t0), "first_pong_ms": ms(t1 - t_load)}
        elif prespawn:
            p = subprocess.Popen(fc_args(v, sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            c = wait_socket(sock)
            t0 = now()
            t_sock = t0
        else:
            t0 = now()
            p = subprocess.Popen(fc_args(v, sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            c = wait_socket(sock)
            t_sock = now()
        http(c, "PUT", "/snapshot/load", body)
        t_load = now()
        t1 = ping_until_pong(s)
    finally:
        kill(p)
        for h in handlers:
            kill(h)
        log.close()
    return {"total_ms": ms(t1 - t0), "t0": t0, "t1": t1, "spawn_ms": ms(t_sock - t0),
            "load_ms": ms(t_load - t_sock), "first_pong_ms": ms(t1 - t_load)}


# ---------------------------------------------------------- Cloud Hypervisor

def ch_args(v, sock=None, console_log=None):
    args = [CH_BIN,
            "--kernel", KERNELS[v["kernel"]],
            "--cmdline", v["cmdline"],
            "--cpus", f"boot={v.get('vcpus', 1)}",
            "--memory", v.get("memory_opt", f"size={v.get('mem', 256)}M"),
            "--net", v.get("net_opt", f"tap={TAP},mac={MAC}"),
            "--console", "off",
            "--seccomp", v.get("seccomp", "true")]
    if console_log:
        args += ["--serial", f"file={console_log}"]
    else:
        args += ["--serial", v.get("serial", "off")]
    if v.get("rootfs"):
        args += ["--disk", f"path={ROOTFS[v['rootfs']]},readonly=on,image_type=raw"]
    if v.get("initrd"):
        args += ["--initramfs", INITRD[v["initrd"]]]
    if sock:
        args += ["--api-socket", f"path={sock}"]
    args += v.get("ch_extra", [])
    return args


def ch_vm_config(v):
    cfg = {
        "cpus": {"boot_vcpus": v.get("vcpus", 1), "max_vcpus": v.get("vcpus", 1)},
        "memory": {"size": v.get("mem", 256) << 20},
        "payload": {"kernel": KERNELS[v["kernel"]], "cmdline": v["cmdline"]},
        "net": [{"tap": TAP, "mac": MAC}],
        "serial": {"mode": "Off"},
        "console": {"mode": "Off"},
    }
    if v.get("initrd"):
        cfg["payload"]["initramfs"] = INITRD[v["initrd"]]
    if v.get("rootfs"):
        cfg["disks"] = [{"path": ROOTFS[v["rootfs"]], "readonly": True}]
    return cfg


def ch_cold(v, s, run):
    os.makedirs(RUN_DIR, exist_ok=True)
    log = open(f"{RUN_DIR}/ch.log", "w")
    console = f"{RUN_DIR}/ch-console.log" if v.get("console_log") else None
    drain(s)
    if v.get("prespawn"):
        sock = f"{RUN_DIR}/ch-cold.sock"
        if os.path.exists(sock):
            os.unlink(sock)
        p = subprocess.Popen([CH_BIN, "--api-socket", f"path={sock}", "--seccomp", v.get("seccomp", "true")],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            wait_socket(sock).close()
            http(sock, "PUT", "/api/v1/vm.create", ch_vm_config(v))
            if v.get("evict"):
                drop_file_cache(boot_files(v, include_vmm=False))
            t0 = now()
            http(sock, "PUT", "/api/v1/vm.boot")
            t1, msg = wait_ready(s)
        finally:
            kill(p)
            log.close()
        return {"total_ms": ms(t1 - t0), "guest": msg, "t0": t0, "t1": t1}
    if v.get("evict"):
        drop_file_cache(boot_files(v))
    t0 = now()
    p = subprocess.Popen(ch_args(v, console_log=console), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        t1, msg = wait_ready(s)
        if v.get("dmesg"):
            collect_dmesg(s, v["dmesg"])
    finally:
        kill(p)
        log.close()
    return {"total_ms": ms(t1 - t0), "guest": msg, "t0": t0, "t1": t1}


def ch_make_snapshot(v, s, snapdir):
    shutil.rmtree(snapdir, ignore_errors=True)
    os.makedirs(snapdir)
    sock = f"{RUN_DIR}/ch-snap.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    log = open(f"{RUN_DIR}/ch-snap.log", "w")
    drain(s)
    p = subprocess.Popen(ch_args(v, sock=sock), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        wait_ready(s)
        time.sleep(v.get("settle", 0.5))
        c = wait_socket(sock)
        http(c, "PUT", "/api/v1/vm.pause")
        http(sock, "PUT", "/api/v1/vm.snapshot", {"destination_url": f"file://{snapdir}"})
    finally:
        kill(p)
        log.close()


def ch_restore(v, s, snapdir, run, prespawn=False):
    sock = f"{RUN_DIR}/ch-restore.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    log = open(f"{RUN_DIR}/ch-restore.log", "w")
    drain(s)
    if v.get("evict"):
        drop_file_cache([snapdir])
    mode = v.get("restore_mode", "ondemand")
    restore = f"source_url=file://{snapdir},memory_restore_mode={mode},resume=true"
    if v.get("restore_prefault"):
        restore += ",prefault=on"
    base = [CH_BIN, "--api-socket", f"path={sock}", "--seccomp", v.get("seccomp", "true")]
    p = None
    try:
        if prespawn == "paused":
            p = subprocess.Popen(base + ["--restore", restore.replace("resume=true", "resume=false")],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while True:
                try:
                    _, info = http(sock, "GET", "/api/v1/vm.info")
                    if json.loads(info).get("state") == "Paused":
                        break
                except (OSError, RuntimeError):
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError("restore never reached Paused")
                time.sleep(0.001)
            t0 = now()
            http(sock, "PUT", "/api/v1/vm.resume")
            t_load = now()
        elif prespawn:
            p = subprocess.Popen(base, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            c = wait_socket(sock)
            t0 = now()
            api_mode = {"ondemand": "OnDemand", "copy": "Copy"}[mode]
            body = {"source_url": f"file://{snapdir}", "memory_restore_mode": api_mode, "resume": True}
            if v.get("restore_prefault"):
                body["prefault"] = True
            http(c, "PUT", "/api/v1/vm.restore", body)
            t_load = now()
        else:
            t0 = now()
            p = subprocess.Popen(base + ["--restore", restore],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            t_load = t0
        t1 = ping_until_pong(s)
    finally:
        kill(p)
        log.close()
    return {"total_ms": ms(t1 - t0), "t0": t0, "t1": t1, "load_ms": ms(t_load - t0), "first_pong_ms": ms(t1 - t_load)}


# --------------------------------------------------------------------- driver

def summarize(name, rows):
    vals = [r["total_ms"] for r in rows]
    out = {
        "name": name,
        "n": len(vals),
        "median": round(statistics.median(vals), 2),
        "min": min(vals),
        "max": max(vals),
        "p90": round(sorted(vals)[max(0, int(len(vals) * 0.9) - 1)], 2),
    }
    for k in ("config_ms", "spawn_ms", "load_ms", "first_pong_ms"):
        if k in rows[0]:
            out[k] = round(statistics.median(r[k] for r in rows), 2)
    if "guest" in rows[0]:
        g = [dict(kv.split("=") for kv in r["guest"].split()[1:]) for r in rows]
        out["guest_init_ms"] = round(statistics.median(int(x["init_us"]) for x in g) / 1000, 2)
        out["guest_net_ms"] = round(statistics.median(int(x["net_us"]) for x in g) / 1000, 2)
    return out


def run_variant(name, v, runs, s):
    kind = v["kind"]
    vmm = v["vmm"]
    rows = []
    if kind == "cold":
        fn = fc_cold if vmm == "fc" else ch_cold
        fn(v, s, -1)  # warm page cache and CPU
        for i in range(runs):
            rows.append(fn(v, s, i))
            time.sleep(v.get("gap", 0.05))
    else:
        snapdir = v.get("snapdir", f"{RUN_DIR}/snap-{name}")
        if snapdir == "disk":
            snapdir = f"{WORK}/snapshots/{name}"
        make = fc_make_snapshot if vmm == "fc" else ch_make_snapshot
        restore = fc_restore if vmm == "fc" else ch_restore
        make(v, s, snapdir)
        restore(v, s, snapdir, -1, prespawn=v.get("prespawn", False))
        for i in range(runs):
            rows.append(restore(v, s, snapdir, i, prespawn=v.get("prespawn", False)))
            time.sleep(v.get("gap", 0.05))
        if not v.get("keep_snapshot"):
            shutil.rmtree(snapdir, ignore_errors=True)
    summ = summarize(name, rows)
    summ["variant"] = v
    summ["runs"] = [r["total_ms"] for r in rows]
    if os.environ.get("TRACE"):
        for r in rows:
            print(f"T0 {r['t0']} T1 {r['t1']}", flush=True)
    with open(RESULTS, "a") as f:
        f.write(json.dumps(summ) + "\n")
    print(json.dumps({k: summ[k] for k in summ if k not in ("variant",)}), flush=True)
    return summ


def main():
    exp_file, runs = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 20
    only = sys.argv[3].split(",") if len(sys.argv) > 3 else None
    with open(exp_file) as f:
        variants = json.load(f)
    if os.environ.get("CPUS"):
        cpus = {int(c) for c in os.environ["CPUS"].split(",")}
        os.sched_setaffinity(0, cpus)
    os.makedirs(RUN_DIR, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    kill_stray_vmms()
    setup_net()
    s = udp_socket()
    try:
        for name, v in variants.items():
            if only and name not in only:
                continue
            try:
                run_variant(name, v, runs, s)
            except Exception as e:
                print(json.dumps({"name": name, "error": repr(e)}), flush=True)
    finally:
        sh("ip", "link", "del", TAP, check=False)


if __name__ == "__main__":
    main()
