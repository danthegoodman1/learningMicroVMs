#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/qemu-snapshot.qmp}"
PIDFILE="${PIDFILE:-$WORK_DIR/qemu.pid}"
TAP_DEV="${TAP_DEV:-tap-qsnapshot}"
TAP_IP="${TAP_IP:-172.16.34.1}"
TAP_CIDR="${TAP_CIDR:-172.16.34.0/30}"
GUEST_IP="${GUEST_IP:-172.16.34.2}"
MAC="${MAC:-06:00:AC:10:22:02}"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
QEMU_NETWORK_STATE="${QEMU_NETWORK_STATE:-$WORK_DIR/network.state}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
RESTORE_RUNS="${RESTORE_RUNS:-3}"
PRE_SIGNAL_RESTORE="${PRE_SIGNAL_RESTORE:-1}"
EVICT_SNAPSHOT_CACHE="${EVICT_SNAPSHOT_CACHE:-0}"
ROOTFS_SRC="$(qemu_find_rootfs)"
ROOTFS="$WORK_DIR/rootfs.ext4"
SIGNAL_IMG="$WORK_DIR/signal.img"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-$WORK_DIR/qemu.snapshot}"
CONSOLE_LOG="${CONSOLE_LOG:-$WORK_DIR/console.log}"
LOGFILE="${LOGFILE:-$WORK_DIR/qemu.log}"
RESULTS_CSV="${RESULTS_CSV:-$WORK_DIR/results.csv}"
RESULTS_JSON="${RESULTS_JSON:-$WORK_DIR/results.json}"
MEMORY_MIB="$BENCH_MEM_MIB"
CPUS="$BENCH_VCPUS"
export MEMORY_MIB CPUS
METADATA_PID=""

now_ms() {
    echo "$(( $(date +%s%N) / 1000000 ))"
}

elapsed_ms() {
    echo "$(( $(now_ms) - $1 ))"
}

cleanup() {
    if mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        sudo umount "$WORK_DIR/mnt" 2>/dev/null || true
    fi
    qemu_stop_existing_vm || true
    if [ -n "$METADATA_PID" ]; then
        sudo pkill -TERM -P "$METADATA_PID" 2>/dev/null || true
        sudo kill "$METADATA_PID" 2>/dev/null || true
    fi
    qemu_cleanup_tap || true
}
trap cleanup EXIT

wait_for_marker() {
    local marker="$1" timeout="${2:-30}" start="${3:-$(now_ms)}" end
    end=$((start + timeout * 1000))
    while [ "$(now_ms)" -lt "$end" ]; do
        if grep -q "$marker" "$CONSOLE_LOG" 2>/dev/null; then
            elapsed_ms "$start"
            return
        fi
        sleep 0.02
    done
    echo "Timed out waiting for $marker" >&2
    tail -n 80 "$CONSOLE_LOG" >&2 || true
    return 1
}

write_signal() {
    printf '%-512s' "$1" | dd of="$SIGNAL_IMG" bs=512 count=1 conv=notrunc status=none
    sync "$SIGNAL_IMG"
}

evict_snapshot_cache() {
    [ "$EVICT_SNAPSHOT_CACHE" = 1 ] || return 0
    sync
    sudo python3 - "$SNAPSHOT_FILE" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
finally:
    os.close(fd)
PY
}

prepare_rootfs() {
    mkdir -p "$WORK_DIR"
    cp "$ROOTFS_SRC" "$ROOTFS"
    mkdir -p "$WORK_DIR/mnt"
    sudo mount -o loop "$ROOTFS" "$WORK_DIR/mnt"
    sudo tee "$WORK_DIR/mnt/snapshot-init.sh" >/dev/null <<'EOF'
#!/bin/sh

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

i=0
while [ "$i" -lt 100 ]; do
    ip link show eth0 >/dev/null 2>&1 && break
    sleep 0.05
    i=$((i + 1))
done
ip link set eth0 up 2>/dev/null || true
ip addr add 172.16.34.2/30 dev eth0 2>/dev/null || true
ip route replace default via 172.16.34.1 dev eth0 2>/dev/null || true

metadata="$(curl -fsS --max-time 5 http://169.254.169.254/instance-id 2>/dev/null || true)"
[ "$metadata" = vm-001 ] && metadata_status=ok || metadata_status=bad
echo "SNAP_BENCH_READY metadata=${metadata_status}"

while true; do
    magic="$(dd if=/dev/vdb bs=512 count=1 2>/dev/null | tr -d '\000' | head -c 2)"
    [ "$magic" = GO ] && break
    sleep 0.02
done

metadata="$(curl -fsS --max-time 5 http://169.254.169.254/instance-id 2>/dev/null || true)"
[ "$metadata" = vm-001 ] && metadata_status=ok || metadata_status=bad
echo "SNAP_BENCH_GO metadata=${metadata_status}"
while true; do sleep 3600; done
EOF
    sudo chmod +x "$WORK_DIR/mnt/snapshot-init.sh"
    sudo umount "$WORK_DIR/mnt"
    rmdir "$WORK_DIR/mnt"

    truncate -s 1M "$SIGNAL_IMG"
    write_signal WAIT
}

start_metadata() {
    sudo env METADATA_IP="$METADATA_IP" python3 - <<'PY' &
import http.server
import os
import socketserver

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def do_GET(self):
        values = {
            "/": "instance-id\nlocal-ipv4\njson\n",
            "/instance-id": "vm-001\n",
            "/local-ipv4": "172.16.34.2\n",
            "/json": '{"instance-id":"vm-001","local-ipv4":"172.16.34.2"}\n',
        }
        body = values.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body.encode())

class Server(socketserver.TCPServer):
    allow_reuse_address = True

Server((os.environ["METADATA_IP"], 80), Handler).serve_forever()
PY
    METADATA_PID="$!"
    sleep 0.2
}

vm_extra_args() {
    printf '%s\n' \
        -drive "file=${SIGNAL_IMG},format=raw,if=none,id=signal,cache=none" \
        -device virtio-blk-device,drive=signal
}

start_vm() {
    local mode="${1:-source}" extra_args=()
    mapfile -t extra_args < <(vm_extra_args)
    if [ "$mode" = restore ]; then
        extra_args+=(-incoming defer)
    fi
    qemu_start_vm "$(qemu_kernel_boot_args ro 'init=/snapshot-init.sh')" on "${extra_args[@]}"
}

enable_mapped_ram() {
    qemu_qmp migrate-set-capabilities \
        '{"capabilities":[{"capability":"mapped-ram","state":true}]}' >/dev/null
}

wait_for_migration() {
    local status
    for _ in $(seq 1 600); do
        status="$(qemu_qmp query-migrate)"
        if grep -q '"status":"completed"' <<<"$status"; then
            return
        fi
        if grep -Eq '"status":"(failed|cancelled)"' <<<"$status"; then
            echo "$status" >&2
            return 1
        fi
        sleep 0.05
    done
    echo "Timed out waiting for QEMU migration" >&2
    return 1
}

main() {
    mkdir -p "$WORK_DIR"
    if mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        sudo umount "$WORK_DIR/mnt"
    fi
    rm -f "$ROOTFS" "$SIGNAL_IMG" "$SNAPSHOT_FILE" \
        "$CONSOLE_LOG" "$LOGFILE" "$RESULTS_CSV" "$RESULTS_JSON" "$PIDFILE"
    prepare_rootfs
    qemu_setup_tap metadata
    start_metadata

    echo "QEMU mapped-RAM snapshot demo"
    echo "  rootfs: $ROOTFS_SRC"
    echo "  memory: ${BENCH_MEM_MIB}MiB, vcpus: $BENCH_VCPUS"
    echo "  snapshot: $SNAPSHOT_FILE"
    echo "  pre-signal restore: $PRE_SIGNAL_RESTORE"
    echo "  evict snapshot cache: $EVICT_SNAPSHOT_CACHE"

    local start cold_ms pause_ms snapshot_ms restore_ms run json_values=""
    start="$(now_ms)"
    start_vm source
    cold_ms="$(wait_for_marker SNAP_BENCH_READY 60 "$start")"
    grep -q 'SNAP_BENCH_READY metadata=ok' "$CONSOLE_LOG" || {
        echo "Metadata check failed during cold boot" >&2
        exit 1
    }

    start="$(now_ms)"
    qemu_qmp stop >/dev/null
    pause_ms="$(elapsed_ms "$start")"

    rm -f "$SNAPSHOT_FILE"
    enable_mapped_ram
    start="$(now_ms)"
    qemu_qmp migrate "{\"uri\":\"file:${SNAPSHOT_FILE}\"}" >/dev/null
    wait_for_migration
    snapshot_ms="$(elapsed_ms "$start")"
    qemu_stop_existing_vm

    echo "hypervisor,run,cold_ready_ms,pause_ms,snapshot_create_ms,restore_ready_ms,restore_mode,metadata_ok" > "$RESULTS_CSV"
    for run in $(seq 1 "$RESTORE_RUNS"); do
        write_signal WAIT
        [ "$PRE_SIGNAL_RESTORE" != 1 ] || write_signal GO
        evict_snapshot_cache
        start="$(now_ms)"
        start_vm restore
        enable_mapped_ram
        qemu_qmp migrate-incoming "{\"uri\":\"file:${SNAPSHOT_FILE}\"}" >/dev/null
        wait_for_migration
        qemu_qmp cont >/dev/null
        [ "$PRE_SIGNAL_RESTORE" = 1 ] || write_signal GO
        restore_ms="$(wait_for_marker SNAP_BENCH_GO 30 "$start")"
        grep -q 'SNAP_BENCH_GO metadata=ok' "$CONSOLE_LOG" || {
            echo "Metadata check failed after restore" >&2
            exit 1
        }
        qemu_stop_existing_vm
        echo "qemu,$run,$cold_ms,$pause_ms,$snapshot_ms,$restore_ms,mapped-ram,ok" >> "$RESULTS_CSV"
        json_values="${json_values}${json_values:+,}$restore_ms"
    done

    cat > "$RESULTS_JSON" <<EOF
{"hypervisor":"qemu","cold_ready_ms":$cold_ms,"pause_ms":$pause_ms,"snapshot_create_ms":$snapshot_ms,"restore_ready_ms":[$json_values],"restore_mode":"mapped-ram","metadata_ok":true}
EOF

    echo
    echo "QEMU results:"
    column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"
}

main "$@"
