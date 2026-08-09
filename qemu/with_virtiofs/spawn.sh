#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${FS_TAG:=hostshare}"
: "${SHARE_DIR:=$SCRIPT_DIR/shared}"
: "${VIRTIOFSD_SOCK:=/tmp/qemu-virtiofs.sock}"
: "${VIRTIOFSD_LOG:=$SCRIPT_DIR/virtiofsd.log}"
: "${VIRTIOFSD_PIDFILE:=$SCRIPT_DIR/virtiofsd.pid}"
: "${QMP_SOCKET:=/tmp/qemu-virtiofs.qmp}"
: "${PIDFILE:=$SCRIPT_DIR/qemu.pid}"
: "${LOGFILE:=$SCRIPT_DIR/qemu.log}"
: "${CONSOLE_LOG:=$SCRIPT_DIR/qemu-console.log}"
: "${QEMU_NETWORK_STATE:=$SCRIPT_DIR/network.state}"

if [ -z "${KERNEL:-}" ]; then
    KERNEL="$REPO_ROOT/cloud-hypervisor/vmlinux-x86_64"
fi

CLEANUP_ARMED=0

find_virtiofsd() {
    if [ -n "${VIRTIOFSD_BIN:-}" ]; then
        printf '%s\n' "$VIRTIOFSD_BIN"
    elif command -v virtiofsd >/dev/null 2>&1; then
        command -v virtiofsd
    elif [ -x /usr/libexec/virtiofsd ]; then
        printf '%s\n' /usr/libexec/virtiofsd
    elif [ -x /usr/lib/qemu/virtiofsd ]; then
        printf '%s\n' /usr/lib/qemu/virtiofsd
    else
        echo "Error: virtiofsd not found." >&2
        return 1
    fi
}

stop_virtiofsd() {
    local pid=""
    [ ! -s "$VIRTIOFSD_PIDFILE" ] || pid="$(cat "$VIRTIOFSD_PIDFILE")"
    if [ -n "$pid" ]; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$VIRTIOFSD_PIDFILE" "$VIRTIOFSD_SOCK"
}

cleanup() {
    local status=$?
    if [ "$CLEANUP_ARMED" = 1 ]; then
        qemu_cleanup >/dev/null 2>&1 || true
        stop_virtiofsd
    fi
    return "$status"
}
trap cleanup EXIT

start_virtiofsd() {
    local bin
    bin="$(find_virtiofsd)"
    stop_virtiofsd
    mkdir -p "$SHARE_DIR"
    rm -f "$SHARE_DIR/from-guest.txt"
    printf 'hello from the host via QEMU virtio-fs\n' > "$SHARE_DIR/from-host.txt"
    : > "$VIRTIOFSD_LOG"

    "$bin" \
        --socket-path "$VIRTIOFSD_SOCK" \
        --shared-dir "$SHARE_DIR" \
        --cache never \
        --sandbox none \
        --log-level warn \
        >>"$VIRTIOFSD_LOG" 2>&1 &
    printf '%s\n' "$!" > "$VIRTIOFSD_PIDFILE"

    for _ in $(seq 1 100); do
        [ -S "$VIRTIOFSD_SOCK" ] && return
        sleep 0.05
    done
    echo "Error: virtiofsd did not create $VIRTIOFSD_SOCK" >&2
    cat "$VIRTIOFSD_LOG" >&2 || true
    return 1
}

main() {
    start_virtiofsd
    CLEANUP_ARMED=1
    qemu_setup_tap
    qemu_start_vm "$(qemu_kernel_boot_args rw)" off \
        -object "memory-backend-memfd,id=mem,size=${MEMORY_MIB}M,share=on" \
        -numa node,memdev=mem \
        -chardev "socket,id=charfs,path=${VIRTIOFSD_SOCK}" \
        -device "vhost-user-fs-device,chardev=charfs,tag=${FS_TAG},queue-size=512"
    qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"

    local key
    key="$(qemu_find_ssh_key)"
    qemu_ssh "$GUEST_IP" "$key" "
        set -e
        mkdir -p /mnt/$FS_TAG
        modprobe virtiofs 2>/dev/null || true
        mount -t virtiofs $FS_TAG /mnt/$FS_TAG
        grep -q 'hello from the host' /mnt/$FS_TAG/from-host.txt
        printf 'hello from the guest via QEMU virtio-fs\n' > /mnt/$FS_TAG/from-guest.txt
        sync /mnt/$FS_TAG/from-guest.txt
        umount /mnt/$FS_TAG
    "
    grep -q 'hello from the guest' "$SHARE_DIR/from-guest.txt"

    qemu_cleanup
    stop_virtiofsd
    CLEANUP_ARMED=0
    echo "QEMU virtio-fs demo passed; VM and daemon stopped."
}

main "$@"
