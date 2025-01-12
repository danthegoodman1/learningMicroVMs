echo "Adding CRIU PPA and installing..."
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update
sudo apt-get install -y criu podman

echo installing deno
curl -fsSL https://deno.land/install.sh | sh
