#!/usr/bin/env bash

set -euo pipefail

SIZE_MB="${1:-500}"
OVERLAY_FILE="${2:-overlay.ext4}"

echo "Creating ${SIZE_MB}MB overlay disk: ${OVERLAY_FILE}"
dd if=/dev/zero of="${OVERLAY_FILE}" bs=1M count="${SIZE_MB}"
mkfs.ext4 -F "${OVERLAY_FILE}"
echo "Created ${OVERLAY_FILE}"
