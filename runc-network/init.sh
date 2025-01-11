echo "Adding CRIU PPA and installing..."
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update
sudo apt-get install -y criu

docker build -t serv .

rm -rf rootfs
rm config.json
runc spec
mkdir rootfs
# this command is slow on both sides, far longer than starting a new docker container
time sudo docker export $(docker create serv) | sudo tar --same-owner -pxf - -C rootfs
