#!/usr/bin/env bash
# Flattens an OCI image into a read-only disk plus a JSON file with what the
# supervisor needs to run it: argv (Entrypoint + Cmd), env, and cwd.
# usage: oci_to_disk.sh <image> <out.erofs|out.ext4> [extra mkfs.erofs options, e.g. -zlz4hc]
#        EROFS_INLINE=1 keeps mkfs.erofs's default inline tails (see below).
# The extension picks the filesystem. Writes <out>.json too. The image gets
# empty /dev, /proc, /sys, /run and /tmp, so the supervisor can mount over them
# without an overlay.
set -euo pipefail

IMAGE="$1"
OUT="$2"
shift 2
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'sudo rm -rf "$TMP"' EXIT

cid="$(sudo docker create "$IMAGE")"
sudo docker export "$cid" | sudo tar -C "$TMP" -xpf -
sudo docker inspect --format '{{json .Config}}' "$IMAGE" | python3 -c '
import json, sys
c = json.load(sys.stdin)
argv = (c.get("Entrypoint") or []) + (c.get("Cmd") or [])
env = dict(e.split("=", 1) for e in (c.get("Env") or []))
json.dump({"argv": argv, "env": env, "cwd": c.get("WorkingDir") or "/", "user": c.get("User") or ""}, open(sys.argv[1], "w"), indent=1)
' "$OUT.json"
sudo docker rm "$cid" >/dev/null
sudo install -d -m 755 "$TMP/dev" "$TMP/proc" "$TMP/sys" "$TMP/run"
sudo install -d -m 1777 "$TMP/tmp"

rm -f "$OUT"
case "$OUT" in
*.erofs)
    # By default mkfs.erofs packs each file's last partial block in with its
    # metadata. Guests read those tails more slowly than whole blocks: Python
    # started 3-4 ms slower than with -Enoinline_data, for 10% less space.
    inline=(-Enoinline_data)
    [ "${EROFS_INLINE:-0}" = 1 ] && inline=()
    sudo docker run --rm -v "$TMP:/src:ro" -v "$(cd "$(dirname "$OUT")" && pwd):/out" fast-start-mkfs \
        mkfs.erofs --quiet "${inline[@]}" "$@" "/out/$(basename "$OUT")" /src
    sudo chown "$(id -u):$(id -g)" "$OUT"
    # Block devices come in 512-byte sectors.
    truncate -s "%512" "$OUT"
    ;;
*)
    size_mb=$(( $(sudo du -sm "$TMP" | cut -f1) * 12 / 10 + 16 ))
    truncate -s "${size_mb}M" "$OUT"
    sudo mkfs.ext4 -q -F -d "$TMP" "$OUT"
    sudo chown "$(id -u):$(id -g)" "$OUT"
    ;;
esac
echo "$OUT: $(numfmt --to=iec "$(stat -c %s "$OUT")"), $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["argv"])' "$OUT.json")"
