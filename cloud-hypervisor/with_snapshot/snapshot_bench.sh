#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
API_SOCKET="${API_SOCKET:-/tmp/cloud-hypervisor-snapshot.sock}"
TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
GUEST_IP="${GUEST_IP:-172.16.0.2}"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
RESTORE_RUNS="${RESTORE_RUNS:-3}"
ROOTFS_SRC="$(ch_find_rootfs)"
ROOTFS="$WORK_DIR/rootfs.ext4"
SIGNAL_IMG="$WORK_DIR/signal.img"
SNAPSHOT_DIR="$WORK_DIR/ch.snapshot"
CONSOLE_LOG="$WORK_DIR/console.log"
LOGFILE="$WORK_DIR/cloud-hypervisor.log"
PIDFILE="$WORK_DIR/cloud-hypervisor.pid"
RESULTS_CSV="$WORK_DIR/results.csv"
RESULTS_JSON="$WORK_DIR/results.json"
METADATA_PID=""

now_ms() {
    echo "$(( $(date +%s%N) / 1000000 ))"
}

elapsed_ms() {
    local start="$1"
    echo "$(( $(now_ms) - start ))"
}

cleanup() {
    if mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        sudo umount "$WORK_DIR/mnt" 2>/dev/null || true
    fi
    ch_stop_existing_vm || true
    if [ -n "$METADATA_PID" ]; then
        sudo kill "$METADATA_PID" 2>/dev/null || true
    fi
    sudo rm -f "$API_SOCKET"
    sudo ip link del "$TAP_DEV" 2>/dev/null || true

    local host_iface
    host_iface="$(ch_host_iface)"
    while sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null; do :; done
    while sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null; do :; done
}
trap cleanup EXIT

wait_for_marker() {
    local marker="$1"
    local timeout="${2:-30}"
    local start="${3:-$(now_ms)}"
    local end
    end=$((start + timeout * 1000))

    while [ "$(now_ms)" -lt "$end" ]; do
        if grep -q "$marker" "$CONSOLE_LOG" 2>/dev/null; then
            elapsed_ms "$start"
            return 0
        fi
        sleep 0.02
    done

    echo "Timed out waiting for $marker" >&2
    tail -n 80 "$CONSOLE_LOG" >&2 || true
    return 1
}

write_signal() {
    local value="$1"
    printf '%-512s' "$value" | dd of="$SIGNAL_IMG" bs=512 count=1 conv=notrunc status=none
    sync "$SIGNAL_IMG"
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
ip addr add 172.16.0.2/30 dev eth0 2>/dev/null || true
ip route replace default via 172.16.0.1 dev eth0 2>/dev/null || true

metadata="$(curl -fsS --max-time 5 http://169.254.169.254/instance-id 2>/dev/null || true)"
if [ "$metadata" = "vm-001" ]; then
    metadata_status="ok"
else
    metadata_status="bad"
fi

echo "SNAP_BENCH_READY metadata=${metadata_status}"

while true; do
    magic="$(dd if=/dev/vdb bs=512 count=1 2>/dev/null | tr -d '\000' | head -c 2)"
    [ "$magic" = "GO" ] && break
    sleep 0.02
done

metadata="$(curl -fsS --max-time 5 http://169.254.169.254/instance-id 2>/dev/null || true)"
if [ "$metadata" = "vm-001" ]; then
    metadata_status="ok"
else
    metadata_status="bad"
fi

echo "SNAP_BENCH_GO metadata=${metadata_status}"

while true; do
    sleep 3600
done
EOF
    sudo chmod +x "$WORK_DIR/mnt/snapshot-init.sh"
    sudo umount "$WORK_DIR/mnt"
    rmdir "$WORK_DIR/mnt"

    dd if=/dev/zero of="$SIGNAL_IMG" bs=1M count=1 status=none
    write_signal "WAIT"
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
            "/local-ipv4": "172.16.0.2\n",
            "/json": '{"instance-id":"vm-001","local-ipv4":"172.16.0.2"}\n',
        }
        body = values.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

class Server(socketserver.TCPServer):
    allow_reuse_address = True

Server((os.environ["METADATA_IP"], 80), Handler).serve_forever()
PY
    METADATA_PID="$!"
    sleep 0.2
}

start_ch_process() {
    local mode="${1:-}"
    local bin kernel
    bin="$(ch_find_binary)"
    kernel="$(ch_find_kernel)"
    sudo rm -f "$API_SOCKET"
    : > "$CONSOLE_LOG"
    : > "$LOGFILE"

    local args
    args=(
        --kernel "$kernel"
        --cmdline "$(ch_kernel_boot_args rw "init=/snapshot-init.sh")"
        --disk "path=${ROOTFS},readonly=on"
        --disk "path=${SIGNAL_IMG},readonly=off"
        --cpus "boot=${BENCH_VCPUS}"
        --memory "size=${BENCH_MEM_MIB}M"
        --net "tap=${TAP_DEV},mac=06:00:AC:10:00:02"
        --api-socket "path=$API_SOCKET"
        --serial "file=$CONSOLE_LOG"
        --console off
        --log-file "$LOGFILE"
    )

    if [ -n "$mode" ]; then
        args+=(--restore "source_url=file://${SNAPSHOT_DIR},memory_restore_mode=${mode},resume=true")
    fi

    sudo "$bin" "${args[@]}" &
    local sudo_pid real_pid
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "${PIDFILE}.sudo"

    sleep 0.1
    real_pid="$(pgrep -P "$sudo_pid" -f "$(basename "$bin")" | head -n 1 || true)"
    printf '%s\n' "${real_pid:-$sudo_pid}" > "$PIDFILE"

    if ! ch_pid_alive "$(cat "$PIDFILE")"; then
        echo "Cloud Hypervisor exited early" >&2
        tail -n 80 "$LOGFILE" >&2 || true
        return 1
    fi
}

start_source_vm() {
    start_ch_process
}

start_restore_vm() {
    start_ch_process "$1"
}

main() {
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    prepare_rootfs
    ch_setup_tap metadata
    start_metadata

    echo "Cloud Hypervisor snapshot demo"
    echo "  rootfs: $ROOTFS_SRC"
    echo "  memory: ${BENCH_MEM_MIB}MiB, vcpus: $BENCH_VCPUS"

    local cold_ms pause_ms snapshot_ms restore_ms start run restore_mode json_values
    start="$(now_ms)"
    start_source_vm
    cold_ms="$(wait_for_marker SNAP_BENCH_READY 60 "$start")"
    if ! grep -q 'SNAP_BENCH_READY metadata=ok' "$CONSOLE_LOG"; then
        echo "Metadata check failed during cold boot" >&2
        exit 1
    fi

    start="$(now_ms)"
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" pause >/dev/null
    pause_ms="$(elapsed_ms "$start")"

    rm -rf "$SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_DIR"
    start="$(now_ms)"
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" snapshot "file://${SNAPSHOT_DIR}" >/dev/null
    snapshot_ms="$(elapsed_ms "$start")"
    ch_stop_existing_vm

    echo "hypervisor,run,cold_ready_ms,pause_ms,snapshot_create_ms,restore_ready_ms,restore_mode,metadata_ok" > "$RESULTS_CSV"
    json_values=""
    restore_mode="ondemand"

    for run in $(seq 1 "$RESTORE_RUNS"); do
        write_signal "WAIT"
        start="$(now_ms)"
        if ! start_restore_vm "ondemand"; then
            restore_mode="copy"
            start_restore_vm "copy"
        fi
        write_signal "GO"
        if ! restore_ms="$(wait_for_marker SNAP_BENCH_GO 30 "$start")"; then
            if [ "$restore_mode" = "ondemand" ]; then
                echo "Ondemand restore did not reach the marker; retrying copy mode..."
                ch_stop_existing_vm
                restore_mode="copy"
                write_signal "WAIT"
                start="$(now_ms)"
                start_restore_vm "copy"
                write_signal "GO"
                restore_ms="$(wait_for_marker SNAP_BENCH_GO 30 "$start")"
            else
                exit 1
            fi
        fi
        if ! grep -q 'SNAP_BENCH_GO metadata=ok' "$CONSOLE_LOG"; then
            echo "Metadata check failed after restore" >&2
            exit 1
        fi
        ch_stop_existing_vm
        echo "cloud-hypervisor,$run,$cold_ms,$pause_ms,$snapshot_ms,$restore_ms,$restore_mode,ok" >> "$RESULTS_CSV"
        json_values="${json_values}${json_values:+,}$restore_ms"
    done

    cat > "$RESULTS_JSON" <<EOF
{"hypervisor":"cloud-hypervisor","cold_ready_ms":$cold_ms,"pause_ms":$pause_ms,"snapshot_create_ms":$snapshot_ms,"restore_ready_ms":[$json_values],"restore_mode":"$restore_mode","metadata_ok":true}
EOF

    echo ""
    echo "Cloud Hypervisor results:"
    column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"
}

main "$@"
