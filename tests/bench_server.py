"""Local server for the browser benchmark: serves build/web and records the results.

    python3 tests/bench_server.py [--port 8790] [--out tests/results/bench_runs.jsonl]

The game (opened with ?bench, e.g. http://localhost:8790/?autopilot&bench) reports its
frame-time statistics with POST /bench-result at the end of the run; each report is
appended as one JSON line to --out and printed. GET /bench-start?<w>x<h>@<dpr> is logged.
"""
import argparse
import http.server
import json
import os
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8790)
ap.add_argument("--dir", default=os.path.join(os.path.dirname(__file__), "..", "build", "web"))
ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "results", "bench_runs.jsonl"))
args = ap.parse_args()


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=args.dir, **k)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        if self.path.startswith("/bench-start"):
            print(time.strftime("%H:%M:%S"), "bench-start", self.path.split("?", 1)[-1], flush=True)
            self.send_response(204)
            self.end_headers()
            return
        super().do_GET()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if self.path.startswith("/bench-result"):
            try:
                rep = json.loads(body)
            except ValueError:
                rep = {"raw": body}
            rep["received"] = time.strftime("%Y-%m-%d %H:%M:%S")
            with open(args.out, "a") as f:
                f.write(json.dumps(rep) + "\n")
            print(time.strftime("%H:%M:%S"), "bench-result", json.dumps({k: rep.get(k) for k in (
                "avg_fps", "median_ms", "p95_ms", "p95_fps", "p99_ms", "one_pct_low_fps", "render_gpu_ms_mean", "options")}), flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *a):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", args.port), H).serve_forever()
