#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/demo-common.sh"

CLEANUP_ARMED=0

cleanup_on_exit() {
    if [ "$CLEANUP_ARMED" = "1" ]; then
        custom_cleanup_host >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_exit EXIT

main() {
    custom_build_daemon
    custom_cleanup_host >/dev/null 2>&1 || true
    CLEANUP_ARMED=1

    custom_start_vm
    custom_configure_guest_network

    custom_start_daemon reset
    custom_add_fs
    custom_verify_spawn_io
    custom_assert_log_ops_since 1 lookup read write
    custom_remove_fs

    custom_cleanup_host >/dev/null
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
