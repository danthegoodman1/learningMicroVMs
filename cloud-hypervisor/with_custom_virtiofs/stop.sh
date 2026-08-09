#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/demo-common.sh"

if [ "${1:-}" = "daemon-only" ]; then
    custom_stop_daemon
    exit 0
fi

custom_cleanup_host

echo "Stopped custom Cloud Hypervisor virtio-fs demo."
