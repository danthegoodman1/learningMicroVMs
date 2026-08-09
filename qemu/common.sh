#!/usr/bin/env bash

QEMU_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$QEMU_ROOT/.." && pwd)"

qemu_set_defaults() {
    : "${TAP_DEV:=tap0}"
    : "${TAP_IP:=172.16.0.1}"
    : "${TAP_CIDR:=172.16.0.0/30}"
    : "${GUEST_IP:=172.16.0.2}"
    : "${MASK_SHORT:=/30}"
    : "${MASK_LONG:=255.255.255.252}"
    : "${MAC:=06:00:AC:10:00:02}"
    : "${QMP_SOCKET:=/tmp/qemu-learning-microvms.qmp}"
    : "${PIDFILE:=$QEMU_ROOT/qemu.pid}"
    : "${LOGFILE:=$QEMU_ROOT/qemu.log}"
    : "${CONSOLE_LOG:=$QEMU_ROOT/qemu-console.log}"
    : "${CPUS:=2}"
    : "${MEMORY_MIB:=1024}"
    : "${QEMU_MEMORY_ARG:=${MEMORY_MIB}M}"
    : "${QEMU_MACHINE:=microvm}"
    : "${QEMU_NETWORK_STATE:=${PIDFILE}.network}"
    : "${QEMU_IPTABLES_COMMENT:=learningMicroVMs-${TAP_DEV}}"
}

qemu_find_binary() {
    if [ -n "${QEMU_BIN:-}" ]; then
        printf '%s\n' "$QEMU_BIN"
    elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
        command -v qemu-system-x86_64
    else
        echo "Error: qemu-system-x86_64 is missing. Install qemu-system-x86." >&2
        return 1
    fi
}

qemu_find_kernel() {
    if [ -n "${KERNEL:-}" ]; then
        printf '%s\n' "$KERNEL"
        return
    fi

    local kernel
    kernel="$(find "$REPO_ROOT/firecracker" -maxdepth 1 -type f \
        -name 'vmlinux-5.10.*' ! -name '*.config' | sort -V | tail -n 1)"
    if [ -z "$kernel" ]; then
        echo "Error: no vmlinux-5.10.* kernel found; run firecracker/dl_reqs.sh." >&2
        return 1
    fi
    printf '%s\n' "$kernel"
}

qemu_find_rootfs() {
    if [ -n "${ROOTFS:-}" ]; then
        printf '%s\n' "$ROOTFS"
        return
    fi

    local candidate
    for candidate in \
        "$REPO_ROOT/firecracker/rootfs.ext4" \
        "$REPO_ROOT/firecracker/ubuntu-22.04.ext4" \
        "$REPO_ROOT/cloud-hypervisor/rootfs.ext4" \
        "$REPO_ROOT/cloud-hypervisor/ubuntu-22.04.ext4"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    echo "Error: no rootfs found; run firecracker/dl_reqs.sh." >&2
    return 1
}

qemu_find_ssh_key() {
    if [ -n "${SSH_KEY:-}" ]; then
        printf '%s\n' "$SSH_KEY"
        return
    fi

    local candidate
    for candidate in \
        "$REPO_ROOT/firecracker/ubuntu-22.04.id_rsa" \
        "$REPO_ROOT/cloud-hypervisor/ubuntu-22.04.id_rsa"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    echo "Error: no SSH key found; run firecracker/dl_reqs.sh." >&2
    return 1
}

qemu_host_iface() {
    if [ -n "${HOST_IFACE:-}" ]; then
        printf '%s\n' "$HOST_IFACE"
        return
    fi
    local iface
    iface="$(ip route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
    [ -n "$iface" ] || iface=eth0
    printf '%s\n' "$iface"
}

qemu_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

qemu_wait_for_qmp() {
    qemu_set_defaults
    for _ in $(seq 1 "${QMP_RETRIES:-100}"); do
        [ -S "$QMP_SOCKET" ] && return 0
        sleep 0.05
    done
    echo "Error: timed out waiting for QMP socket $QMP_SOCKET" >&2
    return 1
}

qemu_qmp() {
    qemu_set_defaults
    "$QEMU_ROOT/qmp.py" "$QMP_SOCKET" "$@"
}

qemu_stop_existing_vm() {
    qemu_set_defaults
    local pid=""
    if [ -S "$QMP_SOCKET" ]; then
        qemu_qmp quit >/dev/null 2>&1 || true
    fi
    if [ -s "$PIDFILE" ]; then
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    fi
    if qemu_pid_alive "$pid"; then
        for _ in $(seq 1 40); do
            qemu_pid_alive "$pid" || break
            sleep 0.1
        done
    fi
    if qemu_pid_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$QMP_SOCKET" "$PIDFILE"
}

qemu_cleanup_tap() {
    qemu_set_defaults
    local host_iface previous_ip_forward=""
    host_iface="$(qemu_host_iface)"
    if [ -f "$QEMU_NETWORK_STATE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                host_iface) host_iface="$value" ;;
                ip_forward) previous_ip_forward="$value" ;;
            esac
        done < "$QEMU_NETWORK_STATE"
    fi

    while sudo iptables -w -t nat -D POSTROUTING -s "$TAP_CIDR" \
        -o "$host_iface" -m comment --comment "$QEMU_IPTABLES_COMMENT" \
        -j MASQUERADE 2>/dev/null; do :; done
    while sudo iptables -w -D FORWARD -i "$TAP_DEV" -o "$host_iface" \
        -m comment --comment "$QEMU_IPTABLES_COMMENT" -j ACCEPT \
        2>/dev/null; do :; done
    while sudo iptables -w -D FORWARD -i "$host_iface" -o "$TAP_DEV" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "$QEMU_IPTABLES_COMMENT" -j ACCEPT \
        2>/dev/null; do :; done
    sudo ip link del "$TAP_DEV" 2>/dev/null || true

    if [ "$previous_ip_forward" = 0 ] || [ "$previous_ip_forward" = 1 ]; then
        sudo sysctl -q -w net.ipv4.ip_forward="$previous_ip_forward"
    fi
    rm -f "$QEMU_NETWORK_STATE"
}

qemu_setup_tap() {
    qemu_set_defaults
    local metadata="${1:-}" host_iface previous_ip_forward

    qemu_stop_existing_vm
    qemu_cleanup_tap
    host_iface="$(qemu_host_iface)"
    previous_ip_forward="$(sysctl -n net.ipv4.ip_forward)"
    mkdir -p "$(dirname -- "$QEMU_NETWORK_STATE")"
    printf 'host_iface=%s\nip_forward=%s\n' \
        "$host_iface" "$previous_ip_forward" > "$QEMU_NETWORK_STATE"

    sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(id -un)"
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
    if [ "$metadata" = metadata ]; then
        : "${METADATA_IP:=169.254.169.254}"
        if ! ip -4 addr show | grep -q "${METADATA_IP}/"; then
            sudo ip addr add "${METADATA_IP}/32" dev "$TAP_DEV"
        fi
    fi
    sudo ip link set dev "$TAP_DEV" up
    sudo sysctl -q -w net.ipv4.ip_forward=1

    sudo iptables -w -t nat -A POSTROUTING -s "$TAP_CIDR" \
        -o "$host_iface" -m comment --comment "$QEMU_IPTABLES_COMMENT" \
        -j MASQUERADE
    sudo iptables -w -I FORWARD 1 -i "$TAP_DEV" -o "$host_iface" \
        -m comment --comment "$QEMU_IPTABLES_COMMENT" -j ACCEPT
    sudo iptables -w -I FORWARD 1 -i "$host_iface" -o "$TAP_DEV" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "$QEMU_IPTABLES_COMMENT" -j ACCEPT
    echo "Using host interface: $host_iface"
}

qemu_kernel_boot_args() {
    qemu_set_defaults
    local root_mode="${1:-rw}" init_arg="${2:-}" args
    args="console=ttyS0 root=/dev/vda ${root_mode} rootwait reboot=k panic=1"
    args+=" net.ifnames=0 biosdevname=0"
    args+=" ip=${GUEST_IP}::${TAP_IP}:${MASK_LONG}::eth0:off"
    if [ "$QEMU_MACHINE" = microvm ]; then
        args+=" pci=off"
    fi
    [ -z "$init_arg" ] || args+=" $init_arg"
    [ -z "${KERNEL_BOOT_ARGS_EXTRA:-}" ] || args+=" $KERNEL_BOOT_ARGS_EXTRA"
    printf '%s\n' "$args"
}

qemu_start_vm() {
    qemu_set_defaults
    local boot_args="$1" rootfs_readonly="$2"
    shift 2

    local bin kernel rootfs readonly_value machine_args root_device net_device
    bin="$(qemu_find_binary)"
    kernel="$(qemu_find_kernel)"
    rootfs="$(qemu_find_rootfs)"
    if [ "$rootfs_readonly" = on ]; then readonly_value=on; else readonly_value=off; fi

    case "$QEMU_MACHINE" in
        microvm)
            machine_args="microvm,accel=kvm,pic=off,pit=off,rtc=off"
            root_device=virtio-blk-device
            net_device=virtio-net-device
            ;;
        q35)
            machine_args="q35,accel=kvm"
            root_device=virtio-blk-pci
            net_device=virtio-net-pci
            ;;
        *)
            echo "Error: QEMU_MACHINE must be microvm or q35" >&2
            return 1
            ;;
    esac

    qemu_stop_existing_vm
    rm -f "$QMP_SOCKET"
    : > "$LOGFILE"
    : > "$CONSOLE_LOG"

    echo "Starting QEMU ($QEMU_MACHINE)..."
    echo "  Kernel: $kernel"
    echo "  Rootfs: $rootfs"
    echo "  QMP socket: $QMP_SOCKET"

    "$bin" \
        -machine "$machine_args" \
        -cpu host \
        -smp "$CPUS" \
        -m "$QEMU_MEMORY_ARG" \
        -nodefaults \
        -no-user-config \
        -nographic \
        -kernel "$kernel" \
        -append "$boot_args" \
        -drive "file=${rootfs},format=raw,if=none,id=rootfs,readonly=${readonly_value},cache=none" \
        -device "${root_device},drive=rootfs" \
        -netdev "tap,id=net0,ifname=${TAP_DEV},script=no,downscript=no" \
        -device "${net_device},netdev=net0,mac=${MAC}" \
        -serial "file:${CONSOLE_LOG}" \
        -qmp "unix:${QMP_SOCKET},server=on,wait=off" \
        -pidfile "$PIDFILE" \
        -D "$LOGFILE" \
        "$@" \
        -daemonize

    qemu_wait_for_qmp
    local pid
    pid="$(cat "$PIDFILE")"
    if ! qemu_pid_alive "$pid"; then
        echo "Error: QEMU exited early." >&2
        tail -n 80 "$CONSOLE_LOG" >&2 || true
        tail -n 80 "$LOGFILE" >&2 || true
        return 1
    fi
}

qemu_ssh() {
    local ip="$1" key="$2"
    shift 2
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$key" \
        "root@${ip}" "$@"
}

qemu_wait_for_ssh() {
    local ip="$1" key="$2"
    for _ in $(seq 1 "${SSH_RETRIES:-45}"); do
        qemu_ssh "$ip" "$key" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "Error: SSH did not become ready on $ip" >&2
    return 1
}

qemu_configure_guest_network() {
    local ip="$1" gateway="$2" key
    key="$(qemu_find_ssh_key)"
    echo "Waiting for SSH on $ip..."
    qemu_wait_for_ssh "$ip" "$key"
    qemu_ssh "$ip" "$key" \
        "ip route replace default via $gateway dev eth0; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf"
}

qemu_cleanup() {
    qemu_stop_existing_vm
    qemu_cleanup_tap
}
