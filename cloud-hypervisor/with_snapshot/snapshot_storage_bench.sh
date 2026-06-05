#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RESTORE_RUNS="${RESTORE_RUNS:-3}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
RESTORE_MODE="${RESTORE_MODE:-ondemand}"
EVICT_DISK_CACHE="${EVICT_DISK_CACHE:-1}"
DISK_WORK_DIR="${DISK_WORK_DIR:-$SCRIPT_DIR/work/storage-disk}"
MEMORY_WORK_DIR="${MEMORY_WORK_DIR:-$SCRIPT_DIR/work/storage-memory}"
DISK_SNAPSHOT_DIR="${DISK_SNAPSHOT_DIR:-$DISK_WORK_DIR/ch.snapshot}"
TMPFS_BASE="${TMPFS_BASE:-/dev/shm/ch-snapshot-storage-${USER:-user}-$$}"
MEMORY_SNAPSHOT_DIR="${MEMORY_SNAPSHOT_DIR:-$TMPFS_BASE/ch.snapshot}"
RESULTS_CSV="${RESULTS_CSV:-$SCRIPT_DIR/work/storage-results.csv}"

cleanup() {
    rm -rf "$TMPFS_BASE"
}
trap cleanup EXIT

run_case() {
    local label="$1"
    local work_dir="$2"
    local snapshot_dir="$3"
    local evict_cache="$4"
    local api_socket="/tmp/cloud-hypervisor-snapshot-${label}.sock"
    local env_args

    mkdir -p "$work_dir" "$(dirname -- "$snapshot_dir")"

    echo ""
    echo "Running $label snapshot restore"
    echo "  snapshot: $snapshot_dir"

    env_args=(
        "WORK_DIR=$work_dir"
        "SNAPSHOT_DIR=$snapshot_dir"
        "RESULTS_CSV=$work_dir/results.csv"
        "RESULTS_JSON=$work_dir/results.json"
        "API_SOCKET=$api_socket"
        "RESTORE_RUNS=$RESTORE_RUNS"
        "BENCH_MEM_MIB=$BENCH_MEM_MIB"
        "BENCH_VCPUS=$BENCH_VCPUS"
        "RESTORE_MODE=$RESTORE_MODE"
        "EVICT_SNAPSHOT_CACHE=$evict_cache"
    )

    if [ -n "${ROOTFS:-}" ]; then
        env_args+=("ROOTFS=$ROOTFS")
    fi
    if [ -n "${KERNEL:-}" ]; then
        env_args+=("KERNEL=$KERNEL")
    fi
    if [ -n "${CLOUD_HYPERVISOR_BIN:-}" ]; then
        env_args+=("CLOUD_HYPERVISOR_BIN=$CLOUD_HYPERVISOR_BIN")
    fi
    if [ -n "${CH_REMOTE_BIN:-}" ]; then
        env_args+=("CH_REMOTE_BIN=$CH_REMOTE_BIN")
    fi

    env "${env_args[@]}" "$SCRIPT_DIR/snapshot_bench.sh"
}

main() {
    mkdir -p "$(dirname -- "$RESULTS_CSV")"

    echo "Cloud Hypervisor snapshot storage benchmark"
    echo "  memory: ${BENCH_MEM_MIB}MiB, vcpus: $BENCH_VCPUS, restore runs: $RESTORE_RUNS"
    echo "  restore mode: $RESTORE_MODE"
    echo "  evict disk snapshot cache: $EVICT_DISK_CACHE"
    echo "  disk snapshot: $DISK_SNAPSHOT_DIR"
    echo "  memory snapshot: $MEMORY_SNAPSHOT_DIR"

    run_case disk "$DISK_WORK_DIR" "$DISK_SNAPSHOT_DIR" "$EVICT_DISK_CACHE"
    run_case memory "$MEMORY_WORK_DIR" "$MEMORY_SNAPSHOT_DIR" 0

    {
        echo "snapshot_storage,hypervisor,run,cold_ready_ms,pause_ms,snapshot_create_ms,restore_ready_ms,restore_mode,metadata_ok"
        awk -F, 'NR > 1 { print "disk," $0 }' "$DISK_WORK_DIR/results.csv"
        awk -F, 'NR > 1 { print "memory," $0 }' "$MEMORY_WORK_DIR/results.csv"
    } > "$RESULTS_CSV"

    echo ""
    echo "Storage comparison:"
    column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"
    echo ""
    echo "Wrote $RESULTS_CSV"
}

main "$@"
