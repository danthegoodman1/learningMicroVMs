#!/usr/bin/env bash

set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$DEMO_DIR/.." && pwd)"
source "$DEMO_DIR/demo-common.sh"
source "$REPO_ROOT/firecracker/common.sh"

TAP_DEV="${TAP_DEV:-tap-hotplug-fc}"
TAP_IP="${TAP_IP:-172.16.20.1}"
TAP_CIDR="${TAP_CIDR:-172.16.20.0/30}"
GUEST_IP="${GUEST_IP:-172.16.20.2}"
API_SOCKET="${API_SOCKET:-/tmp/firecracker-memory-hotplug.sock}"
VMM_LOG="${VMM_LOG:-/tmp/firecracker-memory-hotplug.log}"
CONSOLE_LOG="${CONSOLE_LOG:-/tmp/firecracker-memory-hotplug-console.log}"
FC_PID=""
GUEST_READY=0
SSH_KEY="$(fc_find_ssh_key)"

guest_exec() {
    demo_ssh "$GUEST_IP" "$SSH_KEY" "$@"
}

api_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local args=(
        --fail-with-body -sS
        -X "$method"
        --unix-socket "$API_SOCKET"
    )

    if [ -n "$body" ]; then
        args+=(--data "$body")
    fi
    sudo curl "${args[@]}" "http://localhost/${path}"
}

resize_to_peak() {
    local hotplug_mib=$((PEAK_MEMORY_MIB - BASE_MEMORY_MIB))
    api_request PATCH hotplug/memory \
        "{\"requested_size_mib\": ${hotplug_mib}}" >/dev/null
}

find_hotplug_kernel() {
    if [ -n "${KERNEL:-}" ]; then
        printf '%s\n' "$KERNEL"
        return
    fi

    local kernel
    kernel="$(find "$REPO_ROOT/firecracker" -maxdepth 1 -type f \
        -name 'vmlinux-6.1.*' ! -name '*.config' | sort -V | tail -n 1)"
    if [ -z "$kernel" ]; then
        echo "Error: no Firecracker vmlinux-6.1.* kernel found." >&2
        echo "Run $DEMO_DIR/setup.sh first, or set KERNEL=/path/to/vmlinux." >&2
        return 1
    fi
    printf '%s\n' "$kernel"
}

wait_for_api_socket() {
    local deadline=$((SECONDS + 10))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if sudo test -S "$API_SOCKET"; then
            return 0
        fi
        sleep 0.05
    done
    echo "Error: timed out waiting for $API_SOCKET" >&2
    return 1
}

check_guest_physical_address_width() {
    [ "$(uname -m)" = "x86_64" ] || return 0

    local physical_bits
    physical_bits="$(LC_ALL=C lscpu | sed -n \
        's/^[[:space:]]*Address sizes:[[:space:]]*\([0-9][0-9]*\) bits physical.*/\1/p')"

    if [ -n "$physical_bits" ] && [ "$physical_bits" -lt 40 ]; then
        cat >&2 <<EOF
Error: Firecracker virtio-mem needs at least 40 guest physical-address bits on x86_64.
This KVM host exposes ${physical_bits} bits, but Firecracker's hotplug region begins at
GPA 0x8000000000 (512 GiB). Run this demo on a host or nested VM exposing at
least 40 bits. The Cloud Hypervisor demo can run on this host.
EOF
        return 1
    fi
}

cleanup() {
    if [ "$GUEST_READY" -eq 1 ]; then
        demo_stop_workload
    fi
    if [ -n "$FC_PID" ]; then
        sudo kill "$FC_PID" 2>/dev/null || true
        wait "$FC_PID" 2>/dev/null || true
    fi
    sudo rm -f "$API_SOCKET"
    demo_cleanup_tap "$TAP_DEV" "$TAP_CIDR"
}
trap cleanup EXIT

demo_validate_settings
demo_require_command curl
demo_require_command ip
demo_require_command iptables
demo_require_command lscpu
demo_require_command ssh
check_guest_physical_address_width

FIRECRACKER_BIN="$(fc_find_firecracker)"
KERNEL="$(find_hotplug_kernel)"
ROOTFS="$(fc_find_rootfs)"
HOTPLUG_MIB=$((PEAK_MEMORY_MIB - BASE_MEMORY_MIB))

echo "Firecracker memory hotplug demo"
echo "  baseline=${BASE_MEMORY_MIB} MiB peak=${PEAK_MEMORY_MIB} MiB trigger=${TRIGGER_USED_MIB} MiB used"
echo "  kernel=$KERNEL"

demo_setup_tap "$TAP_DEV" "$TAP_IP" "$TAP_CIDR"
sudo rm -f "$API_SOCKET"
fc_prepare_logfile "$VMM_LOG"
: > "$CONSOLE_LOG"
sudo "$FIRECRACKER_BIN" --api-sock "$API_SOCKET" --enable-pci >"$CONSOLE_LOG" 2>&1 &
FC_PID="$!"
wait_for_api_socket

api_request PUT logger "{
    \"log_path\": \"${VMM_LOG}\",
    \"level\": \"Info\",
    \"show_level\": true
}" >/dev/null
api_request PUT machine-config "{
    \"vcpu_count\": 2,
    \"mem_size_mib\": ${BASE_MEMORY_MIB}
}" >/dev/null
api_request PUT hotplug/memory "{
    \"total_size_mib\": ${HOTPLUG_MIB},
    \"block_size_mib\": 2,
    \"slot_size_mib\": 128
}" >/dev/null
api_request PUT boot-source "{
    \"kernel_image_path\": \"${KERNEL}\",
    \"boot_args\": \"console=ttyS0 reboot=k panic=1 memhp_default_state=online_movable ip=${GUEST_IP}::${TAP_IP}:255.255.255.252::eth0:off\"
}" >/dev/null
api_request PUT drives/rootfs "{
    \"drive_id\": \"rootfs\",
    \"path_on_host\": \"${ROOTFS}\",
    \"is_root_device\": true,
    \"is_read_only\": false
}" >/dev/null
api_request PUT network-interfaces/eth0 "{
    \"iface_id\": \"eth0\",
    \"guest_mac\": \"06:00:AC:10:14:02\",
    \"host_dev_name\": \"${TAP_DEV}\"
}" >/dev/null
api_request PUT actions '{"action_type": "InstanceStart"}' >/dev/null

demo_wait_for_ssh "$GUEST_IP" "$SSH_KEY"
GUEST_READY=1
demo_configure_guest_network "$TAP_IP"
guest_exec 'for device in /sys/bus/virtio/drivers/virtio_mem/virtio*; do [ -L "$device" ] && exit 0; done; exit 1' || {
    echo "Error: guest did not load the virtio-mem driver" >&2
    exit 1
}
demo_run_policy

echo "Firecracker hotplug status:"
api_request GET hotplug/memory
