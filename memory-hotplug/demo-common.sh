#!/usr/bin/env bash

# Shared policy loop for the Firecracker and Cloud Hypervisor demos. Each
# runner supplies guest_exec() and resize_to_peak().

: "${BASE_MEMORY_MIB:=4096}"
: "${PEAK_MEMORY_MIB:=6144}"
: "${TRIGGER_USED_MIB:=2048}"
: "${WORKLOAD_MIB:=2560}"
: "${WORKLOAD_HOLD_SECONDS:=120}"
: "${POLL_INTERVAL_SECONDS:=1}"
: "${DEMO_TIMEOUT_SECONDS:=90}"

demo_require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        return 1
    fi
}

demo_validate_settings() {
    local name value
    for name in \
        BASE_MEMORY_MIB PEAK_MEMORY_MIB TRIGGER_USED_MIB WORKLOAD_MIB \
        WORKLOAD_HOLD_SECONDS DEMO_TIMEOUT_SECONDS; do
        value="${!name}"
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            echo "Error: $name must be an integer, got: $value" >&2
            return 1
        fi
    done

    if [ "$PEAK_MEMORY_MIB" -le "$BASE_MEMORY_MIB" ]; then
        echo "Error: PEAK_MEMORY_MIB must be larger than BASE_MEMORY_MIB" >&2
        return 1
    fi
    if [ "$TRIGGER_USED_MIB" -ge "$BASE_MEMORY_MIB" ]; then
        echo "Error: TRIGGER_USED_MIB must be below BASE_MEMORY_MIB" >&2
        return 1
    fi
    if [ "$WORKLOAD_MIB" -le "$TRIGGER_USED_MIB" ]; then
        echo "Error: WORKLOAD_MIB must exceed TRIGGER_USED_MIB" >&2
        return 1
    fi
}

demo_setup_tap() {
    local tap_dev="$1"
    local tap_ip="$2"
    local tap_cidr="$3"
    local host_iface

    host_iface="${HOST_IFACE:-$(ip route show default | awk 'NR == 1 {print $5}')}"
    if [ -z "$host_iface" ]; then
        echo "Error: could not determine the host's default network interface" >&2
        return 1
    fi
    DEMO_HOST_IFACE="$host_iface"

    sudo ip link del "$tap_dev" 2>/dev/null || true
    sudo ip tuntap add dev "$tap_dev" mode tap user "$(id -un)"
    sudo ip addr add "${tap_ip}/30" dev "$tap_dev"
    sudo ip link set dev "$tap_dev" up
    sudo sysctl -q -w net.ipv4.ip_forward=1

    sudo iptables -t nat -C POSTROUTING -s "$tap_cidr" -o "$host_iface" -j MASQUERADE 2>/dev/null \
        || sudo iptables -t nat -A POSTROUTING -s "$tap_cidr" -o "$host_iface" -j MASQUERADE
    sudo iptables -C FORWARD -i "$tap_dev" -o "$host_iface" -j ACCEPT 2>/dev/null \
        || sudo iptables -I FORWARD 1 -i "$tap_dev" -o "$host_iface" -j ACCEPT
    sudo iptables -C FORWARD -i "$host_iface" -o "$tap_dev" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || sudo iptables -I FORWARD 1 -i "$host_iface" -o "$tap_dev" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

demo_cleanup_tap() {
    local tap_dev="$1"
    local tap_cidr="$2"

    if [ -n "${DEMO_HOST_IFACE:-}" ]; then
        sudo iptables -t nat -D POSTROUTING -s "$tap_cidr" \
            -o "$DEMO_HOST_IFACE" -j MASQUERADE 2>/dev/null || true
        sudo iptables -D FORWARD -i "$tap_dev" \
            -o "$DEMO_HOST_IFACE" -j ACCEPT 2>/dev/null || true
        sudo iptables -D FORWARD -i "$DEMO_HOST_IFACE" -o "$tap_dev" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
    sudo ip link del "$tap_dev" 2>/dev/null || true
}

demo_ssh() {
    local ip="$1"
    local key="$2"
    shift 2

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$key" \
        "root@${ip}" \
        "$@"
}

demo_wait_for_ssh() {
    local ip="$1"
    local key="$2"
    local deadline=$((SECONDS + DEMO_TIMEOUT_SECONDS))

    echo "Waiting for guest SSH..."
    while [ "$SECONDS" -lt "$deadline" ]; do
        if demo_ssh "$ip" "$key" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Error: SSH did not become ready on $ip" >&2
    return 1
}

demo_configure_guest_network() {
    local gateway="$1"
    guest_exec "ip route replace default via $gateway dev eth0"
}

demo_guest_total_mib() {
    guest_exec "awk '/^MemTotal:/ {printf \"%d\\n\", \$2 / 1024}' /proc/meminfo"
}

demo_guest_used_mib() {
    guest_exec "awk '
        /^MemTotal:/ {total = \$2}
        /^MemAvailable:/ {available = \$2}
        END {printf \"%d\\n\", (total - available) / 1024}
    ' /proc/meminfo"
}

demo_start_workload() {
    local python_code command

    guest_exec "command -v python3 >/dev/null"
    python_code="import os, time; size = ${WORKLOAD_MIB} * 1024 * 1024; buf = bytearray(size); [(buf.__setitem__(offset, 1)) for offset in range(0, size, 4096)]; print(\"allocated_mib=${WORKLOAD_MIB} pid=%d\" % os.getpid(), flush=True); time.sleep(${WORKLOAD_HOLD_SECONDS})"
    command="rm -f /tmp/memory-hotplug-demo.pid /tmp/memory-hotplug-demo.log; nohup python3 -c '$python_code' >/tmp/memory-hotplug-demo.log 2>&1 </dev/null & echo \$! >/tmp/memory-hotplug-demo.pid"
    guest_exec "$command"
}

demo_stop_workload() {
    guest_exec 'if [ -f /tmp/memory-hotplug-demo.pid ]; then kill "$(cat /tmp/memory-hotplug-demo.pid)" 2>/dev/null || true; fi; rm -f /tmp/memory-hotplug-demo.pid' \
        >/dev/null 2>&1 || true
}

demo_wait_for_threshold() {
    local deadline=$((SECONDS + DEMO_TIMEOUT_SECONDS))
    local used_mib

    echo "Waiting for guest usage to cross ${TRIGGER_USED_MIB} MiB..."
    while [ "$SECONDS" -lt "$deadline" ]; do
        used_mib="$(demo_guest_used_mib)"
        printf '  used=%s MiB\n' "$used_mib"
        if [ "$used_mib" -gt "$TRIGGER_USED_MIB" ]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done

    echo "Error: guest usage never crossed ${TRIGGER_USED_MIB} MiB" >&2
    guest_exec "cat /tmp/memory-hotplug-demo.log" >&2 || true
    return 1
}

demo_wait_for_memory_growth() {
    local before_total_mib="$1"
    local expected_growth_mib=$((PEAK_MEMORY_MIB - BASE_MEMORY_MIB))
    local minimum_growth_mib=$((expected_growth_mib - 128))
    local deadline=$((SECONDS + DEMO_TIMEOUT_SECONDS))
    local total_mib growth_mib

    while [ "$SECONDS" -lt "$deadline" ]; do
        total_mib="$(demo_guest_total_mib)"
        growth_mib=$((total_mib - before_total_mib))
        printf '  guest total=%s MiB (growth=%s MiB)\n' "$total_mib" "$growth_mib"
        if [ "$growth_mib" -ge "$minimum_growth_mib" ]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done

    echo "Error: guest memory did not grow by approximately ${expected_growth_mib} MiB" >&2
    return 1
}

demo_run_policy() {
    local before_total_mib after_total_mib used_mib

    before_total_mib="$(demo_guest_total_mib)"
    echo "Guest started with ${before_total_mib} MiB visible RAM."
    echo "Starting a ${WORKLOAD_MIB} MiB guest allocation..."
    demo_start_workload
    demo_wait_for_threshold

    used_mib="$(demo_guest_used_mib)"
    echo "Threshold crossed at ${used_mib} MiB; requesting ${PEAK_MEMORY_MIB} MiB..."
    resize_to_peak
    demo_wait_for_memory_growth "$before_total_mib"

    after_total_mib="$(demo_guest_total_mib)"
    echo
    echo "Success: guest RAM grew from ${before_total_mib} MiB to ${after_total_mib} MiB."
    echo "The policy loop—not the VMM—made the scaling decision."
}
