#!/usr/bin/env bash

FC_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fc_asset_dir() {
    printf '%s\n' "${FIRECRACKER_ASSET_DIR:-$FC_ROOT}"
}

fc_find_kernel() {
    if [ -n "${KERNEL:-}" ]; then
        printf '%s\n' "$KERNEL"
        return
    fi

    local dir kernel
    dir="$(fc_asset_dir)"
    kernel="$(find "$dir" -maxdepth 1 -type f -name 'vmlinux-5.10.*' ! -name '*.config' | sort -V | tail -n 1)"
    if [ -z "$kernel" ]; then
        echo "Error: no vmlinux-5.10.* kernel found in $dir. Run ./dl_reqs.sh first." >&2
        return 1
    fi
    printf '%s\n' "$kernel"
}

fc_find_rootfs() {
    if [ -n "${ROOTFS:-}" ]; then
        printf '%s\n' "$ROOTFS"
        return
    fi

    local dir
    dir="$(fc_asset_dir)"
    if [ -f "$dir/rootfs.ext4" ]; then
        printf '%s\n' "$dir/rootfs.ext4"
        return
    fi
    if [ -f "$dir/ubuntu-22.04.ext4" ]; then
        printf '%s\n' "$dir/ubuntu-22.04.ext4"
        return
    fi

    echo "Error: no rootfs.ext4 or ubuntu-22.04.ext4 found in $dir. Run ./dl_reqs.sh first." >&2
    return 1
}

fc_find_ssh_key() {
    if [ -n "${SSH_KEY:-}" ]; then
        printf '%s\n' "$SSH_KEY"
        return
    fi

    local dir key
    dir="$(fc_asset_dir)"
    key="$dir/ubuntu-22.04.id_rsa"
    if [ ! -f "$key" ]; then
        echo "Error: no ubuntu-22.04.id_rsa found in $dir. Run ./dl_reqs.sh first." >&2
        return 1
    fi
    printf '%s\n' "$key"
}

fc_find_firecracker() {
    if [ -n "${FIRECRACKER_BIN:-}" ]; then
        printf '%s\n' "$FIRECRACKER_BIN"
        return
    fi

    if [ -x "$FC_ROOT/firecracker" ]; then
        printf '%s\n' "$FC_ROOT/firecracker"
        return
    fi

    if command -v firecracker >/dev/null 2>&1; then
        command -v firecracker
        return
    fi

    echo "Error: no Firecracker binary found. Run ./dl_reqs.sh first." >&2
    return 1
}

fc_host_iface() {
    if [ -n "${HOST_IFACE:-}" ]; then
        printf '%s\n' "$HOST_IFACE"
        return
    fi

    local iface
    iface="$(ip route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
    if [ -z "$iface" ]; then
        iface="eth0"
        echo "Warning: could not detect default interface, using $iface" >&2
    fi
    printf '%s\n' "$iface"
}

fc_api_put() {
    local path="$1"
    local body="$2"

    sudo curl --fail-with-body -sS -X PUT --unix-socket "${API_SOCKET}" \
        --data "$body" \
        "http://localhost/${path}"
    echo
}

fc_ssh() {
    local ip="$1"
    local key="$2"
    shift 2

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$key" \
        "root@${ip}" \
        "$@"
}

fc_wait_for_ssh() {
    local ip="$1"
    local key="$2"
    local retries="${SSH_RETRIES:-30}"

    for _ in $(seq 1 "$retries"); do
        if fc_ssh "$ip" "$key" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Error: SSH did not become ready on $ip" >&2
    return 1
}

fc_configure_guest_network() {
    local ip="$1"
    local gateway="$2"
    local key
    key="$(fc_find_ssh_key)"

    echo "Waiting for SSH on $ip..."
    fc_wait_for_ssh "$ip" "$key"

    fc_ssh "$ip" "$key" \
        "ip route replace default via $gateway dev eth0; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf"
}
