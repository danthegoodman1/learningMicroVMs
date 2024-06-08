rm -rf rootfs
mkdir rootfs
docker export $(docker create ubuntu) | tar -C rootfs -xf -
