#!/usr/bin/env bash
# Builds the test OCI images and flattens each into ../../work as both EROFS
# and ext4:
#   oci-py.*       python:3.12-slim running py_child.py as /app/server.py
#   oci-py-pyc.*   the same image with its bytecode precompiled
#   oci-scratch.*  FROM scratch, only the static child_probe
# plus oci-py-pyc-inline.erofs and oci-scratch-inline.erofs, built with
# mkfs.erofs's default inline tails for comparison.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/../../work"
cp "$HERE/../py_child.py" "$HERE/py/server.py"
cp "$WORK/child_probe" "$HERE/scratch/child_probe"
sudo docker build -q -t fast-start-mkfs "$HERE/mkfs" >/dev/null
sudo docker build -q -t fast-start-oci-py "$HERE/py" >/dev/null
sudo docker build -q -t fast-start-oci-py-pyc "$HERE/py-pyc" >/dev/null
sudo docker build -q -t fast-start-oci-scratch "$HERE/scratch" >/dev/null
rm -f "$HERE/py/server.py" "$HERE/scratch/child_probe"
for name in py py-pyc scratch; do
    for fs in erofs ext4; do
        "$HERE/../oci_to_disk.sh" "fast-start-oci-$name" "$WORK/oci-$name.$fs"
    done
done
for name in py-pyc scratch; do
    EROFS_INLINE=1 "$HERE/../oci_to_disk.sh" "fast-start-oci-$name" "$WORK/oci-$name-inline.erofs"
done
