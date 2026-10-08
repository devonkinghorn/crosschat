#!/usr/bin/env python3
"""Stand-in for a bridgev2 bridge in crosschatd's runtime tests.

`-e -c CONFIG` writes an example config; otherwise it reads appservice.port
from CONFIG and answers 200 to everything (health checks, transactions)."""
import http.server
import re
import sys

args = sys.argv[1:]
cfg = args[args.index("-c") + 1]
if "-e" in args:
    with open(cfg, "w") as f:
        f.write("appservice:\n  port: 1\nnetwork:\n  example: true\n")
    sys.exit(0)

port = None
in_as = False
for line in open(cfg):
    if re.match(r"^appservice:", line):
        in_as = True
    elif re.match(r"^\S", line):
        in_as = False
    elif in_as:
        m = re.match(r"^\s+port:\s*(\d+)", line)
        if m:
            port = int(m.group(1))


class H(http.server.BaseHTTPRequestHandler):
    def _ok(self):
        n = int(self.headers.get("content-length") or 0)
        if n:
            self.rfile.read(n)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    do_GET = do_PUT = do_POST = _ok

    def log_message(self, *a):
        pass


print(f"fake bridge listening on {port}", flush=True)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
