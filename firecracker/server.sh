#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

API_SOCKET="${API_SOCKET:-/tmp/firecracker.socket}"
FIRECRACKER_BIN="$(fc_find_firecracker)"

# Remove API unix socket
sudo rm -f $API_SOCKET

# Run firecracker
sudo "$FIRECRACKER_BIN" --api-sock "${API_SOCKET}"
