rm -rf rootfs
mkdir --mode=0755 rootfs
docker export $(docker create hello-world) | sudo tar -xf - -C rootfs --same-owner --same-permissions

runsc spec -- /hello

sudo runsc run hello
