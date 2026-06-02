#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

: "${VIRTIOFSD_SOCK:=/tmp/cloud-hypervisor-virtiofs.sock}"
: "${VIRTIOFSD_PIDFILE:=$SCRIPT_DIR/virtiofsd.pid}"
: "${API_SOCKET:=/tmp/cloud-hypervisor-virtiofs-api.sock}"
: "${PIDFILE:=$SCRIPT_DIR/cloud-hypervisor.pid}"

ch_stop_existing_vm || true

if [ -f "$VIRTIOFSD_PIDFILE" ]; then
    pid="$(cat "$VIRTIOFSD_PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    fi
fi
pkill -TERM -f "$VIRTIOFSD_SOCK" 2>/dev/null || true
rm -f "$VIRTIOFSD_PIDFILE" "$VIRTIOFSD_SOCK" "$API_SOCKET"

sudo ip link del "$TAP_DEV" 2>/dev/null || true

host_iface="$(ch_host_iface)"
while sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null; do :; done
while sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
while sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null; do :; done

echo "Stopped Cloud Hypervisor virtio-fs demo."
