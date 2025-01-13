systemd-run --user --scope -p "Delegate=yes" -p "MemoryLimit=500M" -p "CPUQuota=100%" --unit=my-cgroup-name bwrap --new-session --dev-bind / / --unshare-net bash


# verify with

#!/bin/bash

# Allocate 600 MB of memory using Python
python3 -c "
import os
import time

# Get and print the current PID
pid = os.getpid()
print(f'Allocated 600 MB of memory. PID: {pid}')

# Allocate 600 MB (600 * 1024 * 1024 bytes) of memory
data = bytearray(600 * 1024 * 1024)

# Keep the memory allocated for 60 seconds
print(f'Memory allocated. PID: {pid}. Press Ctrl+C to terminate early.')
time.sleep(60)
"

# also check with
systemd-run --user --scope -p "MemoryLimit=500M" --unit=memory-test ./allocate_memory.sh
