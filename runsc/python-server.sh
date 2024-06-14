# Need to see https://gvisor.dev/docs/tutorials/cni/ for networking, but this launches something long-running

rm -rf rootfs
rm config.json
sudo mkdir rootfs
sudo docker export $(docker create python) | sudo tar --same-owner -pxf - -C rootfs
sudo mkdir -p rootfs/var/www/html
sudo sh -c 'echo "Hello World!" > rootfs/var/www/html/index.html'

runsc spec -- python -m http.server

sudo runsc run -detach -pid-file pid.txt server
