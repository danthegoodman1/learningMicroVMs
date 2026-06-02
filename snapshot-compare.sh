#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="${ROOTFS:-$ROOT_DIR/firecracker/ubuntu-22.04.ext4}"
RESTORE_RUNS="${RESTORE_RUNS:-3}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
RESULTS="$ROOT_DIR/snapshot-results.csv"

echo "SnapStart-style snapshot comparison"
echo "  rootfs: $ROOTFS"
echo "  memory: ${BENCH_MEM_MIB}MiB, vcpus: $BENCH_VCPUS, restore runs: $RESTORE_RUNS"
echo ""

ROOTFS="$ROOTFS" RESTORE_RUNS="$RESTORE_RUNS" BENCH_MEM_MIB="$BENCH_MEM_MIB" BENCH_VCPUS="$BENCH_VCPUS" \
    "$ROOT_DIR/firecracker/with_snapshot/snapshot_bench.sh"

ROOTFS="$ROOTFS" RESTORE_RUNS="$RESTORE_RUNS" BENCH_MEM_MIB="$BENCH_MEM_MIB" BENCH_VCPUS="$BENCH_VCPUS" \
    "$ROOT_DIR/cloud-hypervisor/with_snapshot/snapshot_bench.sh"

head -n 1 "$ROOT_DIR/firecracker/with_snapshot/work/results.csv" > "$RESULTS"
tail -n +2 "$ROOT_DIR/firecracker/with_snapshot/work/results.csv" >> "$RESULTS"
tail -n +2 "$ROOT_DIR/cloud-hypervisor/with_snapshot/work/results.csv" >> "$RESULTS"

echo ""
echo "Combined results:"
column -t -s, "$RESULTS" 2>/dev/null || cat "$RESULTS"
echo ""
echo "Wrote $RESULTS"
