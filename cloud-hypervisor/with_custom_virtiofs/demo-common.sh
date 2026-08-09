#!/usr/bin/env bash

# Shared helpers for the custom Rust virtio-fs Cloud Hypervisor demos.

CUSTOM_VIRTIOFS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$CUSTOM_VIRTIOFS_DIR/../common.sh"

: "${FS_TAG:=hostshare}"
: "${FS_ID:=customfs0}"
: "${SHARE_DIR:=$CUSTOM_VIRTIOFS_DIR/shared}"
: "${CUSTOM_VIRTIOFSD_SOCK:=/tmp/cloud-hypervisor-custom-virtiofs.sock}"
: "${CUSTOM_VIRTIOFSD_LOG:=$CUSTOM_VIRTIOFS_DIR/custom-virtiofsd.log}"
: "${CUSTOM_VIRTIOFSD_PIDFILE:=$CUSTOM_VIRTIOFS_DIR/custom-virtiofsd.pid}"
: "${API_SOCKET:=/tmp/cloud-hypervisor-custom-virtiofs-api.sock}"
: "${LOGFILE:=$CUSTOM_VIRTIOFS_DIR/cloud-hypervisor.log}"
: "${CONSOLE_LOG:=$CUSTOM_VIRTIOFS_DIR/cloud-hypervisor-console.log}"
: "${PIDFILE:=$CUSTOM_VIRTIOFS_DIR/cloud-hypervisor.pid}"
: "${MEMORY:=size=1024M,shared=on}"
: "${WORK_DIR:=$CUSTOM_VIRTIOFS_DIR/work}"
: "${TAP_DEV:=tap-custom-vfs}"
: "${TAP_IP:=172.16.22.1}"
: "${GUEST_IP:=172.16.22.2}"
: "${TAP_CIDR:=172.16.22.0/30}"
: "${MASK_SHORT:=/30}"
: "${MASK_LONG:=255.255.255.252}"
: "${CUSTOM_IPTABLES_COMMENT:=learningMicroVMs-custom-virtiofs}"
: "${CUSTOM_NETWORK_STATE:=$WORK_DIR/network.state}"

CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
DAEMON_MANIFEST="$CUSTOM_VIRTIOFS_DIR/custom-virtiofsd/Cargo.toml"
DAEMON_BIN="$CUSTOM_VIRTIOFS_DIR/custom-virtiofsd/target/release/custom-virtiofsd"
GUEST_MOUNT="/mnt/$FS_TAG"

custom_build_daemon() {
    if [ ! -x "$CARGO_BIN" ]; then
        echo "Error: cargo not found at $CARGO_BIN. Set CARGO_BIN=... or add Rust to PATH." >&2
        exit 1
    fi
    "$CARGO_BIN" build --release --manifest-path "$DAEMON_MANIFEST"
}

custom_stop_daemon() {
    local pid
    if [ -f "$CUSTOM_VIRTIOFSD_PIDFILE" ]; then
        pid="$(cat "$CUSTOM_VIRTIOFSD_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            sudo pkill -TERM -P "$pid" 2>/dev/null || pkill -TERM -P "$pid" 2>/dev/null || true
            sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
    fi
    if command -v fuser >/dev/null 2>&1 && [ -S "$CUSTOM_VIRTIOFSD_SOCK" ]; then
        sudo fuser -k "$CUSTOM_VIRTIOFSD_SOCK" >/dev/null 2>&1 || fuser -k "$CUSTOM_VIRTIOFSD_SOCK" >/dev/null 2>&1 || true
    fi
    rm -f "$CUSTOM_VIRTIOFSD_PIDFILE"
    sudo rm -f "$CUSTOM_VIRTIOFSD_SOCK" "${CUSTOM_VIRTIOFSD_SOCK}.pid"
}

custom_start_daemon() {
    local mode="${1:-reset}"

    custom_stop_daemon
    mkdir -p "$SHARE_DIR"

    if [ "$mode" = "reset" ]; then
        rm -f "$SHARE_DIR/from-guest.txt" \
            "$SHARE_DIR/before-snapshot.txt" \
            "$SHARE_DIR/after-restore.txt"
        printf 'hello from the host via custom virtio-fs\n' > "$SHARE_DIR/from-host.txt"
        : > "$CUSTOM_VIRTIOFSD_LOG"
    else
        printf '\n--- custom virtiofsd restart: %s ---\n' "$(date -Is)" >> "$CUSTOM_VIRTIOFSD_LOG"
    fi

    sudo env RUST_LOG="${RUST_LOG:-info}" "$DAEMON_BIN" \
        --socket-path "$CUSTOM_VIRTIOFSD_SOCK" \
        --shared-dir "$SHARE_DIR" \
        --thread-pool-size 0 \
        >>"$CUSTOM_VIRTIOFSD_LOG" 2>&1 &
    printf '%s\n' "$!" > "$CUSTOM_VIRTIOFSD_PIDFILE"

    for _ in $(seq 1 100); do
        if [ -S "$CUSTOM_VIRTIOFSD_SOCK" ]; then
            return 0
        fi
        sleep 0.05
    done

    echo "Error: custom virtiofsd did not create $CUSTOM_VIRTIOFSD_SOCK" >&2
    cat "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
    return 1
}

custom_fs_config() {
    printf 'tag=%s,socket=%s,num_queues=1,queue_size=512,id=%s\n' \
        "$FS_TAG" "$CUSTOM_VIRTIOFSD_SOCK" "$FS_ID"
}

custom_add_fs() {
    sudo "$(ch_find_remote)" --api-socket "$API_SOCKET" add-fs \
        "$(custom_fs_config)" >/dev/null
}

custom_remove_fs() {
    if remote="$(ch_find_remote 2>/dev/null)"; then
        timeout 5 sudo "$remote" --api-socket "$API_SOCKET" remove-device "$FS_ID" >/dev/null 2>&1 || true
    fi
}

custom_cleanup_tap_and_nat() {
    local host_iface=""
    local previous_ip_forward=""

    if [ -f "$CUSTOM_NETWORK_STATE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                host_iface) host_iface="$value" ;;
                ip_forward) previous_ip_forward="$value" ;;
            esac
        done < "$CUSTOM_NETWORK_STATE"
    fi
    if [ -z "$host_iface" ]; then
        host_iface="$(ch_host_iface)"
    fi

    while sudo iptables -w -t nat -D POSTROUTING -s "$TAP_CIDR" \
        -o "$host_iface" -m comment --comment "$CUSTOM_IPTABLES_COMMENT" \
        -j MASQUERADE 2>/dev/null; do :; done
    while sudo iptables -w -D FORWARD -i "$TAP_DEV" -o "$host_iface" \
        -m comment --comment "$CUSTOM_IPTABLES_COMMENT" -j ACCEPT \
        2>/dev/null; do :; done
    while sudo iptables -w -D FORWARD -i "$host_iface" -o "$TAP_DEV" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "$CUSTOM_IPTABLES_COMMENT" -j ACCEPT \
        2>/dev/null; do :; done

    sudo ip link del "$TAP_DEV" 2>/dev/null || true

    if [ "$previous_ip_forward" = "0" ] || [ "$previous_ip_forward" = "1" ]; then
        sudo sysctl -q -w net.ipv4.ip_forward="$previous_ip_forward"
    fi
    rm -f "$CUSTOM_NETWORK_STATE"
}

custom_setup_tap_and_nat() {
    local host_iface previous_ip_forward

    custom_cleanup_tap_and_nat
    host_iface="$(ch_host_iface)"
    previous_ip_forward="$(sysctl -n net.ipv4.ip_forward)"
    mkdir -p "$WORK_DIR"
    printf 'host_iface=%s\nip_forward=%s\n' \
        "$host_iface" "$previous_ip_forward" > "$CUSTOM_NETWORK_STATE"

    sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(id -un)"
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
    sudo ip link set dev "$TAP_DEV" up
    sudo sysctl -q -w net.ipv4.ip_forward=1

    sudo iptables -w -t nat -A POSTROUTING -s "$TAP_CIDR" \
        -o "$host_iface" -m comment --comment "$CUSTOM_IPTABLES_COMMENT" \
        -j MASQUERADE
    sudo iptables -w -I FORWARD 1 -i "$TAP_DEV" -o "$host_iface" \
        -m comment --comment "$CUSTOM_IPTABLES_COMMENT" -j ACCEPT
    sudo iptables -w -I FORWARD 1 -i "$host_iface" -o "$TAP_DEV" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "$CUSTOM_IPTABLES_COMMENT" -j ACCEPT
}

custom_start_vm() {
    local boot_args
    boot_args="$(ch_kernel_boot_args rw)"

    custom_setup_tap_and_nat
    API_SOCKET="$API_SOCKET" \
    LOGFILE="$LOGFILE" \
    CONSOLE_LOG="$CONSOLE_LOG" \
    PIDFILE="$PIDFILE" \
    MEMORY="$MEMORY" \
    ch_start_vm "$boot_args" off
}

custom_start_restore_vm() {
    local mode="$1"
    local snapshot_dir="$2"
    local bin
    bin="$(ch_find_binary)"

    sudo rm -f "$API_SOCKET"
    : > "$LOGFILE"
    : > "$CONSOLE_LOG"

    local args=(
        --api-socket "path=${API_SOCKET}"
        --log-file "$LOGFILE"
        --restore "source_url=file://${snapshot_dir},memory_restore_mode=${mode},resume=true"
    )

    sudo "$bin" "${args[@]}" &

    local sudo_pid real_pid
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "${PIDFILE}.sudo"

    sleep 0.25
    real_pid="$(pgrep -P "$sudo_pid" -f "$(basename "$bin")" | head -n 1 || true)"
    printf '%s\n' "${real_pid:-$sudo_pid}" > "$PIDFILE"

    sleep 1
    if ! ch_pid_alive "$(cat "$PIDFILE")"; then
        echo "Error: Cloud Hypervisor restore exited early." >&2
        echo "Console log:" >&2
        tail -n 80 "$CONSOLE_LOG" >&2 || true
        echo "VMM log:" >&2
        tail -n 80 "$LOGFILE" >&2 || true
        return 1
    fi
}

custom_stop_vm() {
    ch_set_defaults

    local remote pid pid_file

    if [ -S "$API_SOCKET" ] && remote="$(ch_find_remote 2>/dev/null)"; then
        timeout 5 sudo "$remote" --api-socket "$API_SOCKET" shutdown-vmm >/dev/null 2>&1 || true
    fi

    for pid_file in "$PIDFILE" "${PIDFILE}.sudo"; do
        if [ ! -f "$pid_file" ]; then
            continue
        fi

        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && ch_pid_alive "$pid"; then
            sudo kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 20); do
                if ! ch_pid_alive "$pid"; then
                    break
                fi
                sleep 0.1
            done
            if ch_pid_alive "$pid"; then
                sudo kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    done

    rm -f "$PIDFILE" "${PIDFILE}.sudo"
}

custom_wait_for_guest() {
    local key retries pid
    key="$(ch_find_ssh_key)"
    retries="${SSH_RETRIES:-45}"
    echo "Waiting for SSH on $GUEST_IP..."

    for _ in $(seq 1 "$retries"); do
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && ! ch_pid_alive "$pid"; then
            echo "Error: Cloud Hypervisor exited before SSH became ready." >&2
            echo "Console log:" >&2
            tail -n 80 "$CONSOLE_LOG" >&2 || true
            echo "VMM log:" >&2
            tail -n 80 "$LOGFILE" >&2 || true
            return 1
        fi

        if ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=1 \
            -o BatchMode=yes \
            -i "$key" \
            "root@${GUEST_IP}" \
            true >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done

    echo "Error: SSH did not become ready on $GUEST_IP" >&2
    return 1
}

custom_configure_guest_network() {
    sleep 5
    ch_configure_guest_network "$GUEST_IP" "$TAP_IP"
}

custom_verify_spawn_io() {
    local key
    key="$(ch_find_ssh_key)"
    custom_wait_for_guest

    if ! ch_ssh "$GUEST_IP" "$key" "
        set -e
        mkdir -p $GUEST_MOUNT
        modprobe virtiofs 2>/dev/null || true
        mountpoint -q $GUEST_MOUNT || mount -t virtiofs $FS_TAG $GUEST_MOUNT
        grep -q 'hello from the host via custom virtio-fs' $GUEST_MOUNT/from-host.txt
        printf 'hello from the guest via custom virtio-fs\n' > $GUEST_MOUNT/from-guest.txt
        sync $GUEST_MOUNT/from-guest.txt
        cat $GUEST_MOUNT/from-host.txt
        cat $GUEST_MOUNT/from-guest.txt
        umount $GUEST_MOUNT
    "; then
        echo "Error: guest custom virtio-fs read/write check failed" >&2
        return 1
    fi

    if ! grep -q 'hello from the guest via custom virtio-fs' "$SHARE_DIR/from-guest.txt"; then
        echo "Error: guest write did not appear on host" >&2
        return 1
    fi
}

custom_mount_and_write_before_snapshot() {
    local key
    key="$(ch_find_ssh_key)"
    custom_wait_for_guest

    if ! ch_ssh "$GUEST_IP" "$key" "
        set -e
        mkdir -p $GUEST_MOUNT
        modprobe virtiofs 2>/dev/null || true
        mountpoint -q $GUEST_MOUNT || mount -t virtiofs $FS_TAG $GUEST_MOUNT
        grep -q 'hello from the host via custom virtio-fs' $GUEST_MOUNT/from-host.txt
        printf 'before snapshot via custom virtio-fs\n' > $GUEST_MOUNT/before-snapshot.txt
        sync $GUEST_MOUNT/before-snapshot.txt
        cat $GUEST_MOUNT/from-host.txt
        cat $GUEST_MOUNT/before-snapshot.txt
    "; then
        echo "Error: guest pre-snapshot custom virtio-fs check failed" >&2
        return 1
    fi

    if ! grep -q 'before snapshot via custom virtio-fs' "$SHARE_DIR/before-snapshot.txt"; then
        echo "Error: before-snapshot write did not appear on host" >&2
        return 1
    fi
}

custom_verify_restored_mounted_io() {
    local key
    key="$(ch_find_ssh_key)"
    custom_wait_for_guest

    if ! ch_ssh "$GUEST_IP" "$key" "
        set -e
        if ! mountpoint -q $GUEST_MOUNT; then
            echo '$GUEST_MOUNT is not still mounted after restore' >&2
            findmnt $GUEST_MOUNT >&2 || true
            grep virtiofs /proc/mounts >&2 || true
            exit 1
        fi
        grep -q 'hello from the host via custom virtio-fs' $GUEST_MOUNT/from-host.txt
        grep -q 'before snapshot via custom virtio-fs' $GUEST_MOUNT/before-snapshot.txt
        printf 'after restore via custom virtio-fs\n' > $GUEST_MOUNT/after-restore.txt
        sync $GUEST_MOUNT/after-restore.txt
        cat $GUEST_MOUNT/from-host.txt
        cat $GUEST_MOUNT/before-snapshot.txt
        cat $GUEST_MOUNT/after-restore.txt
    "; then
        echo "Error: guest post-restore mounted custom virtio-fs check failed" >&2
        return 1
    fi

    if ! grep -q 'after restore via custom virtio-fs' "$SHARE_DIR/after-restore.txt"; then
        echo "Error: after-restore write did not appear on host" >&2
        return 1
    fi
}

custom_unmount_guest() {
    local key
    key="$(ch_find_ssh_key)"
    ch_ssh "$GUEST_IP" "$key" "umount $GUEST_MOUNT" >/dev/null 2>&1 || true
}

custom_log_next_line() {
    local lines=0
    if [ -f "$CUSTOM_VIRTIOFSD_LOG" ]; then
        lines="$(wc -l < "$CUSTOM_VIRTIOFSD_LOG")"
    fi
    echo $((lines + 1))
}

custom_assert_log_ops_since() {
    local start_line="$1"
    shift

    local op
    for op in "$@"; do
        if ! tail -n +"$start_line" "$CUSTOM_VIRTIOFSD_LOG" | grep -q "customfs $op"; then
            echo "Error: custom daemon log is missing operation after line $start_line: $op" >&2
            cat "$CUSTOM_VIRTIOFSD_LOG" >&2 || true
            return 1
        fi
    done
}

custom_cleanup_host() {
    custom_remove_fs
    custom_stop_vm || true
    custom_stop_daemon
    sudo rm -f "$API_SOCKET"
    custom_cleanup_tap_and_nat
}
