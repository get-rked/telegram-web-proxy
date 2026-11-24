#!/usr/bin/env python3
"""Bridge loopback-only relay and MTProxy admin endpoints to the private panel network."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from urllib.error import URLError
from urllib.request import urlopen

ADMIN_PORT = int(os.environ.get("RELAY_ADMIN_PORT", "8081"))
UPSTREAMS = {
    "/stats": "http://127.0.0.1:8888/stats",
    "/relay/healthz": f"http://127.0.0.1:{ADMIN_PORT}/healthz",
    "/relay/readyz": f"http://127.0.0.1:{ADMIN_PORT}/readyz",
    "/relay/metrics": f"http://127.0.0.1:{ADMIN_PORT}/metrics",
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(204)
            self.end_headers()
            return
        upstream = UPSTREAMS.get(self.path)
        if upstream is None:
            self.send_error(404)
            return
        try:
            with urlopen(upstream, timeout=3) as response:
                data = response.read(2 * 1024 * 1024)
                status = response.status
                content_type = response.headers.get("Content-Type", "text/plain; charset=utf-8")
        except (OSError, URLError):
            self.send_error(503, "upstream statistics unavailable")
            return
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        return

ThreadingHTTPServer(("0.0.0.0", 9090), Handler).serve_forever()
