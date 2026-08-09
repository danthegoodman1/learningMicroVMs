#!/usr/bin/env bash

# Launch a QEMU-platform Unikraft image directly, without the Kraft runtime.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/qemu/common.sh"

UNIKERNEL="${1:-$SCRIPT_DIR/app/.unikraft/build/app_qemu-x86_64}"
VM_ID="${VM_ID:-uk-001}"
TAP_DEV="${TAP_DEV:-tap-qunikraft}"
TAP_IP="${TAP_IP:-172.16.38.1}"
TAP_CIDR="${TAP_CIDR:-172.16.38.0/30}"
GUEST_IP="${GUEST_IP:-172.16.38.2}"
MAC="${MAC:-06:00:AC:10:26:02}"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
QEMU_NETWORK_STATE="${QEMU_NETWORK_STATE:-/tmp/qemu-unikraft.network}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/qemu-unikraft.qmp}"
PIDFILE="${PIDFILE:-/tmp/qemu-unikraft.pid}"

if [ ! -f "$UNIKERNEL" ]; then
    echo "Error: QEMU-platform Unikraft image not found: $UNIKERNEL" >&2
    echo "Build one with: cd $SCRIPT_DIR/app && kraft build --plat qemu --arch x86_64" >&2
    exit 1
fi

cleanup() {
    qemu_cleanup >/dev/null 2>&1 || true
}
trap cleanup EXIT

qemu_setup_tap metadata
rm -f "$QMP_SOCKET" "$PIDFILE"

echo "Launching Unikraft '$VM_ID' directly with QEMU"
echo "  image: $UNIKERNEL"
echo "  address: $GUEST_IP"
echo "  metadata: http://$METADATA_IP/"

"$(qemu_find_binary)" \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 1 \
    -m 128M \
    -nodefaults \
    -no-user-config \
    -nographic \
    -kernel "$UNIKERNEL" \
    -append "netdev.ip=${GUEST_IP}/30:${TAP_IP}" \
    -netdev "tap,id=net0,ifname=${TAP_DEV},script=no,downscript=no" \
    -device "virtio-net-pci,netdev=net0,mac=${MAC}" \
    -qmp "unix:${QMP_SOCKET},server=on,wait=off" \
    -pidfile "$PIDFILE"
