#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${FS_TAG:=hostshare}"
: "${SHARE_DIR:=$SCRIPT_DIR/shared}"
: "${VIRTIOFSD_SOCK:=/tmp/cloud-hypervisor-virtiofs.sock}"
: "${VIRTIOFSD_LOG:=$SCRIPT_DIR/virtiofsd.log}"
: "${VIRTIOFSD_PIDFILE:=$SCRIPT_DIR/virtiofsd.pid}"
: "${API_SOCKET:=/tmp/cloud-hypervisor-virtiofs-api.sock}"
: "${LOGFILE:=$SCRIPT_DIR/cloud-hypervisor.log}"
: "${CONSOLE_LOG:=$SCRIPT_DIR/cloud-hypervisor-console.log}"
: "${PIDFILE:=$SCRIPT_DIR/cloud-hypervisor.pid}"
: "${MEMORY:=size=1024M,shared=on}"

CLEANUP_ARMED=0

cleanup_on_exit() {
    if [ "$CLEANUP_ARMED" = "1" ]; then
        "$SCRIPT_DIR/stop.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_exit EXIT

find_virtiofsd() {
    if [ -n "${VIRTIOFSD_BIN:-}" ]; then
        printf '%s\n' "$VIRTIOFSD_BIN"
        return
    fi
    if command -v virtiofsd >/dev/null 2>&1; then
        command -v virtiofsd
        return
    fi
    if [ -x /usr/libexec/virtiofsd ]; then
        printf '%s\n' /usr/libexec/virtiofsd
        return
    fi
    if [ -x /usr/lib/qemu/virtiofsd ]; then
        printf '%s\n' /usr/lib/qemu/virtiofsd
        return
    fi

    echo "Error: virtiofsd not found. Install the virtiofsd package or set VIRTIOFSD_BIN=..." >&2
    return 1
}

stop_virtiofsd() {
    local pid
    if [ -f "$VIRTIOFSD_PIDFILE" ]; then
        pid="$(cat "$VIRTIOFSD_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            pkill -TERM -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    fi
    pkill -TERM -f "$VIRTIOFSD_SOCK" 2>/dev/null || true
    rm -f "$VIRTIOFSD_PIDFILE" "$VIRTIOFSD_SOCK"
}

start_virtiofsd() {
    local bin
    bin="$(find_virtiofsd)"

    stop_virtiofsd
    mkdir -p "$SHARE_DIR"
    printf 'hello from the host via virtio-fs\n' > "$SHARE_DIR/from-host.txt"
    : > "$VIRTIOFSD_LOG"

    nohup bash -c '
        bin="$1"
        sock="$2"
        share="$3"
        log="$4"
        trap "exit 0" INT TERM
        while true; do
            rm -f "$sock"
            "$bin" \
                --socket-path "$sock" \
                --shared-dir "$share" \
                --cache never \
                --sandbox none \
                --log-level warn \
                >>"$log" 2>&1
            printf "virtiofsd exited; restarting\n" >>"$log"
            sleep 0.2
        done
    ' virtiofsd-supervisor "$bin" "$VIRTIOFSD_SOCK" "$SHARE_DIR" "$VIRTIOFSD_LOG" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$VIRTIOFSD_PIDFILE"

    for _ in $(seq 1 100); do
        if [ -S "$VIRTIOFSD_SOCK" ]; then
            return 0
        fi
        sleep 0.05
    done

    echo "Error: virtiofsd did not create $VIRTIOFSD_SOCK" >&2
    cat "$VIRTIOFSD_LOG" >&2 || true
    return 1
}

start_vm() {
    local bin kernel rootfs boot_args
    bin="$(ch_find_binary)"
    kernel="$(ch_find_kernel)"
    rootfs="$(ch_find_rootfs)"
    boot_args="$(ch_kernel_boot_args rw)"

    ch_stop_existing_vm
    sudo rm -f "$API_SOCKET"
    : > "$LOGFILE"
    : > "$CONSOLE_LOG"

    sudo "$bin" \
        --kernel "$kernel" \
        --cmdline "$boot_args" \
        --disk "path=${rootfs},readonly=off" \
        --cpus "$CPUS" \
        --memory "$MEMORY" \
        --net "tap=${TAP_DEV},mac=${MAC}" \
        --fs "tag=${FS_TAG},socket=${VIRTIOFSD_SOCK},num_queues=1,queue_size=512" \
        --api-socket "path=${API_SOCKET}" \
        --serial "file=${CONSOLE_LOG}" \
        --console off \
        --log-file "$LOGFILE" &

    local sudo_pid real_pid
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "${PIDFILE}.sudo"

    sleep 0.25
    real_pid="$(pgrep -P "$sudo_pid" -f "$(basename "$bin")" | head -n 1 || true)"
    printf '%s\n' "${real_pid:-$sudo_pid}" > "$PIDFILE"

    sleep 1
    if ! ch_pid_alive "$(cat "$PIDFILE")"; then
        echo "Error: Cloud Hypervisor exited early." >&2
        tail -n 80 "$LOGFILE" >&2 || true
        tail -n 80 "$CONSOLE_LOG" >&2 || true
        return 1
    fi
}

verify_mount() {
    local key
    key="$(ch_find_ssh_key)"

    echo "Waiting for SSH on $GUEST_IP..."
    ch_wait_for_ssh "$GUEST_IP" "$key"

    ch_ssh "$GUEST_IP" "$key" "
        set -e
        mkdir -p /mnt/$FS_TAG
        modprobe virtiofs 2>/dev/null || true
        mountpoint -q /mnt/$FS_TAG || mount -t virtiofs $FS_TAG /mnt/$FS_TAG
        grep -q 'hello from the host' /mnt/$FS_TAG/from-host.txt
        printf 'hello from the guest via virtio-fs\n' > /mnt/$FS_TAG/from-guest.txt
        sync /mnt/$FS_TAG/from-guest.txt
        cat /mnt/$FS_TAG/from-host.txt
        cat /mnt/$FS_TAG/from-guest.txt
    "

    if ! grep -q 'hello from the guest' "$SHARE_DIR/from-guest.txt"; then
        echo "Error: guest write did not appear on host" >&2
        return 1
    fi
}

main() {
    start_virtiofsd
    CLEANUP_ARMED=1
    ch_setup_tap
    start_vm
    sleep 5
    ch_configure_guest_network "$GUEST_IP" "$TAP_IP"
    verify_mount

    "$SCRIPT_DIR/stop.sh" >/dev/null
    CLEANUP_ARMED=0

    echo ""
    echo "========================================"
    echo "Cloud Hypervisor virtio-fs demo passed"
    echo "========================================"
    echo ""
    echo "Host share:"
    echo "  $SHARE_DIR"
    echo ""
    echo "Guest mount:"
    echo "  /mnt/$FS_TAG"
    echo ""
    echo "VM, TAP, and virtiofsd were stopped after verification."
}

main "$@"
