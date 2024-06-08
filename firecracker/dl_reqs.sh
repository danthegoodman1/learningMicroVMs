ARCH="$(uname -m)"

# Download a linux kernel binary
wget https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.9/${ARCH}/vmlinux-5.10.217

# Download a rootfs
wget https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.9/${ARCH}/ubuntu-22.04.ext4

# Download the ssh key for the rootfs
wget https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.9/${ARCH}/ubuntu-22.04.id_rsa

# Set user read permission on the ssh key
chmod 400 ./ubuntu-22.04.id_rsa
