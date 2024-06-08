sudo setcap cap_net_admin+ep ./cloud-hypervisor
cloud-hypervisor \
	--kernel ./vmlinux-5.10.217 \
	--disk path=./rootfs.ext4 \
	--cmdline "console=hvc0 root=/dev/vda1 rw" \
	--cpus boot=2 \
	--memory size=1024M \
	--net "tap=,mac=,ip=,mask="
