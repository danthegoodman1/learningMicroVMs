"""Test child for the supervisor: an HTTP server that reports the INSTANCE_ID
from its environment, a value from Python's own PRNG, and its wall clock."""
import json
import os
import random
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

INSTANCE_ID = os.environ.get("INSTANCE_ID", "")
RND = f"{random.getrandbits(64):016x}"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"id": INSTANCE_ID, "rnd": RND, "rt": time.time_ns()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
