#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RESTORE_RUNS="${RESTORE_RUNS:-3}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
EVICT_DISK_CACHE="${EVICT_DISK_CACHE:-1}"
DISK_WORK_DIR="${DISK_WORK_DIR:-$SCRIPT_DIR/work/storage-disk}"
MEMORY_WORK_DIR="${MEMORY_WORK_DIR:-$SCRIPT_DIR/work/storage-memory}"
TMPFS_BASE="${TMPFS_BASE:-/dev/shm/qemu-snapshot-storage-${USER:-user}-$$}"
RESULTS_CSV="${RESULTS_CSV:-$SCRIPT_DIR/work/storage-results.csv}"

cleanup() {
    rm -f "$TMPFS_BASE/qemu.snapshot"
    rmdir "$TMPFS_BASE" 2>/dev/null || true
}
trap cleanup EXIT

run_case() {
    local label="$1" work_dir="$2" snapshot_file="$3" evict="$4"
    local env_args
    mkdir -p "$work_dir" "$(dirname -- "$snapshot_file")"
    echo
    echo "Running $label snapshot restore from $snapshot_file"
    env_args=(
        "WORK_DIR=$work_dir"
        "SNAPSHOT_FILE=$snapshot_file"
        "RESULTS_CSV=$work_dir/results.csv"
        "RESULTS_JSON=$work_dir/results.json"
        "QMP_SOCKET=/tmp/qemu-snapshot-${label}.qmp"
        "RESTORE_RUNS=$RESTORE_RUNS"
        "BENCH_MEM_MIB=$BENCH_MEM_MIB"
        "BENCH_VCPUS=$BENCH_VCPUS"
        "EVICT_SNAPSHOT_CACHE=$evict"
    )
    [ -z "${ROOTFS:-}" ] || env_args+=("ROOTFS=$ROOTFS")
    [ -z "${KERNEL:-}" ] || env_args+=("KERNEL=$KERNEL")
    env "${env_args[@]}" "$SCRIPT_DIR/snapshot_bench.sh"
}

mkdir -p "$(dirname -- "$RESULTS_CSV")"
run_case disk "$DISK_WORK_DIR" "$DISK_WORK_DIR/qemu.snapshot" "$EVICT_DISK_CACHE"
run_case memory "$MEMORY_WORK_DIR" "$TMPFS_BASE/qemu.snapshot" 0

{
    echo "snapshot_storage,hypervisor,run,cold_ready_ms,pause_ms,snapshot_create_ms,restore_ready_ms,restore_mode,metadata_ok"
    awk -F, 'NR > 1 { print "disk," $0 }' "$DISK_WORK_DIR/results.csv"
    awk -F, 'NR > 1 { print "memory," $0 }' "$MEMORY_WORK_DIR/results.csv"
} > "$RESULTS_CSV"

echo
echo "QEMU snapshot storage comparison:"
column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"
