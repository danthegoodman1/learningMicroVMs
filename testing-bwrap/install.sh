echo installing bubblewrap
sudo apt update && sudo apt install bubblewrap slirp4netns unzip -y

echo installing deno
curl -fsSL https://deno.land/install.sh | sh
