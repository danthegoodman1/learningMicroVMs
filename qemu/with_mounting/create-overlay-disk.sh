#!/usr/bin/env bash

set -euo pipefail

SIZE_MB="${1:-500}"
OVERLAY_FILE="${2:-overlay.ext4}"

if [ -e "$OVERLAY_FILE" ]; then
    echo "Error: file already exists: $OVERLAY_FILE" >&2
    exit 1
fi
truncate -s "${SIZE_MB}M" "$OVERLAY_FILE"
mkfs.ext4 -F "$OVERLAY_FILE"
echo "Created ${OVERLAY_FILE} (${SIZE_MB} MiB)."
