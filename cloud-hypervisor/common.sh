#!/usr/bin/env bash

CH_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ch_set_defaults() {
    : "${TAP_DEV:=tap0}"
    : "${TAP_IP:=172.16.0.1}"
    : "${GUEST_IP:=172.16.0.2}"
    : "${MASK_SHORT:=/30}"
    : "${MASK_LONG:=255.255.255.252}"
    : "${ROOT_DEVICE:=/dev/vda}"
    : "${CPUS:=boot=2}"
    : "${MEMORY:=size=1024M}"
    : "${MAC:=06:00:AC:10:00:02}"
    : "${API_SOCKET:=/tmp/cloud-hypervisor.sock}"
    : "${LOGFILE:=$CH_ROOT/cloud-hypervisor.log}"
    : "${CONSOLE_LOG:=$CH_ROOT/cloud-hypervisor-console.log}"
    : "${PIDFILE:=$CH_ROOT/cloud-hypervisor.pid}"
}

ch_asset_dir() {
    printf '%s\n' "${CLOUD_HYPERVISOR_ASSET_DIR:-$CH_ROOT}"
}

ch_find_kernel() {
    if [ -n "${KERNEL:-}" ]; then
        printf '%s\n' "$KERNEL"
        return
    fi

    local dir kernel
    dir="$(ch_asset_dir)"
    case "$(uname -m)" in
        x86_64)
            kernel="$dir/vmlinux-x86_64"
            ;;
        aarch64)
            kernel="$dir/Image-arm64"
            ;;
        *)
            echo "Error: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac

    if [ ! -f "$kernel" ]; then
        echo "Error: no Cloud Hypervisor guest kernel found at $kernel. Run ./dl_reqs.sh first." >&2
        return 1
    fi
    printf '%s\n' "$kernel"
}

ch_find_rootfs() {
    if [ -n "${ROOTFS:-}" ]; then
        printf '%s\n' "$ROOTFS"
        return
    fi

    local dir fc_root
    dir="$(ch_asset_dir)"
    fc_root="$(cd -- "$CH_ROOT/../firecracker" 2>/dev/null && pwd || true)"

    if [ -f "$dir/rootfs.ext4" ]; then
        printf '%s\n' "$dir/rootfs.ext4"
        return
    fi
    if [ -f "$dir/ubuntu-22.04.ext4" ]; then
        printf '%s\n' "$dir/ubuntu-22.04.ext4"
        return
    fi
    if [ -n "$fc_root" ] && [ -f "$fc_root/rootfs.ext4" ]; then
        printf '%s\n' "$fc_root/rootfs.ext4"
        return
    fi
    if [ -n "$fc_root" ] && [ -f "$fc_root/ubuntu-22.04.ext4" ]; then
        printf '%s\n' "$fc_root/ubuntu-22.04.ext4"
        return
    fi

    echo "Error: no rootfs.ext4 or ubuntu-22.04.ext4 found. Run ./dl_reqs.sh first or set ROOTFS=..." >&2
    return 1
}

ch_find_ssh_key() {
    if [ -n "${SSH_KEY:-}" ]; then
        printf '%s\n' "$SSH_KEY"
        return
    fi

    local dir fc_root
    dir="$(ch_asset_dir)"
    fc_root="$(cd -- "$CH_ROOT/../firecracker" 2>/dev/null && pwd || true)"

    if [ -f "$dir/ubuntu-22.04.id_rsa" ]; then
        printf '%s\n' "$dir/ubuntu-22.04.id_rsa"
        return
    fi
    if [ -n "$fc_root" ] && [ -f "$fc_root/ubuntu-22.04.id_rsa" ]; then
        printf '%s\n' "$fc_root/ubuntu-22.04.id_rsa"
        return
    fi

    echo "Error: no ubuntu-22.04.id_rsa found. Run ./dl_reqs.sh first or set SSH_KEY=..." >&2
    return 1
}

ch_find_binary() {
    if [ -n "${CLOUD_HYPERVISOR_BIN:-}" ]; then
        printf '%s\n' "$CLOUD_HYPERVISOR_BIN"
        return
    fi

    if [ -x "$CH_ROOT/cloud-hypervisor" ]; then
        printf '%s\n' "$CH_ROOT/cloud-hypervisor"
        return
    fi

    if command -v cloud-hypervisor >/dev/null 2>&1; then
        command -v cloud-hypervisor
        return
    fi

    echo "Error: no Cloud Hypervisor binary found. Run ./dl_reqs.sh first." >&2
    return 1
}

ch_find_remote() {
    if [ -n "${CH_REMOTE_BIN:-}" ]; then
        printf '%s\n' "$CH_REMOTE_BIN"
        return
    fi

    if [ -x "$CH_ROOT/ch-remote" ]; then
        printf '%s\n' "$CH_ROOT/ch-remote"
        return
    fi

    if command -v ch-remote >/dev/null 2>&1; then
        command -v ch-remote
        return
    fi

    return 1
}

ch_host_iface() {
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

ch_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && sudo kill -0 "$pid" 2>/dev/null
}

ch_setup_tap() {
    ch_set_defaults

    local metadata="${1:-}"
    local host_iface

    ch_stop_existing_vm

    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(id -un)"
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"

    if [ "$metadata" = "metadata" ]; then
        : "${METADATA_IP:=169.254.169.254}"
        sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"
    fi

    sudo ip link set dev "$TAP_DEV" up
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

    host_iface="$(ch_host_iface)"
    echo "Using host interface: $host_iface"

    sudo iptables -t nat -D POSTROUTING -o "$host_iface" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$TAP_DEV" -o "$host_iface" -j ACCEPT 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -o "$host_iface" -j MASQUERADE
    sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -I FORWARD 1 -i "$TAP_DEV" -o "$host_iface" -j ACCEPT
}

ch_stop_existing_vm() {
    ch_set_defaults

    local remote pid pid_file

    if [ -S "$API_SOCKET" ] && remote="$(ch_find_remote 2>/dev/null)"; then
        sudo "$remote" --api-socket "$API_SOCKET" shutdown-vmm >/dev/null 2>&1 || true
    fi

    for pid_file in "$PIDFILE" "${PIDFILE}.sudo"; do
        if [ ! -f "$pid_file" ]; then
            continue
        fi

        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && ch_pid_alive "$pid"; then
            for _ in $(seq 1 20); do
                if ! ch_pid_alive "$pid"; then
                    break
                fi
                sleep 0.25
            done
            if ch_pid_alive "$pid"; then
                sudo kill "$pid" 2>/dev/null || true
            fi
            for _ in $(seq 1 20); do
                if ! ch_pid_alive "$pid"; then
                    break
                fi
                sleep 0.25
            done
            if ch_pid_alive "$pid"; then
                sudo kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    done

    rm -f "$PIDFILE" "${PIDFILE}.sudo"
}

ch_kernel_boot_args() {
    ch_set_defaults

    local root_mode="${1:-rw}"
    local init_arg="${2:-}"
    local console_arg

    case "$(uname -m)" in
        aarch64)
            console_arg="console=ttyAMA0"
            ;;
        *)
            console_arg="console=ttyS0"
            ;;
    esac

    local args
    args="${console_arg} root=${ROOT_DEVICE} ${root_mode} rootwait reboot=k panic=1"
    args="${args} net.ifnames=0 biosdevname=0"
    args="${args} ip=${GUEST_IP}::${TAP_IP}:${MASK_LONG}::eth0:off"

    if [ -n "$init_arg" ]; then
        args="${args} ${init_arg}"
    fi
    if [ -n "${KERNEL_BOOT_ARGS_EXTRA:-}" ]; then
        args="${args} ${KERNEL_BOOT_ARGS_EXTRA}"
    fi

    printf '%s\n' "$args"
}

ch_start_vm() {
    ch_set_defaults

    local boot_args="$1"
    local rootfs_readonly="$2"
    shift 2

    local bin kernel rootfs net_arg
    bin="$(ch_find_binary)"
    kernel="$(ch_find_kernel)"
    rootfs="$(ch_find_rootfs)"
    net_arg="tap=${TAP_DEV},mac=${MAC}"

    ch_stop_existing_vm
    sudo rm -f "$API_SOCKET"
    : > "$LOGFILE"
    : > "$CONSOLE_LOG"

    echo "Starting Cloud Hypervisor..."
    echo "  Kernel: $kernel"
    echo "  Rootfs: $rootfs"
    echo "  API socket: $API_SOCKET"

    local args
    args=(
        --kernel "$kernel"
        --cmdline "$boot_args"
        --disk "path=${rootfs},readonly=${rootfs_readonly}"
        --cpus "$CPUS"
        --memory "$MEMORY"
        --net "$net_arg"
        --api-socket "path=${API_SOCKET}"
        --serial "file=${CONSOLE_LOG}"
        --console off
        --log-file "$LOGFILE"
    )

    local disk
    for disk in "$@"; do
        args+=(--disk "$disk")
    done

    sudo "$bin" "${args[@]}" &
    local sudo_pid real_pid
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "${PIDFILE}.sudo"

    sleep 0.25
    real_pid="$(pgrep -P "$sudo_pid" -f "$(basename "$bin")" | head -n 1 || true)"
    printf '%s\n' "${real_pid:-$sudo_pid}" > "$PIDFILE"

    sleep 1
    if ! ch_pid_alive "$(cat "$PIDFILE")"; then
        echo "Error: Cloud Hypervisor exited early." >&2
        echo "Console log:" >&2
        tail -n 80 "$CONSOLE_LOG" >&2 || true
        echo "VMM log:" >&2
        tail -n 80 "$LOGFILE" >&2 || true
        return 1
    fi
}

ch_ssh() {
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

ch_wait_for_ssh() {
    local ip="$1"
    local key="$2"
    local retries="${SSH_RETRIES:-45}"

    for _ in $(seq 1 "$retries"); do
        if ch_ssh "$ip" "$key" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Error: SSH did not become ready on $ip" >&2
    return 1
}

ch_configure_guest_network() {
    local ip="$1"
    local gateway="$2"
    local key
    key="$(ch_find_ssh_key)"

    echo "Waiting for SSH on $ip..."
    ch_wait_for_ssh "$ip" "$key"

    ch_ssh "$ip" "$key" \
        "ip route replace default via $gateway dev eth0; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf"
}

ch_shutdown_vm() {
    ch_set_defaults

    local remote
    if remote="$(ch_find_remote 2>/dev/null)"; then
        sudo "$remote" --api-socket "$API_SOCKET" shutdown-vmm >/dev/null 2>&1 || true
    fi
}
