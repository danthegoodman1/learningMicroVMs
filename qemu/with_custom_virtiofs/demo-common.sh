#!/usr/bin/env bash

CUSTOM_QEMU_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$CUSTOM_QEMU_DIR/../common.sh"

: "${FS_TAG:=hostshare}"
: "${FS_ID:=customfs0}"
: "${CHARDEV_ID:=customfs-char0}"
: "${SHARE_DIR:=$CUSTOM_QEMU_DIR/shared}"
: "${CUSTOM_VIRTIOFSD_SOCK:=/tmp/qemu-custom-virtiofs.sock}"
: "${CUSTOM_VIRTIOFSD_LOG:=$CUSTOM_QEMU_DIR/custom-virtiofsd.log}"
: "${CUSTOM_VIRTIOFSD_PIDFILE:=$CUSTOM_QEMU_DIR/custom-virtiofsd.pid}"
: "${QMP_SOCKET:=/tmp/qemu-custom-virtiofs.qmp}"
: "${PIDFILE:=$CUSTOM_QEMU_DIR/qemu.pid}"
: "${LOGFILE:=$CUSTOM_QEMU_DIR/qemu.log}"
: "${CONSOLE_LOG:=$CUSTOM_QEMU_DIR/qemu-console.log}"
: "${WORK_DIR:=$CUSTOM_QEMU_DIR/work}"
: "${TAP_DEV:=tap-qcustom}"
: "${TAP_IP:=172.16.36.1}"
: "${TAP_CIDR:=172.16.36.0/30}"
: "${GUEST_IP:=172.16.36.2}"
: "${MAC:=06:00:AC:10:24:02}"
: "${QEMU_NETWORK_STATE:=$WORK_DIR/network.state}"
: "${QEMU_MACHINE:=q35}"
: "${MEMORY_MIB:=1024}"

if [ -z "${KERNEL:-}" ]; then
    KERNEL="$REPO_ROOT/cloud-hypervisor/vmlinux-x86_64"
fi

DAEMON_MANIFEST="$REPO_ROOT/cloud-hypervisor/with_custom_virtiofs/custom-virtiofsd/Cargo.toml"
DAEMON_BIN="$REPO_ROOT/cloud-hypervisor/with_custom_virtiofs/custom-virtiofsd/target/release/custom-virtiofsd"

custom_qemu_build_daemon() {
    local cargo_bin
    cargo_bin="${CARGO_BIN:-$(command -v cargo || true)}"
    if [ -z "$cargo_bin" ]; then
        echo "Error: cargo is required to build the custom daemon." >&2
        return 1
    fi
    "$cargo_bin" build --release --manifest-path "$DAEMON_MANIFEST"
}

custom_qemu_stop_daemon() {
    local pid=""
    [ ! -s "$CUSTOM_VIRTIOFSD_PIDFILE" ] || pid="$(cat "$CUSTOM_VIRTIOFSD_PIDFILE")"
    if [ -n "$pid" ]; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$CUSTOM_VIRTIOFSD_PIDFILE" "$CUSTOM_VIRTIOFSD_SOCK"
}

custom_qemu_start_daemon() {
    local mode="${1:-reset}"
    custom_qemu_stop_daemon
    mkdir -p "$SHARE_DIR"
    if [ "$mode" = reset ]; then
        rm -f "$SHARE_DIR/from-guest.txt" \
            "$SHARE_DIR/before-snapshot.txt" \
            "$SHARE_DIR/after-restore.txt"
        printf 'hello from the host via custom QEMU virtio-fs\n' > "$SHARE_DIR/from-host.txt"
        : > "$CUSTOM_VIRTIOFSD_LOG"
    else
        printf '\n--- custom daemon restart: %s ---\n' "$(date -Is)" >> "$CUSTOM_VIRTIOFSD_LOG"
    fi

    RUST_LOG="${RUST_LOG:-info}" "$DAEMON_BIN" \
        --socket-path "$CUSTOM_VIRTIOFSD_SOCK" \
        --shared-dir "$SHARE_DIR" \
        --thread-pool-size 0 \
        >>"$CUSTOM_VIRTIOFSD_LOG" 2>&1 &
    printf '%s\n' "$!" > "$CUSTOM_VIRTIOFSD_PIDFILE"

    for _ in $(seq 1 100); do
        [ -S "$CUSTOM_VIRTIOFSD_SOCK" ] && return
        sleep 0.05
    done
    echo "Error: custom daemon did not create $CUSTOM_VIRTIOFSD_SOCK" >&2
    cat "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
    return 1
}

custom_qemu_start_vm() {
    local mode="${1:-source}" args=()
    args=(
        -object "memory-backend-memfd,id=mem,size=${MEMORY_MIB}M,share=on"
        -numa "node,memdev=mem"
        -device "pcie-root-port,id=customfs-port,chassis=1,slot=1"
    )
    [ "$mode" != restore ] || args+=(-incoming defer)
    qemu_start_vm "$(qemu_kernel_boot_args rw)" off "${args[@]}"
}

custom_qemu_add_fs() {
    local chardev_args device_args
    chardev_args="$(jq -nc --arg id "$CHARDEV_ID" --arg path "$CUSTOM_VIRTIOFSD_SOCK" '
        {id:$id, backend:{type:"socket",data:{addr:{type:"unix",data:{path:$path}},server:false}}}')"
    qemu_qmp chardev-add "$chardev_args" >/dev/null
    device_args="$(jq -nc --arg id "$FS_ID" --arg chardev "$CHARDEV_ID" --arg tag "$FS_TAG" '
        {driver:"vhost-user-fs-pci",id:$id,chardev:$chardev,tag:$tag,bus:"customfs-port",
         "num-request-queues":1,"queue-size":512}')"
    qemu_qmp device_add "$device_args" >/dev/null
}

custom_qemu_remove_fs() {
    if [ -S "$QMP_SOCKET" ]; then
        qemu_qmp device_del "$(jq -nc --arg id "$FS_ID" '{id:$id}')" >/dev/null 2>&1 || true
        sleep 0.5
        qemu_qmp chardev-remove "$(jq -nc --arg id "$CHARDEV_ID" '{id:$id}')" >/dev/null 2>&1 || true
    fi
}

custom_qemu_wait_for_guest() {
    local key
    key="$(qemu_find_ssh_key)"
    qemu_wait_for_ssh "$GUEST_IP" "$key"
}

custom_qemu_verify_spawn_io() {
    local key
    key="$(qemu_find_ssh_key)"
    custom_qemu_wait_for_guest
    qemu_ssh "$GUEST_IP" "$key" "
        set -e
        echo 1 > /sys/bus/pci/rescan
        udevadm settle 2>/dev/null || sleep 0.5
        mkdir -p /mnt/$FS_TAG
        modprobe virtiofs 2>/dev/null || true
        mount -t virtiofs $FS_TAG /mnt/$FS_TAG
        grep -q 'hello from the host via custom QEMU' /mnt/$FS_TAG/from-host.txt
        printf 'hello from the guest via custom QEMU virtio-fs\n' > /mnt/$FS_TAG/from-guest.txt
        sync /mnt/$FS_TAG/from-guest.txt
        umount /mnt/$FS_TAG
    "
    grep -q 'hello from the guest via custom QEMU' "$SHARE_DIR/from-guest.txt"
}

custom_qemu_assert_log_ops() {
    local op
    for op in "$@"; do
        if ! grep -q "customfs $op" "$CUSTOM_VIRTIOFSD_LOG"; then
            echo "Error: custom daemon log is missing operation: $op" >&2
            return 1
        fi
    done
}

custom_qemu_cleanup() {
    custom_qemu_remove_fs
    qemu_cleanup >/dev/null 2>&1 || true
    custom_qemu_stop_daemon
}
