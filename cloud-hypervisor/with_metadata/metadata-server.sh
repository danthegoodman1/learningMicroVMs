#!/usr/bin/env bash

set -euo pipefail

: "${METADATA_IP:=169.254.169.254}"
: "${METADATA_PORT:=80}"

echo "Starting metadata server on http://${METADATA_IP}:${METADATA_PORT}/"
echo "Press Ctrl+C to stop"
echo ""

if ! ip -4 addr show | grep -q "${METADATA_IP}/"; then
    echo "Waiting for ${METADATA_IP} to be assigned to a host interface..."
    for _ in $(seq 1 "${METADATA_WAIT_RETRIES:-120}"); do
        if ip -4 addr show | grep -q "${METADATA_IP}/"; then
            break
        fi
        sleep 1
    done
fi

if ! ip -4 addr show | grep -q "${METADATA_IP}/"; then
    echo "Error: ${METADATA_IP} is not assigned. Start a metadata-enabled VM first." >&2
    exit 1
fi

sudo env METADATA_IP="$METADATA_IP" METADATA_PORT="$METADATA_PORT" python3 - <<'PYTHON_EOF'
#!/usr/bin/env python3
import http.server
import json
import os
import socketserver

BIND = os.environ.get("METADATA_IP", "169.254.169.254")
PORT = int(os.environ.get("METADATA_PORT", "80"))

VM_METADATA = {
    "172.16.0.2": {
        "instance-id": "vm-001",
        "local-ipv4": "172.16.0.2",
        "ami-id": "cloud-hypervisor-rootfs",
        "instance-type": "ch.micro",
        "placement": {"availability-zone": "local"},
        "hostname": "vm-001.local",
    },
    "172.16.1.2": {
        "instance-id": "vm-002",
        "local-ipv4": "172.16.1.2",
        "ami-id": "cloud-hypervisor-rootfs",
        "instance-type": "ch.micro",
        "placement": {"availability-zone": "local"},
        "hostname": "vm-002.local",
    },
}

class MetadataHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{self.client_address[0]}] {fmt % args}")

    def do_GET(self):
        client_ip = self.client_address[0]
        metadata = VM_METADATA.get(client_ip)
        if metadata is None:
            self.send_error(404, f"Unknown VM: {client_ip}")
            return

        path = self.path.strip("/")
        if path in ("", "meta-data", "meta-data/"):
            self.send_text("\n".join(metadata.keys()))
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
        elif path in ("all", "json"):
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

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReusableTCPServer((BIND, PORT), MetadataHandler) as httpd:
    print(f"Metadata server listening on {BIND}:{PORT}")
    print(f"Known VMs: {list(VM_METADATA.keys())}")
    httpd.serve_forever()
PYTHON_EOF
