#!/usr/bin/env bash
# Reruns the measurements behind REPORT.md, one group at a time. Most groups
# write work/repro/<group>.jsonl, one line per configuration with its median,
# p90 and every run (bench_supervisor.py groups also keep their console output
# as <group>.log). profile also writes profile-<fc|ch>.txt, repo-scripts writes
# repo-scripts-<fc|ch>.csv (one row per run), and clones writes clones.txt.
# Run ./setup.sh first.
#
# usage: sudo ./reproduce.sh <group>... | all
#   RUNS=n    overrides every group's run count (for a quick check)
#   CPUS=list CPUs to pin to (default: the P-cores, /sys/devices/cpu_core/cpus)
#
# group            what runs                                        REPORT.md section
# steps            bench.py final.json, 30 runs                     the four step tables
# pagecache        bench.py pagecache.json, 20 runs                 cold boots with files evicted (caveats)
# kernels          bench.py kernels.json, 30 runs                   Summary; A full-featured guest kernel
# profile          bench.py profile-full.json, 3 runs, then         the profiled full boot
#                  tools/gaps.py
# repo-scripts     the repo's */with_snapshot/snapshot_bench.sh     the repo-script baselines
#                  with RESTORE_RUNS=5; needs iptables and a
#                  default route
# supervisor       bench_supervisor.py @supervisor, 20 runs         Launching customer code on restore;
#                                                                     cold boots and Python as shipped
#                                                                     in Building fast-starting Linux VMs
# supervisor-tiny  @supervisor-tiny on KERNEL=tiny                  (its tiny-kernel comparison)
# clones           bench_supervisor.py clones, then clones-control  (its clone check)
# rootfs           @rootfs, 20 runs                                 Building fast-starting Linux VMs:
# rootfs-rcu       @rootfs-rcu with rcu_expedited=1                   attach modes, ext4, expedited RCU,
# rootfs-pipeline  @rootfs-pipeline with PIPELINE=1                   pipelined START,
# erofs-inline     @erofs-inline                                      EROFS inline tails,
# erofs            @erofs                                             EROFS (the table's EROFS rows),
# erofs-rcu        @erofs-rcu with rcu_expedited=1                    paused pools with expedited RCU
#
# Every group runs with /sys/kernel/rcu_expedited=0 unless listed otherwise.
# The script reserves 1024 hugepages, mounts a huge=always tmpfs at
# /mnt/vmbench-hugetmp, and on exit restores those, rcu_expedited and
# net.ipv4.ip_forward (which the repo scripts turn on).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/.." && pwd)"
OUT="$HERE/work/repro"
GROUPS_ALL=(steps pagecache kernels profile repo-scripts supervisor supervisor-tiny clones
            rootfs rootfs-rcu rootfs-pipeline erofs-inline erofs erofs-rcu)

if [ "$(id -u)" != 0 ]; then
    echo "run as root: sudo $0 $*" >&2
    exit 1
fi
if [ $# -eq 0 ]; then
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
fi
[ "$1" = all ] && set -- "${GROUPS_ALL[@]}"
for g in "$@"; do
    [[ " ${GROUPS_ALL[*]} " == *" $g "* ]] || { echo "unknown group: $g" >&2; exit 1; }
done
if [ ! -f "$HERE/work/vmlinux-full" ] || [ ! -f "$HERE/work/oci-scratch.erofs" ]; then
    echo "run ./setup.sh first" >&2
    exit 1
fi

# Pin to the P-cores of a hybrid Intel CPU; elsewhere, to every online CPU.
if [ -z "${CPUS:-}" ]; then
    range="$(cat /sys/devices/cpu_core/cpus 2>/dev/null || cat /sys/devices/system/cpu/online)"
    CPUS="$(python3 -c '
import sys
cpus = []
for part in sys.argv[1].split(","):
    a, _, b = part.partition("-")
    cpus += range(int(a), int(b or a) + 1)
print(",".join(map(str, cpus)))' "$range")"
fi
export CPUS

# Host setup, undone on exit.
old_hugepages="$(cat /proc/sys/vm/nr_hugepages)"
old_rcu="$(cat /sys/kernel/rcu_expedited)"
old_forward="$(cat /proc/sys/net/ipv4/ip_forward)"
mounted=0
restore_host() {
    echo "$old_rcu" > /sys/kernel/rcu_expedited
    echo "$old_forward" > /proc/sys/net/ipv4/ip_forward
    if [ "$mounted" = 1 ]; then umount /mnt/vmbench-hugetmp && rmdir /mnt/vmbench-hugetmp; fi
    sysctl -qw vm.nr_hugepages="$old_hugepages"
}
trap restore_host EXIT
sysctl -qw vm.nr_hugepages=1024
if ! mountpoint -q /mnt/vmbench-hugetmp; then
    mkdir -p /mnt/vmbench-hugetmp
    mount -t tmpfs -o huge=always,size=4G tmpfs /mnt/vmbench-hugetmp
    mounted=1
fi
mkdir -p "$OUT"
echo "CPUS=$CPUS; results in $OUT"

runs() { echo "${RUNS:-$1}"; }
rcu() { echo "$1" > /sys/kernel/rcu_expedited; }

bench() {  # bench <group> <experiments.json> <runs>
    rcu 0
    python3 "$HERE/bench.py" "$HERE/$2" "$(runs "$3")" | tee "$OUT/$1.jsonl"
}

supervisor() {  # supervisor <group> [ENV=value...]: runs bench_supervisor.py's set of that name
    local group="$1"
    shift
    rm -f "$OUT/$group.jsonl"
    env RESULTS="$OUT/$group.jsonl" "$@" python3 "$HERE/supervisor/bench_supervisor.py" "$(runs 20)" "@$group" \
        | tee "$OUT/$group.log"
}

for g in "$@"; do
    echo "== $g"
    case "$g" in
    steps) bench steps final.json 30 ;;
    pagecache) bench pagecache pagecache.json 20 ;;
    kernels) bench kernels kernels.json 30 ;;
    profile)
        bench profile profile-full.json 3
        for vmm in fc ch; do
            python3 "$HERE/tools/gaps.py" "/dev/shm/vmbench/$vmm-full.dmesg" | tee "$OUT/profile-$vmm.txt"
        done
        ;;
    repo-scripts)
        rcu 0
        for vmm in fc:firecracker ch:cloud-hypervisor; do
            dir="$REPO/${vmm#*:}/with_snapshot"
            (cd "$dir" && RESTORE_RUNS="$(runs 5)" ./snapshot_bench.sh)
            cp "$dir/work/results.csv" "$OUT/repo-scripts-${vmm%%:*}.csv"
        done
        ;;
    supervisor | supervisor-tiny | rootfs | rootfs-pipeline | erofs-inline | erofs)
        rcu 0
        case "$g" in
        supervisor-tiny) supervisor "$g" KERNEL=tiny ;;
        rootfs-pipeline) supervisor "$g" PIPELINE=1 ;;
        *) supervisor "$g" ;;
        esac
        ;;
    rootfs-rcu | erofs-rcu) rcu 1; supervisor "$g" ;;
    clones)
        rcu 0
        for mode in clones clones-control; do
            python3 "$HERE/supervisor/bench_supervisor.py" "$mode"
        done | tee "$OUT/clones.txt"
        ;;
    esac
done
