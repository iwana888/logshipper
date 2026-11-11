#!/usr/bin/env python3
"""
Same-origin host + reverse proxy for the Loki log viewer (web/index.html).

Why a proxy: Loki does not send CORS headers, so a browser page cannot call
/loki/api/v1/* directly. This server hosts the page AND forwards Loki API calls
under the same origin, so the browser only ever talks to localhost.

Usage:
    python web/serve.py                                # Loki = http://localhost:3100, port 8099
    python web/serve.py --loki http://host:3100 --port 8099
    set LOKI_URL=http://host:3100 && python web/serve.py

Then open http://127.0.0.1:8099
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEB_DIR = os.path.dirname(os.path.abspath(__file__))
LOKI_BASE = ""
TIMEOUT = 30


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Scope-OrgID, Authorization")

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path in ("/", "/index.html"):
            try:
                with open(os.path.join(WEB_DIR, "index.html"), "rb") as fh:
                    return self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError as exc:
                return self._send(500, json.dumps({"error": str(exc)}))

        if parsed.path == "/api/info":
            return self._send(200, json.dumps({"loki": LOKI_BASE}))

        if parsed.path.startswith("/loki/"):
            return self._proxy("GET", parsed, None)

        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        if parsed.path.startswith("/loki/"):
            return self._proxy("POST", parsed, body)
        return self._send(404, json.dumps({"error": "not found"}))

    def _proxy(self, method, parsed, body):
        url = LOKI_BASE.rstrip("/") + parsed.path
        if parsed.query:
            url += "?" + parsed.query

        headers = {}
        for name in ("X-Scope-OrgID", "Authorization", "Accept", "Content-Type"):
            val = self.headers.get(name)
            if val:
                headers[name] = val

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = resp.read()
                ctype = resp.headers.get("Content-Type", "application/json; charset=utf-8")
                self._send(resp.status, data, ctype)
        except urllib.error.HTTPError as exc:
            self._send(exc.code, exc.read(), "application/json; charset=utf-8")
        except Exception as exc:  # noqa: BLE001 - surface any backend failure to the UI
            self._send(502, json.dumps({"error": "Loki unreachable: %s" % exc}))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global LOKI_BASE
    parser = argparse.ArgumentParser(description="Loki log viewer")
    parser.add_argument("--loki", default=os.environ.get("LOKI_URL", "http://localhost:3100"),
                        help="Loki base URL (default: http://localhost:3100)")
    parser.add_argument("--host", default="127.0.0.1", help="bind address")
    parser.add_argument("--port", type=int, default=8099, help="listen port (default 8099; 8080 is often taken)")
    args = parser.parse_args()

    LOKI_BASE = args.loki.rstrip("/")
    srv = Server((args.host, args.port), Handler)
    print("Log viewer : http://%s:%d" % (args.host, args.port))
    print("Loki       : %s" % LOKI_BASE)
    print("Ctrl-C to stop\n", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
        srv.shutdown()


if __name__ == "__main__":
    main()
