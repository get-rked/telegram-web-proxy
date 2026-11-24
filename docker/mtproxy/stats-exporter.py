#!/usr/bin/env python3
"""Expose loopback-only MTProxy statistics to the private Docker network."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.request import urlopen

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(204)
            self.end_headers()
            return
        if self.path != "/stats":
            self.send_error(404)
            return
        try:
            with urlopen("http://127.0.0.1:8888/stats", timeout=2) as response:
                data = response.read(1024 * 1024)
        except (OSError, URLError):
            self.send_error(503, "MTProxy statistics unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        return

ThreadingHTTPServer(("0.0.0.0", 9090), Handler).serve_forever()
