#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/demo-common.sh"

CLEANUP_ARMED=0
cleanup_on_exit() {
    local status=$?
    [ "$CLEANUP_ARMED" != 1 ] || custom_qemu_cleanup
    return "$status"
}
trap cleanup_on_exit EXIT

custom_qemu_build_daemon
custom_qemu_cleanup
CLEANUP_ARMED=1

qemu_setup_tap
custom_qemu_start_vm
qemu_configure_guest_network "$GUEST_IP" "$TAP_IP"
custom_qemu_start_daemon reset
custom_qemu_add_fs
custom_qemu_verify_spawn_io
custom_qemu_assert_log_ops lookup read write
custom_qemu_remove_fs

custom_qemu_cleanup
CLEANUP_ARMED=0

echo "Custom Rust virtio-fs QEMU hotplug demo passed."
echo "The device was added and removed through QMP; VM and daemon are stopped."
