#!/bin/bash
# Re-enables, on top of trim.sh, what a general-purpose Linux VM needs:
# firewalling, IPv6, container and overlay networking, BPF, loop devices,
# more filesystems, hugetlbfs, and PCI hotplug.
# usage: trim-full.sh <config> [mitigations]
set -e
C="scripts/config --file $1"
# Firewalling: nftables plus the iptables (legacy and nft) interfaces
$C -e NETFILTER -e NETFILTER_ADVANCED -e NF_CONNTRACK -e NF_NAT -e NF_TABLES -e NF_TABLES_INET -e NF_TABLES_IPV4 -e NF_TABLES_IPV6 \
   -e NFT_CT -e NFT_NAT -e NFT_MASQ -e NFT_REDIR -e NFT_REJECT -e NFT_COMPAT -e NFT_LIMIT -e NFT_LOG \
   -e NETFILTER_XTABLES -e NETFILTER_XT_MARK -e NETFILTER_XT_MATCH_CONNTRACK -e NETFILTER_XT_MATCH_ADDRTYPE \
   -e NETFILTER_XT_MATCH_COMMENT -e NETFILTER_XT_MATCH_MULTIPORT -e NETFILTER_XT_TARGET_MASQUERADE \
   -e IP_NF_IPTABLES -e IP_NF_FILTER -e IP_NF_NAT -e IP_NF_MANGLE -e IP_NF_TARGET_MASQUERADE -e IP_NF_TARGET_REJECT \
   -e IP6_NF_IPTABLES -e IP6_NF_FILTER -e IP6_NF_NAT -e IP6_NF_MANGLE -e IP6_NF_TARGET_MASQUERADE -e IP6_NF_TARGET_REJECT
# Networking for containers, overlays and VPNs
$C -e IPV6 -e BRIDGE -e BRIDGE_NETFILTER -e VETH -e TUN -e VXLAN -e WIREGUARD -e VLAN_8021Q -e MACVLAN -e IPVLAN -e DUMMY \
   -e IP_ADVANCED_ROUTER -e IP_MULTIPLE_TABLES -e NET_SCHED -e NET_SCH_FQ_CODEL -e NET_SCH_HTB -e NET_CLS_BPF -e NET_ACT_BPF
# BPF (systemd, Cilium, bpftrace-style tooling). The JIT needs module support.
$C -e MODULES -e MODULE_UNLOAD -e BPF_SYSCALL -e BPF_JIT -e CGROUP_BPF
# Storage: loop devices created on demand, more filesystems, hugetlbfs
$C -e BLK_DEV_LOOP --set-val BLK_DEV_LOOP_MIN_COUNT 0 -e XFS_FS -e EROFS_FS -e EROFS_FS_ZIP -e SQUASHFS -e SQUASHFS_ZSTD \
   -e HUGETLBFS -e HUGETLB_PAGE
# Hot-added PCI devices (Cloud Hypervisor vm.add-disk and friends)
$C -e HOTPLUG_PCI -e HOTPLUG_PCI_ACPI
if [ "$2" = "mitigations" ]; then
  $C -e SPECULATION_MITIGATIONS -e PAGE_TABLE_ISOLATION -e RETPOLINE -e RETHUNK -e CPU_UNRET_ENTRY -e CPU_IBPB_ENTRY \
     -e CPU_IBRS_ENTRY -e CPU_SRSO -e SLS -e MITIGATION_RFDS
fi
