#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
API_SOCKET="${API_SOCKET:-/tmp/firecracker-snapshot.socket}"
TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
GUEST_IP="${GUEST_IP:-172.16.0.2}"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
BENCH_MEM_MIB="${BENCH_MEM_MIB:-256}"
BENCH_VCPUS="${BENCH_VCPUS:-1}"
RESTORE_RUNS="${RESTORE_RUNS:-3}"
ROOTFS_SRC="$(fc_find_rootfs)"
KERNEL="$(fc_find_kernel)"
FIRECRACKER_BIN="$(fc_find_firecracker)"
ROOTFS="$WORK_DIR/rootfs.ext4"
SIGNAL_IMG="$WORK_DIR/signal.img"
SNAPSHOT_FILE="$WORK_DIR/vm.snapshot"
MEM_FILE="$WORK_DIR/memory.snapshot"
CONSOLE_LOG="$WORK_DIR/console.log"
VMM_LOG="$WORK_DIR/firecracker.log"
RESULTS_CSV="$WORK_DIR/results.csv"
RESULTS_JSON="$WORK_DIR/results.json"
FC_PID=""
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
    if [ -n "$FC_PID" ]; then
        sudo kill "$FC_PID" 2>/dev/null || true
    fi
    if [ -n "$METADATA_PID" ]; then
        sudo kill "$METADATA_PID" 2>/dev/null || true
    fi
    sudo rm -f "$API_SOCKET"
    sudo ip link del "$TAP_DEV" 2>/dev/null || true

    local host_iface
    host_iface="$(fc_host_iface)"
    while sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null; do :; done
    while sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null; do :; done
}
trap cleanup EXIT

api_request() {
    local method="$1"
    local path="$2"
    local body="$3"

    sudo curl --fail-with-body -sS -X "$method" --unix-socket "$API_SOCKET" \
        --data "$body" \
        "http://localhost/$path" >/dev/null
}

put_api() {
    local path="$1"
    local body="$2"

    api_request PUT "$path" "$body"
}

patch_api() {
    local path="$1"
    local body="$2"

    api_request PATCH "$path" "$body"
}

wait_for_socket() {
    for _ in $(seq 1 100); do
        if sudo test -S "$API_SOCKET"; then
            return 0
        fi
        sleep 0.05
    done
    echo "Timed out waiting for $API_SOCKET" >&2
    return 1
}

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

setup_tap() {
    local host_iface
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    sudo ip tuntap add dev "$TAP_DEV" mode tap
    sudo ip addr add "${TAP_IP}/30" dev "$TAP_DEV"
    sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"
    sudo ip link set dev "$TAP_DEV" up
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

    host_iface="$(fc_host_iface)"
    sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -o "$host_iface" -j MASQUERADE
    sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$host_iface" -j ACCEPT
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

start_firecracker() {
    sudo rm -f "$API_SOCKET"
    : > "$CONSOLE_LOG"
    : > "$VMM_LOG"
    sudo "$FIRECRACKER_BIN" --api-sock "$API_SOCKET" >"$CONSOLE_LOG" 2>&1 &
    FC_PID="$!"
    wait_for_socket
}

configure_source_vm() {
    put_api logger "{
        \"log_path\": \"$VMM_LOG\",
        \"level\": \"Info\",
        \"show_level\": true,
        \"show_log_origin\": false
    }"
    put_api machine-config "{
        \"vcpu_count\": $BENCH_VCPUS,
        \"mem_size_mib\": $BENCH_MEM_MIB,
        \"smt\": false
    }"
    put_api boot-source "{
        \"kernel_image_path\": \"$KERNEL\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off init=/snapshot-init.sh\"
    }"
    put_api drives/rootfs "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS\",
        \"is_root_device\": true,
        \"is_read_only\": true
    }"
    put_api drives/signal "{
        \"drive_id\": \"signal\",
        \"path_on_host\": \"$SIGNAL_IMG\",
        \"is_root_device\": false,
        \"is_read_only\": false
    }"
    put_api network-interfaces/eth0 "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"06:00:AC:10:00:02\",
        \"host_dev_name\": \"$TAP_DEV\"
    }"
}

stop_firecracker() {
    if [ -n "$FC_PID" ]; then
        sudo kill "$FC_PID" 2>/dev/null || true
        FC_PID=""
    fi
    sudo rm -f "$API_SOCKET"
}

main() {
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    prepare_rootfs
    setup_tap
    start_metadata

    echo "Firecracker snapshot demo"
    echo "  rootfs: $ROOTFS_SRC"
    echo "  memory: ${BENCH_MEM_MIB}MiB, vcpus: $BENCH_VCPUS"

    start_firecracker
    configure_source_vm

    local start cold_ms pause_ms snapshot_ms restore_ms run restore_values json_values
    start="$(now_ms)"
    put_api actions '{"action_type":"InstanceStart"}'
    cold_ms="$(wait_for_marker SNAP_BENCH_READY 60 "$start")"
    if ! grep -q 'SNAP_BENCH_READY metadata=ok' "$CONSOLE_LOG"; then
        echo "Metadata check failed during cold boot" >&2
        exit 1
    fi

    start="$(now_ms)"
    patch_api vm '{"state":"Paused"}'
    pause_ms="$(elapsed_ms "$start")"

    rm -f "$SNAPSHOT_FILE" "$MEM_FILE"
    start="$(now_ms)"
    put_api snapshot/create "{
        \"snapshot_type\": \"Full\",
        \"snapshot_path\": \"$SNAPSHOT_FILE\",
        \"mem_file_path\": \"$MEM_FILE\"
    }"
    snapshot_ms="$(elapsed_ms "$start")"
    stop_firecracker

    echo "hypervisor,run,cold_ready_ms,pause_ms,snapshot_create_ms,restore_ready_ms,restore_mode,metadata_ok" > "$RESULTS_CSV"
    restore_values=""
    json_values=""
    for run in $(seq 1 "$RESTORE_RUNS"); do
        write_signal "WAIT"
        start="$(now_ms)"
        start_firecracker
        put_api snapshot/load "{
            \"snapshot_path\": \"$SNAPSHOT_FILE\",
            \"mem_file_path\": \"$MEM_FILE\",
            \"resume_vm\": true
        }"
        write_signal "GO"
        restore_ms="$(wait_for_marker SNAP_BENCH_GO 30 "$start")"
        if ! grep -q 'SNAP_BENCH_GO metadata=ok' "$CONSOLE_LOG"; then
            echo "Metadata check failed after restore" >&2
            exit 1
        fi
        stop_firecracker
        echo "firecracker,$run,$cold_ms,$pause_ms,$snapshot_ms,$restore_ms,full,ok" >> "$RESULTS_CSV"
        restore_values="${restore_values}${restore_values:+ }$restore_ms"
        json_values="${json_values}${json_values:+,}$restore_ms"
    done

    cat > "$RESULTS_JSON" <<EOF
{"hypervisor":"firecracker","cold_ready_ms":$cold_ms,"pause_ms":$pause_ms,"snapshot_create_ms":$snapshot_ms,"restore_ready_ms":[$json_values],"restore_mode":"full","metadata_ok":true}
EOF

    echo ""
    echo "Firecracker results:"
    column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"
}

main "$@"
