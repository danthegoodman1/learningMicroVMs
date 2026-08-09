#!/usr/bin/env bash

set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEMO_DIR/.." && pwd)"
source "$DEMO_DIR/demo-common.sh"
source "$REPO_ROOT/cloud-hypervisor/common.sh"

TAP_DEV="${TAP_DEV:-tap-hotplug-ch}"
TAP_IP="${TAP_IP:-172.16.21.1}"
TAP_CIDR="${TAP_CIDR:-172.16.21.0/30}"
GUEST_IP="${GUEST_IP:-172.16.21.2}"
MAC="${MAC:-06:00:AC:10:15:02}"
API_SOCKET="${API_SOCKET:-/tmp/cloud-hypervisor-memory-hotplug.sock}"
WORK_DIR="${WORK_DIR:-$DEMO_DIR/work}"
LOGFILE="${LOGFILE:-$WORK_DIR/cloud-hypervisor.log}"
CONSOLE_LOG="${CONSOLE_LOG:-$WORK_DIR/console.log}"
PIDFILE="${PIDFILE:-/tmp/cloud-hypervisor-memory-hotplug.pid}"
CPUS="${CPUS:-boot=2}"
MEMORY="size=${BASE_MEMORY_MIB}M,hotplug_size=$((PEAK_MEMORY_MIB - BASE_MEMORY_MIB))M,hotplug_method=virtio-mem"
GUEST_READY=0
SSH_KEY="$(ch_find_ssh_key)"

guest_exec() {
    demo_ssh "$GUEST_IP" "$SSH_KEY" "$@"
}

resize_to_peak() {
    local remote
    remote="$(ch_find_remote)"
    sudo "$remote" --api-socket "$API_SOCKET" resize \
        --memory "${PEAK_MEMORY_MIB}M"
}

cleanup() {
    if [ "$GUEST_READY" -eq 1 ]; then
        demo_stop_workload
    fi
    ch_shutdown_vm
    rm -f "$PIDFILE" "${PIDFILE}.sudo"
    sudo rm -f "$API_SOCKET"
    demo_cleanup_tap "$TAP_DEV" "$TAP_CIDR"
}
trap cleanup EXIT

demo_validate_settings
demo_require_command ip
demo_require_command iptables
demo_require_command ssh
ch_find_binary >/dev/null
ch_find_remote >/dev/null || {
    echo "Error: ch-remote not found. Run $DEMO_DIR/setup.sh first." >&2
    exit 1
}

echo "Cloud Hypervisor memory hotplug demo"
echo "  baseline=${BASE_MEMORY_MIB} MiB peak=${PEAK_MEMORY_MIB} MiB trigger=${TRIGGER_USED_MIB} MiB used"

demo_setup_tap "$TAP_DEV" "$TAP_IP" "$TAP_CIDR"
BOOT_ARGS="$(ch_kernel_boot_args rw) memhp_default_state=online_movable"
mkdir -p "$WORK_DIR"
ch_start_vm "$BOOT_ARGS" off

demo_wait_for_ssh "$GUEST_IP" "$SSH_KEY"
GUEST_READY=1
demo_configure_guest_network "$TAP_IP"
guest_exec 'for device in /sys/bus/virtio/drivers/virtio_mem/virtio*; do [ -L "$device" ] && exit 0; done; exit 1' || {
    echo "Error: guest did not load the virtio-mem driver" >&2
    exit 1
}
demo_run_policy
