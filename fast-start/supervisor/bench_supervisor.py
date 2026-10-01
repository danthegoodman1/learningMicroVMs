#!/usr/bin/env python3
"""Time from "start a VM" to the customer's process doing work, using the
supervisor as PID 1, and check that restored clones are distinct.

Usage (as root, after ../setup.sh and ./build.sh, with vm.nr_hugepages reserved
and a huge=always tmpfs at /mnt/vmbench-hugetmp; see ../README.md):
    CPUS=0,1,2,3,4,5,6,7 python3 bench_supervisor.py [runs] [name,name,...]
    CPUS=0,1,2,3,4,5,6,7 python3 bench_supervisor.py clones
    CPUS=0,1,2,3,4,5,6,7 python3 bench_supervisor.py clones-control
KERNEL picks the guest kernel (default full). PIPELINE=1 sends START in the
same write as the vsock CONNECT line. Each result row records the host's
/sys/kernel/rcu_expedited, which sets how long a dm swap takes.

Tiers (the clock starts at T0 in each):
  cold      T0, spawn VMM, boot, START               (no snapshot)
  restore   T0, spawn VMM, load snapshot, START
  prespawn  VMM already running; T0, load snapshot, START
  paused    snapshot already loaded and paused; T0, resume, START
The clock stops when the host hears from the customer's process: a UDP report
from child_probe, or the first HTTP response from py_child.py.

Variants with "tenant" restore a generic base snapshot and give it the
tenant's disk after T0. "attach" picks how:
  hotadd  Firecracker swaps a placeholder drive's file (PATCH /drives);
          Cloud Hypervisor hot-adds a PCI disk (vm.add-disk)
  dm      the base VM's disk is a device-mapper slot (dmslot.py) whose table
          is pointed at the tenant image
  path    the base VM's disk is a symlink that is pointed at the tenant image
          before the VMM opens it (restore only; images padded to SLOT_SIZE)
"""
import json
import os
import shutil
import socket
import select
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import bench  # noqa: E402
import ctl  # noqa: E402
import dmslot  # noqa: E402

bench.ROOTFS["sv-ubuntu"] = f"{bench.WORK}/ubuntu-supervisor.ext4"
bench.INITRD["sv"] = f"{bench.WORK}/initramfs-supervisor.cpio"
RUN = bench.RUN_DIR
API = f"{RUN}/sv-api.sock"
VSOCK = f"{RUN}/sv-vsock.sock"          # vsock socket of a booted VM
VSOCK_RESTORED = f"{RUN}/sv-vsock-r.sock"  # Firecracker: vsock_override on restore
RESULTS = f"{bench.WORK}/supervisor-results.jsonl"
# Fly-style starts: a generic base snapshot (initramfs + supervisor, no tenant
# files) gets the tenant's disk after restore. The Ubuntu image doubles as the
# tenant disk; it holds both test children.
TENANT_DISK = bench.ROOTFS["sv-ubuntu"]
# OCI images flattened by oci_to_disk.sh (oci-<name>.<fs>); the .json beside
# each holds argv/env/cwd.
OCI_IMAGES = {"c": "scratch", "py": "py"}
PLACEHOLDER = f"{bench.WORK}/placeholder.img"
# A tenant disk that stays attached across the snapshot ("dm" and "path"
# attach) keeps one size, so the guest never sees a capacity change.
SLOT_SIZE = 512 << 20
SLOT_LINK = f"{RUN}/sv-slot.img"
SLOT_PLACEHOLDER = f"{RUN}/sv-slot-placeholder.img"
SLOT = None  # dmslot.Slot, created in main()

CHILDREN = {
    "c": {
        "argv": ["/child_probe"],
        "warm": ["/child_probe"],
        "warmrun": [],
        "result": "udp",
    },
    "py": {
        "argv": ["/usr/bin/python3", "/py_child.py"],
        "warm": ["/py_child.py"],
        "warmrun": ["/usr/bin/python3 -c 'import http.server, json, random, socketserver'"],
        "result": "http",
    },
}


def guest(v):
    """Fill in kernel command line and image for a variant."""
    d = dict(v)
    base = "reboot=k panic=1 quiet 8250.nr_uarts=0" + (" pci=off" if v["vmm"] == "fc" else "")
    if (v["child"] == "py" or v.get("disk")) and not v.get("tenant"):
        d["rootfs"] = "sv-ubuntu"
        d["cmdline"] = base + " init=/supervisor" + (" root=/dev/vda ro" if v["vmm"] == "ch" else "")
    else:
        d["initrd"] = "sv"
        d["cmdline"] = base
    return d


def child_env(instance):
    return {
        "INSTANCE_ID": instance,
        "SECRET_TOKEN": os.urandom(8).hex(),
        "REPORT_HOST": bench.HOST_IP,
        "REPORT_PORT": str(bench.PORT),
        "PORT": "8080",
        "HOME": "/root",
    }


def unlink(*paths):
    for p in paths:
        if os.path.exists(p):
            os.unlink(p)


def popen(args):
    return subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def spawn_fc(v, api=None, cfg=None):
    args = bench.fc_args(v, api)
    if cfg:
        path = f"{RUN}/sv-fc.json"
        with open(path, "w") as f:
            json.dump(cfg, f)
        args += ["--config-file", path]
    return popen(args)


def fc_cfg(v):
    cfg = bench.fc_config(v)
    cfg["vsock"] = {"guest_cid": 3, "uds_path": VSOCK}
    if v.get("tenant"):
        path = PLACEHOLDER if v.get("attach", "hotadd") == "hotadd" else slot_path(v)
        cfg["drives"].append({"drive_id": "tenant", "path_on_host": path,
                              "is_root_device": False, "is_read_only": True})
    return cfg


def tenant_disk(v):
    if not v.get("oci"):
        return TENANT_DISK
    name = v["oci"] if isinstance(v["oci"], str) else OCI_IMAGES[v["child"]]
    return f"{bench.WORK}/oci-{name}.{v.get('fs', 'ext4')}"


def slot_path(v):
    return SLOT.path if v.get("attach") == "dm" else SLOT_LINK


def point_link(target):
    tmp = SLOT_LINK + ".new"
    unlink(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, SLOT_LINK)


def prepare_slot(v):
    """Before booting a base VM: an empty slot. Before T0: the tenant image is
    ready to swap in (a loop device, or padded to the slot size)."""
    if v.get("attach") == "dm":
        SLOT.clear()
        SLOT.add_image(tenant_disk(v))
    elif v.get("attach") == "path":
        with open(SLOT_PLACEHOLDER, "a"):
            os.truncate(SLOT_PLACEHOLDER, SLOT_SIZE)
        if os.path.getsize(tenant_disk(v)) < SLOT_SIZE:
            os.truncate(tenant_disk(v), SLOT_SIZE)  # sparse: the image's own blocks are unchanged
        point_link(SLOT_PLACEHOLDER)


def swap_slot(v):
    """After T0: point the base VM's disk at the tenant image."""
    if v.get("attach") == "dm":
        SLOT.swap(tenant_disk(v))
    elif v.get("attach") == "path":
        point_link(tenant_disk(v))


def attach_tenant_disk(v):
    """Give a restored base VM the tenant's disk after the fact; it shows up as
    /dev/vda."""
    if v["vmm"] == "fc":
        bench.http(API, "PATCH", "/drives/tenant", {"drive_id": "tenant", "path_on_host": tenant_disk(v)})
        return
    deadline = time.monotonic() + 30
    while True:  # a CLI restore finishes in the background
        try:
            if json.loads(bench.http(API, "GET", "/api/v1/vm.info")[1]).get("state") == "Running":
                break
        except (OSError, RuntimeError):
            pass
        if time.monotonic() > deadline:
            raise TimeoutError("restored VM never reached Running")
        time.sleep(0.0002)
    bench.http(API, "PUT", "/api/v1/vm.add-disk", {"path": tenant_disk(v), "readonly": True})


def spawn_ch(v, api=None, restore=None):
    if restore:
        args = [bench.CH_BIN, "--api-socket", f"path={api}", "--seccomp", v.get("seccomp", "true")]
        if restore != "api":
            args += ["--restore", restore]
        return popen(args)
    args = bench.ch_args(v, sock=api) + ["--vsock", f"cid=3,socket={VSOCK}"]
    if v.get("tenant") and v.get("attach", "hotadd") != "hotadd":
        args += ["--disk", f"path={slot_path(v)},readonly=on,image_type=raw"]
    return popen(args)


def wait_child(v, s, timeout=20):
    """Return (host_ns, host_realtime_ns, report dict) once the child reports."""
    deadline = time.monotonic() + timeout
    if CHILDREN[v["child"]]["result"] == "udp":
        while time.monotonic() < deadline:
            r, _, _ = select.select([s], [], [], deadline - time.monotonic())
            if r:
                data = s.recv(4096)
                if data.startswith(b"child"):
                    t, rt = bench.now(), time.time_ns()
                    return t, rt, dict(kv.split("=", 1) for kv in data.decode().split()[1:])
        raise TimeoutError("child never reported")
    while time.monotonic() < deadline:
        try:
            c = socket.create_connection((bench.GUEST_IP, 8080), timeout=0.05)
        except OSError:
            time.sleep(0.0002)
            continue
        with c:
            c.sendall(b"GET / HTTP/1.0\r\n\r\n")
            buf = b""
            while chunk := c.recv(65536):
                buf += chunk
        t, rt = bench.now(), time.time_ns()
        return t, rt, json.loads(buf.partition(b"\r\n\r\n")[2])
    raise TimeoutError("child never answered HTTP")


def make_snapshot(v, s, snapdir):
    shutil.rmtree(snapdir, ignore_errors=True)
    os.makedirs(snapdir)
    unlink(API, VSOCK)
    child = CHILDREN[v["child"]]
    if v.get("tenant"):
        prepare_slot(v)
    p = spawn_fc(v, API, fc_cfg(v)) if v["vmm"] == "fc" else spawn_ch(v, api=API)
    try:
        c = ctl.connect(VSOCK, timeout=30)
        if v.get("tenant"):
            ctl.prepare(c)  # the base snapshot knows nothing about the tenant
        else:
            ctl.prepare(c, child["warm"], child["warmrun"])
        c.close()
        time.sleep(v.get("settle", 0.3))
        if v["vmm"] == "fc":
            c, _ = bench.http(API, "PATCH", "/vm", {"state": "Paused"})
            bench.http(c, "PUT", "/snapshot/create", {
                "snapshot_type": "Full", "snapshot_path": f"{snapdir}/vm.snap", "mem_file_path": f"{snapdir}/mem.snap"})
        else:
            bench.http(API, "PUT", "/api/v1/vm.pause")
            bench.http(API, "PUT", "/api/v1/vm.snapshot", {"destination_url": f"file://{snapdir}"})
    finally:
        bench.kill(p)


def run_once(v, s, snapdir, instance, fixups=True):
    tier, vmm = v["tier"], v["vmm"]
    child = CHILDREN[v["child"]]
    env = child_env(instance)
    argv, cwd = child["argv"], None
    if v.get("oci"):
        with open(tenant_disk(v) + ".json") as f:
            image = json.load(f)
        argv, cwd = image["argv"], image["cwd"]
        env = {**image["env"], **env}
    mode = v.get("restore_mode", "copy" if tier == "paused" else "ondemand")
    fc_load = {"snapshot_path": f"{snapdir}/vm.snap",
               "mem_backend": {"backend_path": f"{snapdir}/mem.snap", "backend_type": "File"},
               "resume_vm": True, "vsock_override": {"uds_path": VSOCK_RESTORED}}
    handler = None
    ch_restore = f"source_url=file://{snapdir},memory_restore_mode={mode},resume=true"
    vsock = VSOCK_RESTORED if vmm == "fc" and tier != "cold" else VSOCK
    unlink(API, VSOCK, VSOCK_RESTORED)
    bench.drain(s)
    p = None
    try:
        # Everything before T0 is pool preparation.
        if tier == "prespawn":
            p = spawn_fc(v, API) if vmm == "fc" else spawn_ch(v, api=API, restore="api")
            bench.wait_socket(API).close()
        elif tier == "paused":
            if vmm == "fc":
                p = spawn_fc(v, API)
                bench.wait_socket(API).close()
                if v.get("uffd_populate"):
                    # Copy the whole snapshot into guest memory before T0.
                    usock = f"{RUN}/sv-uffd.sock"
                    handler = subprocess.Popen([f"{bench.WORK}/uffd_populate", usock, f"{snapdir}/mem.snap"],
                                               stdout=subprocess.PIPE, text=True)
                    assert handler.stdout.readline().startswith("listening")
                    fc_load["mem_backend"] = {"backend_path": usock, "backend_type": "Uffd"}
                bench.http(API, "PUT", "/snapshot/load", dict(fc_load, resume_vm=False))
                if handler:
                    assert handler.stdout.readline().startswith("populated")
            else:
                p = spawn_ch(v, api=API, restore=ch_restore.replace("resume=true", "resume=false"))
                deadline = time.monotonic() + 30
                while True:
                    try:
                        if json.loads(bench.http(API, "GET", "/api/v1/vm.info")[1]).get("state") == "Paused":
                            break
                    except (OSError, RuntimeError):
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError("restore never reached Paused")
                    time.sleep(0.001)

        if v.get("tenant") and v.get("attach", "hotadd") == "dm":
            SLOT.clear()  # the previous run left its image in the slot
        elif v.get("tenant") and v.get("attach") == "path":
            point_link(SLOT_PLACEHOLDER)

        t0 = bench.now()
        if v.get("tenant"):
            swap_slot(v)
        t_swap = bench.now()
        t_api = None
        if tier == "cold":
            p = spawn_fc(v, None, fc_cfg(v)) if vmm == "fc" else spawn_ch(v)
        elif tier == "restore":
            if vmm == "fc":
                p = spawn_fc(v, API)
                c = bench.wait_socket(API)
                t_api = bench.now()
                bench.http(c, "PUT", "/snapshot/load", fc_load)
                c.close()
            else:
                p = spawn_ch(v, api=API, restore=ch_restore)
        elif tier == "prespawn":
            if vmm == "fc":
                bench.http(API, "PUT", "/snapshot/load", fc_load)
            else:
                api_mode = {"ondemand": "OnDemand", "copy": "Copy"}[mode]
                bench.http(API, "PUT", "/api/v1/vm.restore",
                           {"source_url": f"file://{snapdir}", "memory_restore_mode": api_mode, "resume": True})
        elif tier == "paused":
            if vmm == "fc":
                bench.http(API, "PATCH", "/vm", {"state": "Resumed"})
            else:
                bench.http(API, "PUT", "/api/v1/vm.resume")
        t_loaded = bench.now()
        if v.get("tenant") and v.get("attach", "hotadd") == "hotadd":
            attach_tenant_disk(v)
        t_vm = bench.now()
        rootfs = {}
        if v.get("tenant"):
            size = os.path.getsize(tenant_disk(v)) if v.get("attach", "hotadd") == "hotadd" else SLOT_SIZE
            rootfs = dict(rootfs="/dev/vda", rootfs_size=size, rootfs_fs=v.get("fs", "ext4"),
                          rootfs_opts=v.get("rootfs_opts"), rootfs_overlay=v.get("overlay", True))
        if PIPELINE:
            records = ctl.start_records(argv, env, cwd=cwd, fixups=fixups, **rootfs)
            c = ctl.connect(vsock, timeout=30, send=ctl.frame(records))
            t_conn = None
            c.settimeout(30)
            reply = ctl.read_reply(c)
        else:
            c = ctl.connect(vsock, timeout=30)
            t_conn = bench.now()
            reply = ctl.start(c, argv, env, cwd=cwd, fixups=fixups, **rootfs)
        t_start = bench.now()
        c.close()
        t1, host_rt, report = wait_child(v, s)
    finally:
        bench.kill(p)
        bench.kill(handler)

    def span(a, b):
        return bench.ms(b - a) if a is not None and b is not None else None
    return {
        "total_ms": span(t0, t1),
        "vm_ms": span(t0, t_vm),        # swap + spawn/load/resume + attach
        "swap_ms": span(t0, t_swap),
        "api_ms": span(t_swap, t_api),  # Firecracker restore: spawn until the API socket answers
        "load_ms": span(t_swap, t_loaded),
        "attach_ms": span(t_loaded, t_vm),
        "start_ms": span(t_vm, t_start),  # vsock connect + START round trip
        "connect_ms": span(t_vm, t_conn),
        "child_ms": span(t_start, t1),
        "instance": instance,
        "report": report,
        "clock_err_ms": round((int(report["rt"]) - host_rt) / 1e6, 3),
        "supervisor": reply,
    }


def summarize(name, v, rows):
    vals = sorted(r["total_ms"] for r in rows)

    def med(k):
        xs = [r[k] for r in rows if r[k] is not None]
        return round(statistics.median(xs), 2) if xs else None
    steps = ("vm_ms", "swap_ms", "api_ms", "load_ms", "attach_ms", "start_ms", "connect_ms", "child_ms")
    sv_keys = ("clock_us", "reseed_us", "net_us", "rootfs_us", "rootfs_wait_us", "rootfs_mount_us",
               "rootfs_overlay_us", "rootfs_switch_us", "spawn_us")
    with open("/sys/kernel/rcu_expedited") as f:
        rcu_expedited = int(f.read())
    out = {
        "name": name, "n": len(vals), "median": round(statistics.median(vals), 2), "min": vals[0],
        "p90": vals[max(0, int(len(vals) * 0.9) - 1)],
        **{k: med(k) for k in steps},
        "supervisor_us": {k: statistics.median(int(r["supervisor"].get(k, 0)) for r in rows) for k in sv_keys},
        "ids_ok": all(r["report"]["id"] == r["instance"] for r in rows),
        "pipeline": PIPELINE, "rcu_expedited": rcu_expedited,
        "variant": v, "runs": [r["total_ms"] for r in rows],
    }
    with open(RESULTS, "a") as f:
        f.write(json.dumps(out) + "\n")
    shown = " ".join(f"{k[:-3]}={out[k]}" for k in steps if out[k] is not None)
    sv = out["supervisor_us"]
    print(f"{name:40} med={out['median']:7.2f} p90={out['p90']:7.2f}  {shown}  "
          f"rootfs_us={sv['rootfs_us']:.0f} (wait {sv['rootfs_wait_us']:.0f}, mount {sv['rootfs_mount_us']:.0f}, "
          f"overlay {sv['rootfs_overlay_us']:.0f}, switch {sv['rootfs_switch_us']:.0f}) spawn_us={sv['spawn_us']:.0f} "
          f"ids_ok={out['ids_ok']}", flush=True)


# Each tier uses the fastest settings found in ../README.md: Firecracker cold boots
# and paused pools on 2 MiB hugepages (the pool pre-copies memory through
# uffd_populate), Firecracker restores from a THP tmpfs, Cloud Hypervisor
# restores on demand and pools in copy mode.
#
# The *_disk and *_attach rows compare two ways of starting a full Linux VM on
# the tenant's own disk: cold-booting it, or restoring a generic base snapshot
# and attaching the disk afterwards. The *_oci_* rows attach a flattened OCI
# image instead (oci/build.sh) and run its own entrypoint. KERNEL picks the
# guest kernel.
THP_TMPFS = "/mnt/vmbench-hugetmp"
KERNEL = os.environ.get("KERNEL", "full")
# PIPELINE=1: send START in the same write as the vsock CONNECT line.
PIPELINE = os.environ.get("PIPELINE") == "1"
MATRIX = {}
for vmm in ("fc", "ch"):
    for child in ("c", "py"):
        tiers = [("cold", {}), ("restore", {}), ("prespawn", {}), ("paused", {}),
                 ("cold_disk", {"disk": True}), ("attach", {"tenant": True}), ("attach_paused", {"tenant": True}),
                 ("oci_attach", {"tenant": True, "oci": True}), ("oci_attach_paused", {"tenant": True, "oci": True}),
                 ("ocipyc_attach", {"tenant": True, "oci": "py-pyc"}),
                 ("ocipyc_attach_paused", {"tenant": True, "oci": "py-pyc"})]
        for name, extra in tiers:
            tier = {"cold_disk": "cold", "attach": "restore", "attach_paused": "paused",
                    "oci_attach": "restore", "oci_attach_paused": "paused",
                    "ocipyc_attach": "restore", "ocipyc_attach_paused": "paused"}.get(name, name)
            if name == "cold_disk" and child == "py":
                continue  # fc_py_cold already boots from the Ubuntu disk
            if name.startswith("ocipyc") and child != "py":
                continue
            v = {"vmm": vmm, "child": child, "tier": tier, "kernel": KERNEL, **extra}
            if vmm == "fc" and tier in ("cold", "paused"):
                v["huge"] = True
            if vmm == "fc" and tier == "paused":
                v["uffd_populate"] = True
            if vmm == "fc" and tier in ("restore", "prespawn"):
                v["snapdir"] = f"{THP_TMPFS}/sv-snap-fc-{child}" + ("-base" if v.get("tenant") else "")
            MATRIX[f"{vmm}_{child}_{name}"] = v

# Restore (or resume) a generic base snapshot and give it an OCI image (the
# scratch image for the C probe, precompiled Python for py): how the disk
# arrives, its filesystem, and whether the root gets a tmpfs overlay ("ro"
# mounts the image directly; only /tmp, /run and /dev are writable).
# Named <vmm>_<child>_oci_<attach>_<fs>_<root>_<tier>.
ROOTS = {"overlay": {}, "ro": {"overlay": False}, "noload": {"overlay": False, "rootfs_opts": "noload"}}
for vmm in ("fc", "ch"):
    for child in ("c", "py"):
        for attach in ("hotadd", "dm", "path"):
            for fs in ("ext4", "erofs"):
                for root, opts in ROOTS.items():
                    for tier in ("restore", "paused"):
                        if (root == "noload" and fs != "ext4") or (attach == "path" and tier == "paused"):
                            continue
                        v = {"vmm": vmm, "child": child, "tier": tier, "kernel": KERNEL, "tenant": True,
                             "oci": "py-pyc" if child == "py" else True, "attach": attach, "fs": fs, **opts}
                        if vmm == "fc" and tier == "paused":
                            v.update(huge=True, uffd_populate=True)
                        if vmm == "fc" and tier == "restore":
                            v["snapdir"] = f"{THP_TMPFS}/sv-snap-fc-{child}-base"
                        MATRIX[f"{vmm}_{child}_oci_{attach}_{fs}_{root}_{tier}"] = v


def bench_matrix(s, runs, only):
    for name, v in MATRIX.items():
        if only and name not in only:
            continue
        v = guest(v)
        try:
            snapdir = v.get("snapdir", f"{RUN}/sv-snap-{v['vmm']}-{v['child']}" + ("-base" if v.get("tenant") else ""))
            if v["tier"] != "cold":
                make_snapshot(v, s, snapdir)
            run_once(v, s, snapdir, "warmup")
            rows = [run_once(v, s, snapdir, f"{name}-{i}") for i in range(runs)]
            summarize(name, v, rows)
        except Exception as e:
            print(json.dumps({"name": name, "error": repr(e)}), flush=True)


def check_clones(s, n=3, age=2.0, fixups=True):
    """Restore one snapshot n times, each behind a fresh TAP, and compare.
    fixups=False is the control: START without the clock and seed."""
    for vmm in ("fc", "ch"):
        for child in ("c", "py") if fixups else ("c",):
            v = guest({"vmm": vmm, "child": child, "tier": "restore", "kernel": "tiny"})
            snapdir = f"{RUN}/sv-clone-{vmm}-{child}"
            make_snapshot(v, s, snapdir)
            time.sleep(age)
            rows = []
            for i in range(n):
                bench.setup_net()  # new TAP, new host MAC
                rows.append(run_once(v, s, snapdir, f"clone-{i + 1}", fixups))
            label = "" if fixups else ", control: no clock or seed in START"
            print(f"== {vmm} / {child}_child (snapshot aged {age:.0f} s, kernel without VMGenID{label})")
            for r in rows:
                sv = r["supervisor"]
                fixed = f"clock was {int(sv['clock_skew_us']) / 1e6:+.2f} s off, " if fixups else ""
                print(f"   {r['instance']}: env id={r['report']['id']:8} rnd={r['report']['rnd']}  "
                      f"{fixed}child's clock {r['clock_err_ms']:+.2f} ms vs host  "
                      f"reseeded={sv['reseeded']}  ready in {r['total_ms']:.1f} ms")
            rnds = [r["report"]["rnd"] for r in rows]
            print(f"   ids match env: {all(r['report']['id'] == r['instance'] for r in rows)}; "
                  f"random values distinct: {len(set(rnds)) == len(rnds)}; "
                  f"clocks within 5 ms: {all(abs(r['clock_err_ms']) < 5 for r in rows)}", flush=True)


def main():
    if os.environ.get("CPUS"):
        os.sched_setaffinity(0, {int(c) for c in os.environ["CPUS"].split(",")})
    global SLOT
    os.makedirs(RUN, exist_ok=True)
    bench.kill_stray_vmms()
    bench.setup_net()
    s = bench.udp_socket()
    SLOT = dmslot.Slot("vmbench-slot", SLOT_SIZE)
    try:
        if len(sys.argv) > 1 and sys.argv[1] in ("clones", "clones-control"):
            check_clones(s, fixups=sys.argv[1] == "clones")
        else:
            runs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
            only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
            bench_matrix(s, runs, only)
    finally:
        bench.kill_stray_vmms()
        SLOT.close()
        bench.sh("ip", "link", "del", bench.TAP, check=False)


if __name__ == "__main__":
    main()
