#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${FS_TAG:=hostshare}"
: "${FS_ID:=customfs0}"
: "${SHARE_DIR:=$SCRIPT_DIR/shared}"
: "${CUSTOM_VIRTIOFSD_SOCK:=/tmp/cloud-hypervisor-custom-virtiofs.sock}"
: "${CUSTOM_VIRTIOFSD_LOG:=$SCRIPT_DIR/custom-virtiofsd.log}"
: "${CUSTOM_VIRTIOFSD_PIDFILE:=$SCRIPT_DIR/custom-virtiofsd.pid}"
: "${API_SOCKET:=/tmp/cloud-hypervisor-custom-virtiofs-api.sock}"
: "${LOGFILE:=$SCRIPT_DIR/cloud-hypervisor.log}"
: "${CONSOLE_LOG:=$SCRIPT_DIR/cloud-hypervisor-console.log}"
: "${PIDFILE:=$SCRIPT_DIR/cloud-hypervisor.pid}"
: "${MEMORY:=size=1024M,shared=on}"

CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
DAEMON_MANIFEST="$SCRIPT_DIR/custom-virtiofsd/Cargo.toml"
DAEMON_BIN="$SCRIPT_DIR/custom-virtiofsd/target/release/custom-virtiofsd"
CLEANUP_ARMED=0

cleanup_on_exit() {
    if [ "$CLEANUP_ARMED" = "1" ]; then
        "$SCRIPT_DIR/stop.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_exit EXIT

build_daemon() {
    if [ ! -x "$CARGO_BIN" ]; then
        echo "Error: cargo not found at $CARGO_BIN. Set CARGO_BIN=... or add Rust to PATH." >&2
        exit 1
    fi
    "$CARGO_BIN" build --release --manifest-path "$DAEMON_MANIFEST"
}

start_vm() {
    local boot_args
    boot_args="$(ch_kernel_boot_args rw)"

    ch_setup_tap
    API_SOCKET="$API_SOCKET" \
    LOGFILE="$LOGFILE" \
    CONSOLE_LOG="$CONSOLE_LOG" \
    PIDFILE="$PIDFILE" \
    MEMORY="$MEMORY" \
    ch_start_vm "$boot_args" off
}

start_custom_virtiofsd() {
    "$SCRIPT_DIR/stop.sh" daemon-only >/dev/null 2>&1 || true

    mkdir -p "$SHARE_DIR"
    printf 'hello from the host via custom virtio-fs\n' > "$SHARE_DIR/from-host.txt"
    : > "$CUSTOM_VIRTIOFSD_LOG"

    RUST_LOG="${RUST_LOG:-info}" "$DAEMON_BIN" \
        --socket-path "$CUSTOM_VIRTIOFSD_SOCK" \
        --shared-dir "$SHARE_DIR" \
        --tag "$FS_TAG" \
        --thread-pool-size 0 \
        >"$CUSTOM_VIRTIOFSD_LOG" 2>&1 &
    printf '%s\n' "$!" > "$CUSTOM_VIRTIOFSD_PIDFILE"

    for _ in $(seq 1 100); do
        if [ -S "$CUSTOM_VIRTIOFSD_SOCK" ]; then
            return 0
        fi
        sleep 0.05
    done

    echo "Error: custom virtiofsd did not create $CUSTOM_VIRTIOFSD_SOCK" >&2
    cat "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
    return 1
}

add_fs() {
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" add-fs \
        "tag=${FS_TAG},socket=${CUSTOM_VIRTIOFSD_SOCK},num_queues=1,queue_size=512,id=${FS_ID}" \
        >/dev/null
}

remove_fs() {
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" remove-device "$FS_ID" >/dev/null 2>&1 || true
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
        grep -q 'hello from the host via custom virtio-fs' /mnt/$FS_TAG/from-host.txt
        printf 'hello from the guest via custom virtio-fs\n' > /mnt/$FS_TAG/from-guest.txt
        sync /mnt/$FS_TAG/from-guest.txt
        cat /mnt/$FS_TAG/from-host.txt
        cat /mnt/$FS_TAG/from-guest.txt
        umount /mnt/$FS_TAG
    "

    if ! grep -q 'hello from the guest via custom virtio-fs' "$SHARE_DIR/from-guest.txt"; then
        echo "Error: guest write did not appear on host" >&2
        return 1
    fi

    for op in lookup read write; do
        if ! grep -q "customfs $op" "$CUSTOM_VIRTIOFSD_LOG"; then
            echo "Error: custom daemon log is missing operation: $op" >&2
            cat "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
            return 1
        fi
    done
}

main() {
    build_daemon
    "$SCRIPT_DIR/stop.sh" >/dev/null 2>&1 || true
    CLEANUP_ARMED=1

    start_vm
    sleep 5
    ch_configure_guest_network "$GUEST_IP" "$TAP_IP"

    start_custom_virtiofsd
    add_fs
    verify_mount
    remove_fs

    "$SCRIPT_DIR/stop.sh" >/dev/null
    CLEANUP_ARMED=0

    echo ""
    echo "=============================================="
    echo "Custom Rust virtio-fs proxy demo passed"
    echo "=============================================="
    echo ""
    echo "Host share:"
    echo "  $SHARE_DIR"
    echo ""
    echo "Daemon log:"
    echo "  $CUSTOM_VIRTIOFSD_LOG"
    echo ""
    echo "VM, TAP, custom daemon, and fs device were stopped after verification."
}

main "$@"
