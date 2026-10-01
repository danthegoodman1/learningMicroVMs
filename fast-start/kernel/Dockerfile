FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential flex bison libelf-dev libssl-dev bc cpio python3 kmod dwarves && rm -rf /var/lib/apt/lists/*
