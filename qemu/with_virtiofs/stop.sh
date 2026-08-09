#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

QMP_SOCKET="${QMP_SOCKET:-/tmp/qemu-virtiofs.qmp}"
PIDFILE="${PIDFILE:-$SCRIPT_DIR/qemu.pid}"
QEMU_NETWORK_STATE="${QEMU_NETWORK_STATE:-$SCRIPT_DIR/network.state}"
VIRTIOFSD_SOCK="${VIRTIOFSD_SOCK:-/tmp/qemu-virtiofs.sock}"
VIRTIOFSD_PIDFILE="${VIRTIOFSD_PIDFILE:-$SCRIPT_DIR/virtiofsd.pid}"

qemu_cleanup || true
if [ -s "$VIRTIOFSD_PIDFILE" ]; then
    pid="$(cat "$VIRTIOFSD_PIDFILE")"
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
fi
rm -f "$VIRTIOFSD_PIDFILE" "$VIRTIOFSD_SOCK"
echo "Stopped QEMU virtio-fs demo."
