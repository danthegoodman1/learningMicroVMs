docker build -t rust-static-app .

# Run the container and extract the filesystem
container_id=$(docker create rust-static-app)
docker export "$container_id" | cpio -o -H newc > unikernel.cpio
docker rm "$container_id"
