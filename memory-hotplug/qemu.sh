#!/usr/bin/env bash

set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEMO_DIR/.." && pwd)"
source "$DEMO_DIR/demo-common.sh"
source "$REPO_ROOT/qemu/common.sh"

TAP_DEV="${TAP_DEV:-tap-hotplug-qm}"
TAP_IP="${TAP_IP:-172.16.37.1}"
TAP_CIDR="${TAP_CIDR:-172.16.37.0/30}"
GUEST_IP="${GUEST_IP:-172.16.37.2}"
MAC="${MAC:-06:00:AC:10:25:02}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/qemu-memory-hotplug.qmp}"
WORK_DIR="${WORK_DIR:-$DEMO_DIR/work/qemu}"
PIDFILE="${PIDFILE:-$WORK_DIR/qemu.pid}"
LOGFILE="${LOGFILE:-$WORK_DIR/qemu.log}"
CONSOLE_LOG="${CONSOLE_LOG:-$WORK_DIR/console.log}"
QEMU_NETWORK_STATE="${QEMU_NETWORK_STATE:-$WORK_DIR/network.state}"
QEMU_MACHINE=q35
QEMU_MEMORY_ARG="${BASE_MEMORY_MIB}M,maxmem=${PEAK_MEMORY_MIB}M"
KERNEL="${KERNEL:-$REPO_ROOT/firecracker/vmlinux-6.1.155}"
SSH_KEY="$(qemu_find_ssh_key)"
GUEST_READY=0
HOTPLUG_MIB=$((PEAK_MEMORY_MIB - BASE_MEMORY_MIB))

guest_exec() {
    demo_ssh "$GUEST_IP" "$SSH_KEY" "$@"
}

resize_to_peak() {
    qemu_qmp qom-set "$(jq -nc \
        --arg path /machine/peripheral/vmem0 \
        --arg property requested-size \
        --argjson value "$((HOTPLUG_MIB * 1024 * 1024))" \
        '{path:$path,property:$property,value:$value}')" >/dev/null
}

cleanup() {
    if [ "$GUEST_READY" = 1 ]; then
        demo_stop_workload
    fi
    qemu_cleanup >/dev/null 2>&1 || true
}
trap cleanup EXIT

demo_validate_settings
demo_require_command jq
demo_require_command qemu-system-x86_64
[ -f "$KERNEL" ] || {
    echo "Error: virtio-mem kernel not found: $KERNEL" >&2
    echo "Run $DEMO_DIR/setup.sh first." >&2
    exit 1
}

mkdir -p "$WORK_DIR"
echo "QEMU memory hotplug demo"
echo "  baseline=${BASE_MEMORY_MIB} MiB peak=${PEAK_MEMORY_MIB} MiB trigger=${TRIGGER_USED_MIB} MiB used"
echo "  machine=q35 kernel=$KERNEL"

qemu_setup_tap
qemu_start_vm "$(qemu_kernel_boot_args rw) memhp_default_state=online_movable" off \
    -object "memory-backend-ram,id=hotplugmem,size=${HOTPLUG_MIB}M" \
    -device "virtio-mem-pci,id=vmem0,memdev=hotplugmem,requested-size=0"

demo_wait_for_ssh "$GUEST_IP" "$SSH_KEY"
GUEST_READY=1
demo_configure_guest_network "$TAP_IP"
guest_exec 'for device in /sys/bus/virtio/drivers/virtio_mem/virtio*; do [ -L "$device" ] && exit 0; done; exit 1' || {
    echo "Error: guest did not load the virtio-mem driver" >&2
    exit 1
}

demo_run_policy

echo "QEMU hotplug status:"
qemu_qmp qom-get '{"path":"/machine/peripheral/vmem0","property":"requested-size"}'
qemu_qmp query-memory-size-summary
