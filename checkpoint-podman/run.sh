# Add CRIU PPA and install
echo "Adding CRIU PPA and installing..."
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update
sudo apt-get install -y criu podman

echo "Building the container"
buildah build -t serv .
echo "Running the container"
podman run -d -p 8080:8080 --name serv serv

echo "Sleeping for 1 second"
sleep 1

echo incrementing the counter
curl http://localhost:8080
curl http://localhost:8080
curl http://localhost:8080
curl http://localhost:8080

echo checkpointing the container
podman container checkpoint --export=checkpoint.tar --tcp-established --file-locks serv

echo "Removing the container"
podman container rm serv

echo "Restoring the container"
podman container restore --tcp-established --file-locks -p 8080:8080 --import=checkpoint.tar

echo "Sleeping for 1 second"
sleep 1

echo curling
curl http://localhost:8080

echo removing the checkpoint
rm -rf checkpoint.tar
