#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/demo-common.sh"

: "${SNAPSHOT_FILE:=$WORK_DIR/qemu.snapshot}"

CLEANUP_ARMED=0
cleanup_on_exit() {
    local status=$?
    [ "$CLEANUP_ARMED" != 1 ] || custom_qemu_cleanup
    return "$status"
}
trap cleanup_on_exit EXIT

validate_snapshot_file() {
    WORK_DIR="$(realpath -m -- "$WORK_DIR")"
    SNAPSHOT_FILE="$(realpath -m -- "$SNAPSHOT_FILE")"
    case "$SNAPSHOT_FILE" in
        "$WORK_DIR"/*) ;;
        *)
            echo "Error: SNAPSHOT_FILE must be a child of WORK_DIR." >&2
            return 1
            ;;
    esac
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

mount_and_write_before_snapshot() {
    local key
    key="$(qemu_find_ssh_key)"
    custom_qemu_wait_for_guest
    qemu_ssh "$GUEST_IP" "$key" "
        set -e
        echo 1 > /sys/bus/pci/rescan
        udevadm settle 2>/dev/null || sleep 0.5
        mkdir -p /mnt/$FS_TAG
        mount -t virtiofs $FS_TAG /mnt/$FS_TAG
        grep -q 'hello from the host via custom QEMU' /mnt/$FS_TAG/from-host.txt
        printf 'before snapshot via custom QEMU virtio-fs\n' > /mnt/$FS_TAG/before-snapshot.txt
        sync /mnt/$FS_TAG/before-snapshot.txt
    "
    grep -q 'before snapshot via custom QEMU' "$SHARE_DIR/before-snapshot.txt"
}

verify_after_restore() {
    local key
    key="$(qemu_find_ssh_key)"
    custom_qemu_wait_for_guest
    qemu_ssh "$GUEST_IP" "$key" "
        set -e
        mountpoint -q /mnt/$FS_TAG
        grep -q 'hello from the host via custom QEMU' /mnt/$FS_TAG/from-host.txt
        grep -q 'before snapshot via custom QEMU' /mnt/$FS_TAG/before-snapshot.txt
        printf 'after restore via custom QEMU virtio-fs\n' > /mnt/$FS_TAG/after-restore.txt
        sync /mnt/$FS_TAG/after-restore.txt
    "
    grep -q 'after restore via custom QEMU' "$SHARE_DIR/after-restore.txt"
}

main() {
    validate_snapshot_file
    custom_qemu_build_daemon
    custom_qemu_cleanup
    mkdir -p "$WORK_DIR"
    rm -f "$SNAPSHOT_FILE"
    CLEANUP_ARMED=1

    echo "Custom Rust virtio-fs QEMU snapshot/restore demo"
    echo "  share: $SHARE_DIR"
    echo "  snapshot: $SNAPSHOT_FILE"

    qemu_setup_tap
    custom_qemu_start_vm source
    qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"
    custom_qemu_start_daemon reset
    custom_qemu_add_fs
    mount_and_write_before_snapshot

    echo "Pausing QEMU and writing mapped-RAM snapshot..."
    qemu_qmp stop >/dev/null
    enable_mapped_ram
    qemu_qmp migrate "{\"uri\":\"file:${SNAPSHOT_FILE}\"}" >/dev/null
    wait_for_migration
    qemu_stop_existing_vm
    custom_qemu_stop_daemon

    echo "Restoring into fresh QEMU and daemon processes..."
    custom_qemu_start_vm restore
    custom_qemu_start_daemon keep
    custom_qemu_add_fs
    enable_mapped_ram
    qemu_qmp migrate-incoming "{\"uri\":\"file:${SNAPSHOT_FILE}\"}" >/dev/null
    wait_for_migration
    qemu_qmp cont >/dev/null
    verify_after_restore

    grep -q 'customfs serialize complete' "$CUSTOM_VIRTIOFSD_LOG"
    grep -q 'customfs deserialize_and_apply complete' "$CUSTOM_VIRTIOFSD_LOG"

    custom_qemu_cleanup
    CLEANUP_ARMED=0
    echo
    echo "Custom QEMU virtio-fs snapshot/restore demo passed."
    echo "The guest mount survived restore and wrote after-restore.txt without remounting."
}

main "$@"
