echo "Adding CRIU PPA and installing..."
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update
sudo apt-get install -y criu

sudo apt-get update && \
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg

curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

sudo apt-get update && sudo apt-get install -y runsc

curl -fsSL https://get.docker.com | sh

docker build -t serv .

rm -rf rootfs
mkdir rootfs
# this command is slow on both sides, far longer than starting a new docker container
time sudo docker export $(docker create serv) | sudo tar --same-owner -pxf - -C rootfs
