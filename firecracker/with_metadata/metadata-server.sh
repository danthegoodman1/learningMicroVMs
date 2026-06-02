#!/bin/bash
# Simple metadata server for Firecracker VMs
#
# Listens on 169.254.169.254:80 and serves VM metadata.
# Identifies which VM the request came from by source IP.
#
# Usage: sudo ./metadata-server.sh
#
# Requires: Python 3

set -e

METADATA_IP="169.254.169.254"
METADATA_PORT="80"

# Map of VM source IPs to their metadata
# Add entries here for each VM you spawn
declare -A VM_METADATA
VM_METADATA["172.16.0.2"]='{"instance-id": "vm-001", "local-ipv4": "172.16.0.2", "tap": "tap0"}'
VM_METADATA["172.16.1.2"]='{"instance-id": "vm-002", "local-ipv4": "172.16.1.2", "tap": "tap1"}'
# Add more VMs as needed...

echo "Starting metadata server on http://${METADATA_IP}:${METADATA_PORT}/"
echo "Press Ctrl+C to stop"
echo ""

# Create a temporary Python server script
TMPSCRIPT=$(mktemp)
cat > "$TMPSCRIPT" << 'PYTHON_EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import sys

# VM metadata keyed by source IP
VM_METADATA = {
    "172.16.0.2": {
        "instance-id": "vm-001",
        "local-ipv4": "172.16.0.2",
        "ami-id": "firecracker-rootfs",
        "instance-type": "fc.micro",
        "placement": {"availability-zone": "local"},
        "hostname": "vm-001.local",
    },
    "172.16.1.2": {
        "instance-id": "vm-002",
        "local-ipv4": "172.16.1.2",
        "ami-id": "firecracker-rootfs",
        "instance-type": "fc.micro",
        "placement": {"availability-zone": "local"},
        "hostname": "vm-002.local",
    },
    # Add more VMs here...
}

class MetadataHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        client_ip = self.client_address[0]
        print(f"[{client_ip}] {args[0]}")

    def do_GET(self):
        client_ip = self.client_address[0]
        
        # Look up metadata for this VM
        if client_ip not in VM_METADATA:
            self.send_error(404, f"Unknown VM: {client_ip}")
            return
        
        metadata = VM_METADATA[client_ip]
        path = self.path.strip("/")
        
        # Route requests
        if path == "" or path == "meta-data" or path == "meta-data/":
            # List available metadata keys
            content = "\n".join(metadata.keys())
            self.send_text(content)
        
        elif path in metadata:
            value = metadata[path]
            if isinstance(value, dict):
                self.send_json(value)
            else:
                self.send_text(str(value))
        
        elif path == "instance-id":
            self.send_text(metadata.get("instance-id", "unknown"))
        
        elif path == "local-ipv4":
            self.send_text(metadata.get("local-ipv4", "unknown"))
        
        elif path == "hostname":
            self.send_text(metadata.get("hostname", "unknown"))
        
        elif path == "all" or path == "json":
            # Return all metadata as JSON
            self.send_json(metadata)
        
        elif path == "placement/availability-zone":
            self.send_text(metadata.get("placement", {}).get("availability-zone", "unknown"))
        
        else:
            self.send_error(404, f"Metadata key not found: {path}")
    
    def send_text(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(content.encode())
    
    def send_json(self, obj):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(obj, indent=2).encode())

if __name__ == "__main__":
    PORT = 80
    BIND = "169.254.169.254"
    
    if len(sys.argv) > 1:
        BIND = sys.argv[1]
    if len(sys.argv) > 2:
        PORT = int(sys.argv[2])
    
    with socketserver.TCPServer((BIND, PORT), MetadataHandler) as httpd:
        print(f"Metadata server listening on {BIND}:{PORT}")
        print(f"Known VMs: {list(VM_METADATA.keys())}")
        httpd.serve_forever()
PYTHON_EOF

# Run the server (requires root for port 80)
sudo python3 "$TMPSCRIPT" "$METADATA_IP" "$METADATA_PORT"

# Cleanup
rm -f "$TMPSCRIPT"
