#!/bin/bash
# Helper script to create an overlay disk for persistent mode

set -e

OVERLAY_SIZE_MB="${1:-500}"
OVERLAY_FILE="${2:-overlay.ext4}"

if [ -f "$OVERLAY_FILE" ]; then
    echo "Error: $OVERLAY_FILE already exists"
    echo "Delete it first or specify a different name"
    exit 1
fi

echo "Creating ${OVERLAY_SIZE_MB}MB overlay disk: ${OVERLAY_FILE}"

# Create empty file
dd if=/dev/zero of="${OVERLAY_FILE}" bs=1M count="${OVERLAY_SIZE_MB}"

# Format as ext4
mkfs.ext4 -F "${OVERLAY_FILE}"

echo ""
echo "✅ Created overlay disk: ${OVERLAY_FILE}"
echo ""
echo "To use it with persistent overlay mode:"
echo "  OVERLAY_MODE=persistent OVERLAY_IMG=./${OVERLAY_FILE} ./spawn_overlay.sh"
echo ""
echo "Or to use tmpfs (ephemeral, no disk needed):"
echo "  ./spawn_overlay.sh"
