#!/usr/bin/env python3
"""Serve the PWA on http://127.0.0.1:4173 (or the port given as the first argument).

`python3 -m http.server` resolves the machine's hostname before listening,
which can hang on some networks; this server skips that lookup.
"""

import functools
import http.server
import pathlib
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4173
WEB = pathlib.Path(__file__).resolve().parent.parent / "apps/web"


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Handler(http.server.SimpleHTTPRequestHandler):
    # Make the browser revalidate every file, so edits show up on reload.
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


handler = functools.partial(Handler, directory=str(WEB))
with Server(("127.0.0.1", PORT), handler) as httpd:
    print(f"PocketRoute PWA on http://127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()
