#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

STATE_DIR="${OVC_STATE_DIR:-/var/tmp/learningMicroVMs-overcommit}"
CGROUP_PARENT="${OVC_CGROUP_PARENT:-/sys/fs/cgroup/learningMicroVMs-overcommit}"

GIB=$((1024 * 1024 * 1024))
MIB=$((1024 * 1024))

POOL_HIGH_BYTES="${OVC_POOL_HIGH_BYTES:-$((8 * GIB))}"
POOL_MAX_BYTES="${OVC_POOL_MAX_BYTES:-$((9 * GIB))}"
POOL_SWAP_MAX_BYTES="${OVC_POOL_SWAP_MAX_BYTES:-$((24 * GIB))}"

SWAP_SIZE_GIB="${OVC_SWAP_SIZE_GIB:-32}"
SWAP_NAME="${OVC_SWAP_NAME:-lmv_overcommit_swap}"
SWAP_BACKING="${OVC_SWAP_BACKING:-$STATE_DIR/secure-swap.img}"
SWAP_LOOP_FILE="$STATE_DIR/secure-swap.loop"
PRIOR_SWAPS_FILE="$STATE_DIR/prior-swaps"

GUEST_MEM_MIB="${OVC_GUEST_MEM_MIB:-6144}"
TOUCH_MIB="${OVC_TOUCH_MIB:-5120}"
SSH_RETRIES="${OVC_SSH_RETRIES:-90}"
HOLD_TIMEOUT_SECONDS="${OVC_HOLD_TIMEOUT_SECONDS:-300}"
MIN_PHASE_SWAP_BYTES="${OVC_MIN_PHASE_SWAP_BYTES:-$((512 * MIB))}"
MIN_FINAL_SWAP_BYTES="${OVC_MIN_FINAL_SWAP_BYTES:-$((8 * GIB))}"

FC_BIN="${OVC_FIRECRACKER_BIN:-$REPO_ROOT/firecracker/firecracker}"
CH_BIN="${OVC_CLOUD_HYPERVISOR_BIN:-$REPO_ROOT/cloud-hypervisor/cloud-hypervisor}"
VM_IDS=(fc0 fc1 ch0 ch1)

usage() {
    cat <<'USAGE'
Usage: ./overcommit-demo/demo.sh <command>

Commands:
  install-deps        Install host packages needed by the demo.
  preflight           Check host, assets, cgroup, and tool availability.
  prepare             Prepare encrypted swap and the shared cgroup pool.
  start               Prepare and boot 2 Firecracker + 2 Cloud Hypervisor VMs.
  prove               Run staged memory pressure proof against already booted VMs.
  watch               Print a live host-side memory table.
  snapshot            Print one host-side memory table.
  stop                Stop workloads/VMs and restore host swap state.
  run                 prepare + start + prove, leaving VMs up for inspection.

Useful environment knobs:
  OVC_TOUCH_MIB=5120
  OVC_SWAP_SIZE_GIB=32
  OVC_POOL_HIGH_BYTES=$((8 * 1024 * 1024 * 1024))
  OVC_POOL_MAX_BYTES=$((9 * 1024 * 1024 * 1024))
  OVC_POOL_SWAP_MAX_BYTES=$((24 * 1024 * 1024 * 1024))
USAGE
}

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

capture_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

write_root_file() {
    local path="$1"
    local value="$2"

    if [ "$(id -u)" -eq 0 ]; then
        printf '%s\n' "$value" > "$path"
    else
        printf '%s\n' "$value" | sudo tee "$path" >/dev/null
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_repo_asset() {
    [ -e "$1" ] || die "missing $1; run the relevant dl_reqs.sh first"
}

human_bytes() {
    local value="${1:-0}"

    if [ "$value" = "max" ]; then
        printf 'max'
    elif command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format='%.1f' "$value"
    else
        awk -v v="$value" 'BEGIN { printf "%.1fGiB", v / 1024 / 1024 / 1024 }'
    fi
}

kib_to_bytes() {
    local value="${1:-0}"
    printf '%s\n' "$((value * 1024))"
}

vm_type() {
    case "$1" in
        fc*) printf 'fc' ;;
        ch*) printf 'ch' ;;
        *) die "unknown VM id: $1" ;;
    esac
}

vm_index() {
    case "$1" in
        fc0) printf '0' ;;
        fc1) printf '1' ;;
        ch0) printf '2' ;;
        ch1) printf '3' ;;
        *) die "unknown VM id: $1" ;;
    esac
}

vm_tap() {
    case "$1" in
        fc0) printf 'ovfc0' ;;
        fc1) printf 'ovfc1' ;;
        ch0) printf 'ovch0' ;;
        ch1) printf 'ovch1' ;;
        *) die "unknown VM id: $1" ;;
    esac
}

vm_octet() {
    printf '%s\n' "$((80 + $(vm_index "$1")))"
}

vm_host_ip() {
    printf '172.31.%s.1\n' "$(vm_octet "$1")"
}

vm_guest_ip() {
    printf '172.31.%s.2\n' "$(vm_octet "$1")"
}

vm_mac() {
    printf '06:00:AC:1F:%02X:02\n' "$(vm_index "$1")"
}

vm_cgroup() {
    printf '%s/%s\n' "$CGROUP_PARENT" "$1"
}

vm_pidfile() {
    printf '%s/pids/%s.pid\n' "$STATE_DIR" "$1"
}

vm_sudo_pidfile() {
    printf '%s/pids/%s.sudo.pid\n' "$STATE_DIR" "$1"
}

vm_socket() {
    printf '%s/sockets/%s.sock\n' "$STATE_DIR" "$1"
}

vm_log() {
    printf '%s/logs/%s.log\n' "$STATE_DIR" "$1"
}

vm_console_log() {
    printf '%s/logs/%s-console.log\n' "$STATE_DIR" "$1"
}

vm_rootfs() {
    printf '%s/rootfs/%s.ext4\n' "$STATE_DIR" "$1"
}

vm_source_rootfs() {
    case "$(vm_type "$1")" in
        fc) printf '%s/firecracker/ubuntu-22.04.ext4\n' "$REPO_ROOT" ;;
        ch) printf '%s/cloud-hypervisor/ubuntu-22.04.ext4\n' "$REPO_ROOT" ;;
    esac
}

vm_kernel() {
    case "$(vm_type "$1")" in
        fc)
            local kernel
            kernel="$(find "$REPO_ROOT/firecracker" -maxdepth 1 -type f -name 'vmlinux-5.10.*' ! -name '*.config' | sort -V | tail -n 1)"
            [ -n "$kernel" ] || die "no Firecracker kernel found in $REPO_ROOT/firecracker"
            printf '%s\n' "$kernel"
            ;;
        ch)
            case "$(uname -m)" in
                x86_64) printf '%s/cloud-hypervisor/vmlinux-x86_64\n' "$REPO_ROOT" ;;
                aarch64) printf '%s/cloud-hypervisor/Image-arm64\n' "$REPO_ROOT" ;;
                *) die "unsupported architecture: $(uname -m)" ;;
            esac
            ;;
    esac
}

vm_ssh_key() {
    case "$(vm_type "$1")" in
        fc) printf '%s/firecracker/ubuntu-22.04.id_rsa\n' "$REPO_ROOT" ;;
        ch) printf '%s/cloud-hypervisor/ubuntu-22.04.id_rsa\n' "$REPO_ROOT" ;;
    esac
}

vm_boot_args() {
    local vm="$1"
    local console="$2"
    local guest_ip host_ip

    guest_ip="$(vm_guest_ip "$vm")"
    host_ip="$(vm_host_ip "$vm")"
    printf '%s root=/dev/vda rw rootwait reboot=k panic=1 net.ifnames=0 biosdevname=0 ip=%s::%s:255.255.255.252::eth0:off' \
        "$console" "$guest_ip" "$host_ip"
}

make_state_dirs() {
    mkdir -p "$STATE_DIR"/{logs,pids,rootfs,sockets,proof}
}

install_deps() {
    if ! command -v apt-get >/dev/null 2>&1; then
        die "install-deps currently supports apt-get hosts; install cryptsetup curl jq iproute2 openssh-client util-linux manually"
    fi

    log "Installing host dependencies"
    run_root apt-get update
    run_root apt-get install -y \
        coreutils \
        cryptsetup \
        curl \
        iproute2 \
        jq \
        openssh-client \
        procps \
        util-linux
}

preflight() {
    require_cmd bash
    require_cmd curl
    require_cmd jq
    require_cmd ssh
    require_cmd ip
    require_cmd awk
    require_cmd sed
    require_cmd fallocate
    require_cmd losetup
    require_cmd mkswap
    require_cmd swapon
    require_cmd swapoff
    require_cmd cryptsetup

    [ -e /dev/kvm ] || die "/dev/kvm is missing"
    [ "$(findmnt -no FSTYPE /sys/fs/cgroup)" = "cgroup2" ] || die "/sys/fs/cgroup is not cgroup v2"
    grep -qw memory /sys/fs/cgroup/cgroup.controllers || die "cgroup v2 memory controller is unavailable"

    require_repo_asset "$REPO_ROOT/firecracker/ubuntu-22.04.ext4"
    require_repo_asset "$REPO_ROOT/firecracker/ubuntu-22.04.id_rsa"
    require_repo_asset "$REPO_ROOT/cloud-hypervisor/ubuntu-22.04.ext4"
    require_repo_asset "$REPO_ROOT/cloud-hypervisor/ubuntu-22.04.id_rsa"
    require_repo_asset "$FC_BIN"
    require_repo_asset "$CH_BIN"

    for vm in "${VM_IDS[@]}"; do
        require_repo_asset "$(vm_kernel "$vm")"
    done

    log "Preflight passed"
}

ensure_firecracker() {
    require_repo_asset "$FC_BIN"
    [ -x "$FC_BIN" ] || die "Firecracker binary is not executable: $FC_BIN"
}

mapper_path() {
    printf '/dev/mapper/%s\n' "$SWAP_NAME"
}

is_active_swap() {
    local target="$1"
    local target_real active active_real

    target_real="$(readlink -f "$target" 2>/dev/null || true)"
    [ -n "$target_real" ] || return 1

    while read -r active; do
        [ -n "$active" ] || continue
        active_real="$(readlink -f "$active" 2>/dev/null || true)"
        if [ "$active_real" = "$target_real" ]; then
            return 0
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    return 1
}

record_prior_swaps_once() {
    if [ ! -e "$PRIOR_SWAPS_FILE" ]; then
        swapon --show=NAME --noheadings > "$PRIOR_SWAPS_FILE" || true
    fi
}

assert_only_encrypted_swap_active() {
    local mapper mapper_real active active_real count

    mapper="$(mapper_path)"
    [ -e "$mapper" ] || die "encrypted swap mapper is missing: $mapper"
    mapper_real="$(readlink -f "$mapper")"
    count=0

    while read -r active; do
        [ -n "$active" ] || continue
        count=$((count + 1))
        active_real="$(readlink -f "$active" 2>/dev/null || true)"
        if [ "$active_real" != "$mapper_real" ]; then
            die "non-demo swap is active ($active); refusing to call this secure swap"
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    [ "$count" -eq 1 ] || die "expected exactly one active swap device, found $count"
}

prepare_secure_swap() {
    local mapper loop ok active active_real mapper_real

    mapper="$(mapper_path)"
    make_state_dirs
    record_prior_swaps_once

    ok=0
    trap 'if [ "$ok" -ne 1 ]; then warn "secure swap setup failed; attempting to restore prior swap state"; restore_prior_swaps || true; fi' RETURN

    mapper_real="$(readlink -f "$mapper" 2>/dev/null || true)"
    while read -r active; do
        [ -n "$active" ] || continue
        active_real="$(readlink -f "$active" 2>/dev/null || true)"
        if [ -n "$mapper_real" ] && [ "$active_real" = "$mapper_real" ]; then
            continue
        fi
        log "Temporarily disabling existing swap: $active"
        run_root swapoff "$active"
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    if is_active_swap "$mapper"; then
        assert_only_encrypted_swap_active
        ok=1
        trap - RETURN
        log "Encrypted swap is already active: $mapper"
        return
    fi

    if [ -e "$mapper" ]; then
        run_root cryptsetup close "$SWAP_NAME" || true
    fi

    log "Creating ${SWAP_SIZE_GIB}GiB encrypted host swap"
    run_root mkdir -p "$(dirname "$SWAP_BACKING")"
    run_root fallocate -l "${SWAP_SIZE_GIB}G" "$SWAP_BACKING"
    run_root chmod 600 "$SWAP_BACKING"

    loop="$(capture_root losetup --find --show "$SWAP_BACKING")"
    printf '%s\n' "$loop" > "$SWAP_LOOP_FILE"

    run_root cryptsetup open \
        --type plain \
        --cipher aes-xts-plain64 \
        --key-size 256 \
        --key-file /dev/urandom \
        "$loop" "$SWAP_NAME"
    run_root mkswap "$mapper"
    run_root swapon "$mapper"

    assert_only_encrypted_swap_active
    ok=1
    trap - RETURN
}

restore_prior_swaps() {
    local mapper loop prior

    mapper="$(mapper_path)"
    if is_active_swap "$mapper"; then
        log "Disabling encrypted demo swap"
        run_root swapoff "$mapper" || true
    fi

    if [ -e "$mapper" ]; then
        run_root cryptsetup close "$SWAP_NAME" || true
    fi

    if [ -s "$SWAP_LOOP_FILE" ]; then
        loop="$(cat "$SWAP_LOOP_FILE")"
        if [ -n "$loop" ]; then
            run_root losetup -d "$loop" 2>/dev/null || true
        fi
        rm -f "$SWAP_LOOP_FILE"
    fi

    if [ -s "$PRIOR_SWAPS_FILE" ]; then
        while read -r prior; do
            [ -n "$prior" ] || continue
            if ! is_active_swap "$prior"; then
                log "Restoring prior swap: $prior"
                run_root swapon "$prior" || warn "could not restore prior swap: $prior"
            fi
        done < "$PRIOR_SWAPS_FILE"
    fi
}

enable_memory_controller() {
    if ! grep -qw memory /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
        write_root_file /sys/fs/cgroup/cgroup.subtree_control '+memory'
    fi
}

prepare_cgroups() {
    local vm cg

    enable_memory_controller
    run_root mkdir -p "$CGROUP_PARENT"

    write_root_file "$CGROUP_PARENT/memory.high" "$POOL_HIGH_BYTES"
    write_root_file "$CGROUP_PARENT/memory.max" "$POOL_MAX_BYTES"
    write_root_file "$CGROUP_PARENT/memory.swap.max" "$POOL_SWAP_MAX_BYTES"
    if [ -e "$CGROUP_PARENT/memory.oom.group" ]; then
        write_root_file "$CGROUP_PARENT/memory.oom.group" 1
    fi

    if ! capture_root grep -qw memory "$CGROUP_PARENT/cgroup.subtree_control" 2>/dev/null; then
        write_root_file "$CGROUP_PARENT/cgroup.subtree_control" '+memory'
    fi

    for vm in "${VM_IDS[@]}"; do
        cg="$(vm_cgroup "$vm")"
        run_root mkdir -p "$cg"
    done

    log "Prepared cgroup pool at $CGROUP_PARENT"
    log "  memory.high=$(human_bytes "$POOL_HIGH_BYTES") memory.max=$(human_bytes "$POOL_MAX_BYTES") memory.swap.max=$(human_bytes "$POOL_SWAP_MAX_BYTES")"
}

prepare() {
    preflight
    ensure_firecracker
    prepare_secure_swap
    prepare_cgroups
}

setup_tap() {
    local vm tap host_ip

    vm="$1"
    tap="$(vm_tap "$vm")"
    host_ip="$(vm_host_ip "$vm")"

    run_root ip link del "$tap" 2>/dev/null || true
    run_root ip tuntap add dev "$tap" mode tap
    run_root ip addr add "${host_ip}/30" dev "$tap"
    run_root ip link set dev "$tap" up
}

delete_taps() {
    local vm tap

    for vm in "${VM_IDS[@]}"; do
        tap="$(vm_tap "$vm")"
        run_root ip link del "$tap" 2>/dev/null || true
    done
}

prepare_rootfs_copy() {
    local vm src dst

    vm="$1"
    src="$(vm_source_rootfs "$vm")"
    dst="$(vm_rootfs "$vm")"

    mkdir -p "$(dirname "$dst")"
    if [ ! -e "$dst" ]; then
        log "Creating rootfs copy for $vm"
        cp --reflink=auto "$src" "$dst"
    fi
}

pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && run_root kill -0 "$pid" 2>/dev/null
}

cgroup_pids() {
    local cg="$1"

    capture_root cat "$cg/cgroup.procs" 2>/dev/null || true
}

find_vm_pid_from_cgroup() {
    local vm="$1"
    local cg socket pid cmdline

    cg="$(vm_cgroup "$vm")"
    socket="$(vm_socket "$vm")"

    for _ in $(seq 1 80); do
        while read -r pid; do
            [ -n "$pid" ] || continue
            [ -e "/proc/$pid/cmdline" ] || continue
            cmdline="$(capture_root cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)"
            if [[ "$cmdline" == *"$socket"* ]]; then
                printf '%s\n' "$pid"
                return 0
            fi
        done < <(cgroup_pids "$cg")
        sleep 0.1
    done

    return 1
}

wait_for_socket() {
    local socket="$1"

    for _ in $(seq 1 100); do
        [ -S "$socket" ] && return 0
        sleep 0.1
    done

    return 1
}

fc_api_put() {
    local socket="$1"
    local path="$2"
    local body="$3"
    local tmp status rc

    tmp="$(mktemp)"
    set +e
    status="$(capture_root curl -sS -o "$tmp" -w '%{http_code}' \
        -X PUT \
        --unix-socket "$socket" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --data-binary "$body" \
        "http://localhost/${path}")"
    rc=$?
    set -e

    if [[ "$status" =~ ^2 ]]; then
        rm -f "$tmp"
        return 0
    fi

    if [ "$rc" -ne 0 ] || [[ ! "$status" =~ ^2 ]]; then
        printf 'Firecracker API PUT /%s failed (status=%s):\n' "$path" "${status:-curl-error}" >&2
        sed -n '1,120p' "$tmp" >&2 || true
        rm -f "$tmp"
        return 1
    fi

    rm -f "$tmp"
}

start_firecracker() {
    local vm socket log_file console_log sudo_pid pid cg kernel rootfs boot_args body tap mac

    vm="$1"
    ensure_firecracker
    socket="$(vm_socket "$vm")"
    log_file="$(vm_log "$vm")"
    console_log="$(vm_console_log "$vm")"
    cg="$(vm_cgroup "$vm")"
    kernel="$(vm_kernel "$vm")"
    rootfs="$(vm_rootfs "$vm")"
    boot_args="$(vm_boot_args "$vm" 'console=ttyS0 pci=off')"
    tap="$(vm_tap "$vm")"
    mac="$(vm_mac "$vm")"

    setup_tap "$vm"
    prepare_rootfs_copy "$vm"
    rm -f "$socket"
    : > "$log_file"
    : > "$console_log"

    log "Starting $vm (Firecracker, ${GUEST_MEM_MIB}MiB)"
    run_root bash -c 'echo $$ > "$1"; console_log="$2"; shift 2; exec "$@" >> "$console_log" 2>&1' \
        overcommit-fc "$cg/cgroup.procs" "$console_log" \
        "$FC_BIN" \
        --api-sock "$socket" \
        --id "$vm" \
        --level Info \
        --log-path "$log_file" \
        --show-level &
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "$(vm_sudo_pidfile "$vm")"

    wait_for_socket "$socket" || die "$vm did not create API socket"
    pid="$(find_vm_pid_from_cgroup "$vm" || true)"
    [ -n "$pid" ] || die "could not find $vm Firecracker PID"
    printf '%s\n' "$pid" > "$(vm_pidfile "$vm")"

    body="$(jq -nc --argjson mem "$GUEST_MEM_MIB" \
        '{vcpu_count:1, mem_size_mib:$mem, smt:false, track_dirty_pages:false}')"
    fc_api_put "$socket" machine-config "$body"

    body="$(jq -nc \
        '{amount_mib:0, deflate_on_oom:true, stats_polling_interval_s:1, free_page_reporting:true}')"
    if ! fc_api_put "$socket" balloon "$body"; then
        warn "$vm Firecracker did not accept free_page_reporting; retrying balloon without it"
        body="$(jq -nc '{amount_mib:0, deflate_on_oom:true, stats_polling_interval_s:1}')"
        fc_api_put "$socket" balloon "$body"
    fi

    body="$(jq -nc --arg kernel "$kernel" --arg args "$boot_args" \
        '{kernel_image_path:$kernel, boot_args:$args}')"
    fc_api_put "$socket" boot-source "$body"

    body="$(jq -nc --arg path "$rootfs" \
        '{drive_id:"rootfs", path_on_host:$path, is_root_device:true, is_read_only:false}')"
    fc_api_put "$socket" drives/rootfs "$body"

    body="$(jq -nc --arg mac "$mac" --arg tap "$tap" \
        '{iface_id:"eth0", guest_mac:$mac, host_dev_name:$tap}')"
    fc_api_put "$socket" network-interfaces/eth0 "$body"

    sleep 0.05
    fc_api_put "$socket" actions '{"action_type":"InstanceStart"}'
}

cloud_hypervisor_memory_arg() {
    local mem_arg

    mem_arg="size=${GUEST_MEM_MIB}M,prefault=off,thp=off"
    if "$CH_BIN" --help 2>&1 | grep -q 'reserve=on|off'; then
        mem_arg="${mem_arg},reserve=off"
    fi

    printf '%s\n' "$mem_arg"
}

start_cloud_hypervisor() {
    local vm socket log_file console_log sudo_pid pid cg kernel rootfs boot_args tap mac memory_arg

    vm="$1"
    socket="$(vm_socket "$vm")"
    log_file="$(vm_log "$vm")"
    console_log="$(vm_console_log "$vm")"
    cg="$(vm_cgroup "$vm")"
    kernel="$(vm_kernel "$vm")"
    rootfs="$(vm_rootfs "$vm")"
    boot_args="$(vm_boot_args "$vm" 'console=ttyS0')"
    tap="$(vm_tap "$vm")"
    mac="$(vm_mac "$vm")"
    memory_arg="$(cloud_hypervisor_memory_arg)"

    setup_tap "$vm"
    prepare_rootfs_copy "$vm"
    rm -f "$socket"
    : > "$log_file"
    : > "$console_log"

    log "Starting $vm (Cloud Hypervisor, ${GUEST_MEM_MIB}MiB)"
    run_root bash -c 'echo $$ > "$1"; shift; exec "$@"' \
        overcommit-ch "$cg/cgroup.procs" \
        "$CH_BIN" \
        --kernel "$kernel" \
        --cmdline "$boot_args" \
        --disk "path=${rootfs},readonly=off" \
        --cpus boot=1 \
        --memory "$memory_arg" \
        --balloon size=0,free_page_reporting=on \
        --net "tap=${tap},mac=${mac}" \
        --api-socket "path=${socket}" \
        --serial "file=${console_log}" \
        --console off \
        --log-file "$log_file" &
    sudo_pid="$!"
    printf '%s\n' "$sudo_pid" > "$(vm_sudo_pidfile "$vm")"

    sleep 0.5
    pid="$(find_vm_pid_from_cgroup "$vm" || true)"
    [ -n "$pid" ] || {
        tail -n 80 "$log_file" >&2 || true
        tail -n 80 "$console_log" >&2 || true
        die "could not find $vm Cloud Hypervisor PID"
    }
    printf '%s\n' "$pid" > "$(vm_pidfile "$vm")"

    if ! pid_alive "$pid"; then
        tail -n 80 "$log_file" >&2 || true
        tail -n 80 "$console_log" >&2 || true
        die "$vm Cloud Hypervisor exited early"
    fi
}

ssh_run() {
    local vm="$1"
    shift

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$(vm_ssh_key "$vm")" \
        "root@$(vm_guest_ip "$vm")" \
        "$@"
}

wait_for_ssh() {
    local vm="$1"

    for _ in $(seq 1 "$SSH_RETRIES"); do
        if ssh_run "$vm" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

configure_guest() {
    local vm host_ip

    vm="$1"
    host_ip="$(vm_host_ip "$vm")"

    log "Waiting for SSH on $vm ($(vm_guest_ip "$vm"))"
    wait_for_ssh "$vm" || die "SSH did not become ready for $vm"

    ssh_run "$vm" "ip route replace default via $host_ip dev eth0 || true; swapoff -a || true; sysctl -w vm.swappiness=0 >/dev/null 2>&1 || true"
}

start_vms() {
    local vm

    stop_vms_only
    preflight
    ensure_firecracker
    prepare_secure_swap
    prepare_cgroups

    for vm in "${VM_IDS[@]}"; do
        case "$(vm_type "$vm")" in
            fc) start_firecracker "$vm" ;;
            ch) start_cloud_hypervisor "$vm" ;;
        esac
    done

    for vm in "${VM_IDS[@]}"; do
        configure_guest "$vm"
    done

    log "All VMs are running"
    snapshot
}

stop_workload() {
    local vm

    for vm in "$@"; do
        if ! pid_alive "$(vm_pid "$vm")"; then
            continue
        fi
        if ssh_run "$vm" true >/dev/null 2>&1; then
            ssh_run "$vm" "if [ -f /tmp/overcommit-touch.pid ]; then kill \$(cat /tmp/overcommit-touch.pid) 2>/dev/null || true; fi; pkill -f /tmp/overcommit-touch.py 2>/dev/null || true; rm -f /tmp/overcommit-touch.pid" >/dev/null 2>&1 || true
        fi
    done
}

stop_all_workloads() {
    stop_workload "${VM_IDS[@]}"
}

install_guest_toucher() {
    local vm="$1"

    ssh_run "$vm" 'cat > /tmp/overcommit-touch.py' <<'PY'
import mmap
import os
import sys
import time

mib = int(sys.argv[1])
size = mib * 1024 * 1024
page = os.sysconf("SC_PAGE_SIZE")
step_report = 256 * 1024 * 1024

buf = mmap.mmap(-1, size)
print(f"allocated {mib} MiB", flush=True)

next_report = 0
for offset in range(0, size, page):
    buf[offset:offset + 1] = b"x"
    if offset >= next_report:
        print(f"touched {offset // (1024 * 1024)} MiB", flush=True)
        next_report += step_report

print("holding", flush=True)

while True:
    # Sparse pulse: keep the process alive without making the whole set hot.
    checksum = 0
    for offset in range(0, size, 64 * 1024 * 1024):
        checksum ^= buf[offset]
    time.sleep(5)
PY
}

start_workload() {
    local vm="$1"
    local mib="$2"

    install_guest_toucher "$vm"
    ssh_run "$vm" "rm -f /tmp/overcommit-touch.log; nohup python3 /tmp/overcommit-touch.py $mib > /tmp/overcommit-touch.log 2>&1 < /dev/null & echo \$! > /tmp/overcommit-touch.pid"
}

wait_workloads_holding() {
    local deadline vm all_ready

    deadline=$((SECONDS + HOLD_TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        all_ready=1
        for vm in "$@"; do
            if ! ssh_run "$vm" "grep -q '^holding$' /tmp/overcommit-touch.log" >/dev/null 2>&1; then
                all_ready=0
                break
            fi
        done
        if [ "$all_ready" -eq 1 ]; then
            return 0
        fi
        sleep 5
    done

    for vm in "$@"; do
        warn "$vm workload log:"
        ssh_run "$vm" "tail -n 40 /tmp/overcommit-touch.log || true" >&2 || true
    done
    return 1
}

cgroup_value() {
    local cg="$1"
    local file="$2"

    capture_root cat "$cg/$file" 2>/dev/null || printf '0\n'
}

cgroup_stat_value() {
    local cg="$1"
    local key="$2"

    capture_root awk -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print 0 }' "$cg/memory.stat" 2>/dev/null || printf '0\n'
}

vm_pid() {
    local file

    file="$(vm_pidfile "$1")"
    [ -s "$file" ] && cat "$file" || true
}

proc_status_kib() {
    local pid="$1"
    local key="$2"

    awk -v key="$key" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' "/proc/$pid/status" 2>/dev/null || printf '0\n'
}

smaps_rollup_kib() {
    local pid="$1"
    local key="$2"

    awk -v key="$key" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' "/proc/$pid/smaps_rollup" 2>/dev/null || printf '0\n'
}

guest_memtotal_bytes() {
    local vm="$1"
    local kib

    kib="$(ssh_run "$vm" "awk '/^MemTotal:/ { print \$2 }' /proc/meminfo" 2>/dev/null || printf '0\n')"
    kib_to_bytes "${kib:-0}"
}

guest_swap_summary() {
    local vm="$1"

    ssh_run "$vm" "awk '/^SwapTotal:/ { total=\$2 } /^SwapFree:/ { free=\$2 } END { printf \"%s/%s KiB\", total+0, free+0 }' /proc/meminfo" 2>/dev/null || printf 'unavailable'
}

print_parent_snapshot() {
    local current swap_current events pressure

    if [ ! -d "$CGROUP_PARENT" ]; then
        printf 'parent cgroup missing: %s\n' "$CGROUP_PARENT"
        return
    fi

    current="$(cgroup_value "$CGROUP_PARENT" memory.current)"
    swap_current="$(cgroup_value "$CGROUP_PARENT" memory.swap.current)"
    events="$(capture_root cat "$CGROUP_PARENT/memory.events" 2>/dev/null | tr '\n' ' ' || true)"
    pressure="$(capture_root cat "$CGROUP_PARENT/memory.pressure" 2>/dev/null | tr '\n' ' ' || true)"

    printf 'POOL current=%s high=%s max=%s swap.current=%s swap.max=%s\n' \
        "$(human_bytes "$current")" \
        "$(human_bytes "$POOL_HIGH_BYTES")" \
        "$(human_bytes "$POOL_MAX_BYTES")" \
        "$(human_bytes "$swap_current")" \
        "$(human_bytes "$POOL_SWAP_MAX_BYTES")"
    printf 'POOL events: %s\n' "$events"
    printf 'POOL pressure: %s\n' "$pressure"
}

snapshot() {
    local vm pid cg mem_current swap_current peak swap_peak anon pgmaj
    local vm_size vm_rss vm_swap smaps_rss smaps_anon smaps_swap guest_mem

    print_parent_snapshot
    printf '\n'
    printf '%-4s %-3s %-7s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-8s %-13s\n' \
        VM TYPE PID GuestMem VmSize VmRSS VmSwap CgMem CgSwap CgPeak CgSwPeak Anon MajFlt GuestSwap

    for vm in "${VM_IDS[@]}"; do
        pid="$(vm_pid "$vm")"
        cg="$(vm_cgroup "$vm")"
        if [ -z "$pid" ] || [ ! -e "/proc/$pid/status" ]; then
            printf '%-4s %-3s %-7s %s\n' "$vm" "$(vm_type "$vm")" "-" "not-running"
            continue
        fi

        guest_mem="$(guest_memtotal_bytes "$vm")"
        vm_size="$(kib_to_bytes "$(proc_status_kib "$pid" VmSize)")"
        vm_rss="$(kib_to_bytes "$(proc_status_kib "$pid" VmRSS)")"
        vm_swap="$(kib_to_bytes "$(proc_status_kib "$pid" VmSwap)")"
        smaps_rss="$(kib_to_bytes "$(smaps_rollup_kib "$pid" Rss)")"
        smaps_anon="$(kib_to_bytes "$(smaps_rollup_kib "$pid" Anonymous)")"
        smaps_swap="$(kib_to_bytes "$(smaps_rollup_kib "$pid" Swap)")"
        mem_current="$(cgroup_value "$cg" memory.current)"
        swap_current="$(cgroup_value "$cg" memory.swap.current)"
        peak="$(cgroup_value "$cg" memory.peak)"
        swap_peak="$(cgroup_value "$cg" memory.swap.peak)"
        anon="$(cgroup_stat_value "$cg" anon)"
        pgmaj="$(cgroup_stat_value "$cg" pgmajfault)"

        # smaps values are read to make /proc/$PID/smaps_rollup part of the audit;
        # the table keeps the process-status fields prominent for compactness.
        : "$smaps_rss" "$smaps_anon" "$smaps_swap"

        printf '%-4s %-3s %-7s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-8s %-13s\n' \
            "$vm" "$(vm_type "$vm")" "$pid" \
            "$(human_bytes "$guest_mem")" \
            "$(human_bytes "$vm_size")" \
            "$(human_bytes "$vm_rss")" \
            "$(human_bytes "$vm_swap")" \
            "$(human_bytes "$mem_current")" \
            "$(human_bytes "$swap_current")" \
            "$(human_bytes "$peak")" \
            "$(human_bytes "$swap_peak")" \
            "$(human_bytes "$anon")" \
            "$pgmaj" \
            "$(guest_swap_summary "$vm")"
    done
}

watch_loop() {
    while true; do
        clear || true
        date
        snapshot
        sleep "${OVC_WATCH_INTERVAL:-2}"
    done
}

sum_swap_for() {
    local total vm

    total=0
    for vm in "$@"; do
        total=$((total + $(cgroup_value "$(vm_cgroup "$vm")" memory.swap.current)))
    done
    printf '%s\n' "$total"
}

assert_all_vms_ready() {
    local vm guest_mem min_mem

    min_mem=$((5 * GIB))
    for vm in "${VM_IDS[@]}"; do
        pid_alive "$(vm_pid "$vm")" || die "$vm is not running"
        wait_for_ssh "$vm" || die "$vm is not SSH-responsive"
        guest_mem="$(guest_memtotal_bytes "$vm")"
        if [ "$guest_mem" -lt "$min_mem" ]; then
            die "$vm guest MemTotal is too small: $(human_bytes "$guest_mem")"
        fi
    done
}

prove_phase() {
    local name min_swap swap_sum vm

    name="$1"
    shift
    min_swap="$1"
    shift

    log "Phase: $name"
    stop_all_workloads
    sleep 3

    for vm in "$@"; do
        log "Starting ${TOUCH_MIB}MiB toucher in $vm"
        start_workload "$vm" "$TOUCH_MIB"
    done

    wait_workloads_holding "$@" || die "workloads did not reach holding state in phase: $name"
    sleep "${OVC_POST_HOLD_SETTLE_SECONDS:-20}"
    snapshot

    swap_sum="$(sum_swap_for "$@")"
    if [ "$swap_sum" -lt "$min_swap" ]; then
        die "$name did not produce enough host cgroup swap: got $(human_bytes "$swap_sum"), wanted at least $(human_bytes "$min_swap")"
    fi

    for vm in "$@"; do
        ssh_run "$vm" true >/dev/null 2>&1 || die "$vm lost SSH responsiveness during $name"
    done

    log "$name passed with $(human_bytes "$swap_sum") swap across participating VMs"
}

prove() {
    local parent_current parent_swap

    assert_only_encrypted_swap_active
    assert_all_vms_ready

    log "Configured visible guest RAM: 4 * ${GUEST_MEM_MIB}MiB = $(human_bytes "$((4 * GUEST_MEM_MIB * MIB))")"
    log "Resident pool hard cap: $(human_bytes "$POOL_MAX_BYTES")"
    log "Guest workload per VM: ${TOUCH_MIB}MiB"

    prove_phase "Cloud Hypervisor only" "$MIN_PHASE_SWAP_BYTES" ch0 ch1
    prove_phase "Firecracker only" "$MIN_PHASE_SWAP_BYTES" fc0 fc1
    prove_phase "All four VMs" "$MIN_FINAL_SWAP_BYTES" "${VM_IDS[@]}"

    parent_current="$(cgroup_value "$CGROUP_PARENT" memory.current)"
    parent_swap="$(cgroup_value "$CGROUP_PARENT" memory.swap.current)"

    if [ "$parent_current" -gt "$POOL_MAX_BYTES" ]; then
        die "parent memory.current exceeded memory.max: $(human_bytes "$parent_current") > $(human_bytes "$POOL_MAX_BYTES")"
    fi

    if [ "$parent_swap" -lt "$MIN_FINAL_SWAP_BYTES" ]; then
        die "parent swap.current too low for proof: $(human_bytes "$parent_swap")"
    fi

    log "PROOF PASSED"
    log "  parent memory.current=$(human_bytes "$parent_current") <= memory.max=$(human_bytes "$POOL_MAX_BYTES")"
    log "  parent memory.swap.current=$(human_bytes "$parent_swap")"
    log "  FC and CH both demonstrated cgroup swap in their staged phases"
}

stop_vms_only() {
    local vm pid sudo_pid file cg

    stop_all_workloads || true

    for vm in "${VM_IDS[@]}"; do
        cg="$(vm_cgroup "$vm")"
        while read -r pid; do
            [ -n "$pid" ] || continue
            if pid_alive "$pid"; then
                log "Stopping $vm cgroup pid $pid"
                run_root kill "$pid" 2>/dev/null || true
            fi
        done < <(cgroup_pids "$cg")

        for _ in $(seq 1 40); do
            if [ -z "$(cgroup_pids "$cg" | tr -d '[:space:]')" ]; then
                break
            fi
            sleep 0.25
        done

        while read -r pid; do
            [ -n "$pid" ] || continue
            if pid_alive "$pid"; then
                run_root kill -9 "$pid" 2>/dev/null || true
            fi
        done < <(cgroup_pids "$cg")

        file="$(vm_pidfile "$vm")"
        if [ -s "$file" ]; then
            pid="$(cat "$file")"
            if pid_alive "$pid"; then
                log "Stopping $vm pid $pid"
                run_root kill "$pid" 2>/dev/null || true
                for _ in $(seq 1 40); do
                    pid_alive "$pid" || break
                    sleep 0.25
                done
                if pid_alive "$pid"; then
                    run_root kill -9 "$pid" 2>/dev/null || true
                fi
            fi
        fi

        file="$(vm_sudo_pidfile "$vm")"
        if [ -s "$file" ]; then
            sudo_pid="$(cat "$file")"
            run_root kill "$sudo_pid" 2>/dev/null || true
        fi

        rm -f "$(vm_pidfile "$vm")" "$(vm_sudo_pidfile "$vm")" "$(vm_socket "$vm")"
    done

    delete_taps
}

remove_cgroups() {
    local vm cg

    for vm in "${VM_IDS[@]}"; do
        cg="$(vm_cgroup "$vm")"
        run_root rmdir "$cg" 2>/dev/null || true
    done
    run_root rmdir "$CGROUP_PARENT" 2>/dev/null || true
}

stop_all() {
    stop_vms_only
    remove_cgroups
    restore_prior_swaps
    log "Stopped demo. Runtime files remain in $STATE_DIR for log inspection."
}

run_all() {
    start_vms
    prove
}

cmd="${1:-}"
case "$cmd" in
    install-deps)
        install_deps
        ;;
    preflight)
        preflight
        ;;
    prepare)
        prepare
        ;;
    start)
        start_vms
        ;;
    prove)
        prove
        ;;
    watch)
        watch_loop
        ;;
    snapshot)
        snapshot
        ;;
    stop)
        stop_all
        ;;
    run)
        run_all
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        usage >&2
        die "unknown command: $cmd"
        ;;
esac
