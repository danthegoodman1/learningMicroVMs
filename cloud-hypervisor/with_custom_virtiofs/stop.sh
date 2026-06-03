#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${CUSTOM_VIRTIOFSD_SOCK:=/tmp/cloud-hypervisor-custom-virtiofs.sock}"
: "${CUSTOM_VIRTIOFSD_PIDFILE:=$SCRIPT_DIR/custom-virtiofsd.pid}"
: "${API_SOCKET:=/tmp/cloud-hypervisor-custom-virtiofs-api.sock}"
: "${PIDFILE:=$SCRIPT_DIR/cloud-hypervisor.pid}"
: "${TAP_DEV:=tap0}"

stop_daemon() {
    local pid
    if [ -f "$CUSTOM_VIRTIOFSD_PIDFILE" ]; then
        pid="$(cat "$CUSTOM_VIRTIOFSD_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    pkill -TERM -f "$CUSTOM_VIRTIOFSD_SOCK" 2>/dev/null || true
    rm -f "$CUSTOM_VIRTIOFSD_PIDFILE" "$CUSTOM_VIRTIOFSD_SOCK" "${CUSTOM_VIRTIOFSD_SOCK}.pid"
}

if [ "${1:-}" = "daemon-only" ]; then
    stop_daemon
    exit 0
fi

if remote="$(ch_find_remote 2>/dev/null)"; then
    if [ -S "$API_SOCKET" ]; then
        sudo "$remote" --api-socket "$API_SOCKET" remove-device customfs0 >/dev/null 2>&1 || true
    fi
fi

ch_stop_existing_vm || true
stop_daemon
sudo rm -f "$API_SOCKET"
sudo ip link del "$TAP_DEV" 2>/dev/null || true

host_iface="$(ch_host_iface)"
while sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null; do :; done
while sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null; do :; done

echo "Stopped custom Cloud Hypervisor virtio-fs demo."
