#!/bin/bash

CONTAINER_ID="demo"

echo "Making folder..."
mkdir --mode=0755 rootfs

# Export the image and extract it to our container rootfs
echo "Exporting and extracting image..."
sudo docker export $(docker create python:3.12) | sudo tar --same-owner -pxf - -C rootfs

# Create the container spec
echo "Creating container spec..."
runsc spec -- /bin/bash

echo "Running container..."
echo "In another terminal, run sudo runsc checkpoint -image-path ckpt $CONTAINER_ID; sudo runsc create $CONTAINER_ID; sudo runsc restore -image-path ckpt $CONTAINER_ID"
echo "do this after something in the repl like a = 42"
# can optionally leave it running when checkpointing
# sudo runsc run -detach -pid-file pid.txt $CONTAINER_ID
sudo runsc run $CONTAINER_ID