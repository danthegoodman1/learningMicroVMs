#!/usr/bin/env bash

set -euo pipefail

: "${METADATA_IP:=169.254.169.254}"
: "${METADATA_PORT:=80}"

if ! ip -4 addr show | grep -q "${METADATA_IP}/"; then
    echo "Error: $METADATA_IP is not assigned; start a metadata VM first." >&2
    exit 1
fi

echo "QEMU metadata server listening on http://${METADATA_IP}:${METADATA_PORT}/"
sudo env METADATA_IP="$METADATA_IP" METADATA_PORT="$METADATA_PORT" python3 - <<'PY'
import http.server
import json
import os
import socketserver

BIND = os.environ["METADATA_IP"]
PORT = int(os.environ["METADATA_PORT"])

def metadata_for(client_ip):
    parts = client_ip.split(".")
    number = int(parts[2]) + 1 if len(parts) == 4 else 0
    return {
        "instance-id": f"vm-{number:03d}",
        "local-ipv4": client_ip,
        "ami-id": "qemu-rootfs",
        "instance-type": "qemu.micro",
        "placement": {"availability-zone": "local"},
        "hostname": f"vm-{number:03d}.local",
    }

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{self.client_address[0]}] {fmt % args}")

    def do_GET(self):
        metadata = metadata_for(self.client_address[0])
        path = self.path.strip("/")
        if path in ("", "meta-data", "meta-data/"):
            self.send_value("\n".join(metadata))
        elif path in ("all", "json"):
            self.send_value(metadata)
        elif path == "placement/availability-zone":
            self.send_value(metadata["placement"]["availability-zone"])
        elif path in metadata:
            self.send_value(metadata[path])
        else:
            self.send_error(404, f"Metadata key not found: {path}")

    def send_value(self, value):
        self.send_response(200)
        self.send_header("Content-Type", "application/json" if isinstance(value, dict) else "text/plain")
        self.end_headers()
        body = json.dumps(value, indent=2) if isinstance(value, dict) else str(value)
        self.wfile.write(body.encode())

class Server(socketserver.TCPServer):
    allow_reuse_address = True

Server((BIND, PORT), Handler).serve_forever()
PY
