#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/demo-common.sh"

: "${SNAPSHOT_DIR:=$WORK_DIR/ch.snapshot}"
: "${RESTORE_SSH_RETRIES:=12}"

CLEANUP_ARMED=0
RESTORE_LOG_START=1

cleanup_on_exit() {
    if [ "$CLEANUP_ARMED" = "1" ]; then
        custom_cleanup_host >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_exit EXIT

validate_snapshot_dir() {
    WORK_DIR="$(realpath -m -- "$WORK_DIR")"
    SNAPSHOT_DIR="$(realpath -m -- "$SNAPSHOT_DIR")"

    case "$SNAPSHOT_DIR" in
        "$WORK_DIR"/*) ;;
        *)
            echo "Error: SNAPSHOT_DIR must be a child of WORK_DIR." >&2
            echo "  WORK_DIR=$WORK_DIR" >&2
            echo "  SNAPSHOT_DIR=$SNAPSHOT_DIR" >&2
            return 1
            ;;
    esac
}

reset_snapshot_dir() {
    sudo rm -rf -- "$SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_DIR"
}

snapshot_source_vm() {
    echo "Pausing VM and writing snapshot..."
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" pause >/dev/null

    reset_snapshot_dir
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" snapshot "file://${SNAPSHOT_DIR}" >/dev/null

    custom_stop_vm
    custom_stop_daemon
}

try_restore_mode() {
    local mode="$1"

    if [ -f "$PIDFILE" ] || [ -f "${PIDFILE}.sudo" ]; then
        custom_stop_vm || true
    fi
    sudo rm -f "$API_SOCKET"
    custom_stop_daemon
    custom_start_daemon keep
    RESTORE_LOG_START="$(custom_log_next_line)"

    echo "Restoring VM with memory_restore_mode=$mode..."
    if ! custom_start_restore_vm "$mode" "$SNAPSHOT_DIR"; then
        return 1
    fi

    SSH_RETRIES="$RESTORE_SSH_RETRIES" custom_verify_restored_mounted_io
}

main() {
    validate_snapshot_dir
    custom_build_daemon
    custom_cleanup_host >/dev/null 2>&1 || true
    reset_snapshot_dir
    mkdir -p "$WORK_DIR"
    CLEANUP_ARMED=1

    echo "Custom Rust virtio-fs snapshot/restore demo"
    echo "  share: $SHARE_DIR"
    echo "  socket: $CUSTOM_VIRTIOFSD_SOCK"
    echo "  snapshot: $SNAPSHOT_DIR"

    custom_start_vm
    custom_configure_guest_network

    custom_start_daemon reset
    custom_add_fs
    custom_mount_and_write_before_snapshot
    custom_assert_log_ops_since 1 lookup read write

    snapshot_source_vm

    local restore_mode
    if try_restore_mode ondemand; then
        restore_mode="ondemand"
    else
        echo "Ondemand restore did not complete; retrying copy mode..."
        custom_stop_vm || true
        if ! try_restore_mode copy; then
            echo "Error: copy-mode restore also failed." >&2
            echo "" >&2
            echo "The custom daemon log should show whether Cloud Hypervisor reached the fs state restore:" >&2
            grep -E 'customfs .*serialize|customfs .*deserialize' "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
            exit 1
        fi
        restore_mode="copy"
    fi

    custom_assert_log_ops_since "$RESTORE_LOG_START" lookup read write
    custom_unmount_guest
    custom_remove_fs

    custom_cleanup_host >/dev/null
    CLEANUP_ARMED=0

    echo ""
    echo "======================================================"
    echo "Custom Rust virtio-fs snapshot/restore demo passed"
    echo "======================================================"
    echo ""
    echo "Restore mode:"
    echo "  $restore_mode"
    echo ""
    echo "Host share:"
    echo "  $SHARE_DIR"
    echo ""
    echo "Snapshot:"
    echo "  $SNAPSHOT_DIR"
    echo ""
    echo "Daemon log:"
    echo "  $CUSTOM_VIRTIOFSD_LOG"
    echo ""
    echo "The guest kept /mnt/$FS_TAG mounted across restore and wrote after-restore.txt."
}

main "$@"
