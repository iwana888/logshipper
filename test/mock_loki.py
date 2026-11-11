import sys, json, gzip, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 59999

conc_lock = threading.Lock()
conc = 0
conc_max = 0

class H(BaseHTTPRequestHandler):
    def _handle(self):
        global conc, conc_max
        ln = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(ln)
        enc = self.headers.get('Content-Encoding', '')
        if enc == 'gzip':
            body = gzip.decompress(body)
        data = json.loads(body.decode('utf-8'))
        # mode-based responses
        if MODE == "ok":
            code = 204
        elif MODE == "bad":
            code = 400
        elif MODE == "retry":
            # 429 twice, then 204
            if not hasattr(self.server, "n"):
                self.server.n = 0
            self.server.n += 1
            code = 429 if self.server.n <= 2 else 204
        else:
            code = 204

        with conc_lock:
            conc += 1
            if conc > conc_max:
                conc_max = conc
        # slow mode: hold the connection a bit to expose concurrency
        if MODE == "slow":
            time.sleep(0.4)
        with conc_lock:
            conc -= 1

        print("MOCK rc=%d streams=%d first=%s" % (
            code,
            len(data.get("streams", [])),
            json.dumps(data["streams"][0]["values"][0]) if data.get("streams") else "none"),
            flush=True)
        print("  CONC_MAX=%d" % conc_max, flush=True)
        for s in data.get("streams", []):
            print("  stream labels:", s.get("stream"), flush=True)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()
        # signal the test driver
        with open("mock_received.tmp", "a") as f:
            f.write("RECEIVED rc=%d\n" % code)

    def do_POST(self):
        self._handle()

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print("MOCK listening on %d mode=%s" % (PORT, MODE), flush=True)
    srv.serve_forever()
