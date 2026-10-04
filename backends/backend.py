#!/usr/bin/env python3
"""Backend application server — CN Course Project, Task C.

Zero dependencies: Python 3 standard library only.

ONE file serves as both Backend A and Backend B — the role is chosen
with command-line flags:

    python3 backend.py --name A --port 3001     # Mac 3 — Backend A
    python3 backend.py --name B --port 3002     # Mac 4 — Backend B

Endpoints (every response carries the  X-Backend: A|B  header):

    GET /                Welcome JSON confirming the service is running
    GET /api/status      {"backend": "A", "status": "ok", ...}   (required contract)
    GET /api/cached      Cacheable resource (Task F):
                           Cache-Control: public, max-age=60
                           ETag + Last-Modified
                         Answers conditional requests (If-None-Match /
                         If-Modified-Since) with "304 Not Modified".
                         Add ?version=v2 to force fresh content + a new ETag.
    GET /health          Liveness probe -> "ok"
    GET /slow?seconds=5  Delays the response — used to demonstrate nginx
                         timeouts and proxy_next_upstream failover.

Design notes (viva material):
  * Binds 0.0.0.0 (all interfaces) so the edge machine can reach it
    across the LAN. Binding 127.0.0.1 would make it invisible to every
    other machine.
  * Speaks plain HTTP/1.1 with keep-alive. TLS is NOT terminated here —
    the nginx edge does HTTPS and proxies plain HTTP to us. That split
    is exactly what "TLS termination at the edge" means.
  * Every request is logged with the client's full socket pair
    (client_ip:ephemeral_port) — direct evidence for the transport-layer
    discussion (well-known server port vs ephemeral client port).
"""

import argparse
import hashlib
import json
import os
import signal
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CFG = {"name": "?", "port": 0, "host": "0.0.0.0"}
START_TIME = time.time()
REQUEST_COUNT = 0
COUNT_LOCK = threading.Lock()
HOSTNAME = socket.gethostname()

# Stable Last-Modified for the cacheable resource. If the ETag /
# Last-Modified changed on every request, a "304 Not Modified" could
# never happen — validators must identify *identical* content.
CACHED_LAST_MODIFIED = "Wed, 01 Jan 2025 09:00:00 GMT"
CACHED_LAST_MODIFIED_TS = 1735722000  # epoch seconds of the date above


def bump_counter():
    global REQUEST_COUNT
    with COUNT_LOCK:
        REQUEST_COUNT += 1
        return REQUEST_COUNT


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class BackendHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"          # enables keep-alive connections
    server_version = "TeamBackend"
    sys_version = ""

    # ---------------- response helpers ----------------
    def _identity_headers(self):
        self.send_header("X-Backend", CFG["name"])        # required by Task C
        self.send_header("X-Backend-Host", HOSTNAME)
        self.send_header("X-Served-At", now_iso())

    def _send_json(self, code, obj, extra_headers=None, head_only=False):
        body = json.dumps(obj, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._identity_headers()
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _send_304(self, extra_headers=None):
        # A 304 MUST NOT carry a body — that is the whole point of a
        # conditional request: headers only, zero payload bytes on the wire.
        self.send_response(304)
        self._identity_headers()
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def _send_text(self, code, text, head_only=False):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._identity_headers()
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    # ---------------- routes ----------------
    def _route_welcome(self, head_only):
        self._send_json(200, {
            "service": "Team Backend " + CFG["name"],
            "status": "running",
            "message": "Hello from Backend " + CFG["name"] + "! You reached me "
                       "through the nginx edge (reverse proxy + load balancer).",
            "backend": CFG["name"],
            "hostname": HOSTNAME,
            "pid": os.getpid(),
            "listen_port": CFG["port"],
            "uptime_seconds": round(time.time() - START_TIME, 1),
            "requests_served": REQUEST_COUNT,
            "server_time_utc": now_iso(),
            "endpoints": ["/", "/api/status", "/api/cached", "/health", "/slow?seconds=N"],
        }, head_only=head_only)

    def _route_status(self, head_only):
        # Required contract: {"backend": "A", "status": "ok"} (+ extras)
        self._send_json(200, {
            "backend": CFG["name"],
            "status": "ok",
            "hostname": HOSTNAME,
            "pid": os.getpid(),
            "listen_port": CFG["port"],
            "uptime_seconds": round(time.time() - START_TIME, 1),
            "requests_served": REQUEST_COUNT,
            "server_time_utc": now_iso(),
        }, head_only=head_only)

    def _route_cached(self, head_only):
        qs = parse_qs(urlparse(self.path).query)
        version = qs.get("version", ["v1"])[0]
        # IMPORTANT design decision (great viva material): the cached
        # representation is BYTE-IDENTICAL on Backend A and Backend B.
        # Behind a round-robin LB a conditional request (If-None-Match)
        # can land on EITHER server — if each backend stamped its own name
        # into the body, their ETags would differ and 304s would randomly
        # break. So: identity lives in the X-Backend HEADER (headers are
        # not part of the validator), and the body stays uniform.
        payload = {
            "resource": "cached-report",
            "version": version,
            "generated_at": CACHED_LAST_MODIFIED,
            "cache_policy": "public, max-age=60 — for 60 s a client/proxy may serve "
                            "this from cache without asking; after that it revalidates "
                            "with If-None-Match and receives 304 Not Modified "
                            "(headers only, no body re-transferred).",
            "served_by": "see the X-Backend response header (identical body on A and B "
                         "on purpose, so ETag validation survives load balancing)",
        }
        body = json.dumps(payload, indent=2).encode("utf-8")
        etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
        cache_headers = {
            "Cache-Control": "public, max-age=60",
            "ETag": etag,
            "Last-Modified": CACHED_LAST_MODIFIED,
        }

        # --- Conditional request handling (Task F) ---
        inm = self.headers.get("If-None-Match", "")
        if inm and etag in [t.strip() for t in inm.split(",")]:
            return self._send_304(cache_headers)          # <- the money shot

        ims = self.headers.get("If-Modified-Since", "")
        if ims:
            try:
                if parsedate_to_datetime(ims).timestamp() >= CACHED_LAST_MODIFIED_TS:
                    return self._send_304(cache_headers)
            except (ValueError, TypeError, OverflowError):
                pass

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._identity_headers()
        for k, v in cache_headers.items():
            self.send_header(k, v)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _route_slow(self, head_only):
        qs = parse_qs(urlparse(self.path).query)
        try:
            seconds = min(max(float(qs.get("seconds", ["5"])[0]), 0), 30)
        except ValueError:
            return self._send_json(400, {"error": "seconds must be a number"})
        time.sleep(seconds)
        self._send_json(200, {
            "backend": CFG["name"],
            "slept_seconds": seconds,
            "note": "nginx has proxy_read_timeout 10s — sleeping longer than that makes "
                    "the edge give up on this backend and (thanks to proxy_next_upstream) "
                    "retry the request on the OTHER backend.",
        }, head_only=head_only)

    # ---------------- HTTP verbs ----------------
    def _dispatch(self, head_only=False):
        bump_counter()
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/":
            self._route_welcome(head_only)
        elif path == "/api/status":
            self._route_status(head_only)
        elif path == "/api/cached":
            self._route_cached(head_only)
        elif path == "/health":
            self._send_text(200, "ok", head_only)
        elif path == "/slow":
            self._route_slow(head_only)
        else:
            self._send_json(404, {
                "error": "not found",
                "path": self.path,
                "backend": CFG["name"],
                "hint": "try /, /api/status, /api/cached, /health, /slow?seconds=N",
            }, head_only=head_only)

    def do_GET(self):
        self._dispatch(head_only=False)

    def do_HEAD(self):
        # curl -I sends HEAD — needed for the Task F header demos.
        self._dispatch(head_only=True)

    # ---------------- logging ----------------
    def log_message(self, fmt, *args):
        # Override default logging to always include the client's full
        # socket pair (ip:ephemeral_port) — transport-layer evidence.
        client_ip, client_port = self.client_address[0], self.client_address[1]
        sys.stdout.write("[%s] backend=%s pid=%d  %s:%s -> %s\n"
                         % (now_iso(), CFG["name"], os.getpid(),
                            client_ip, client_port, fmt % args))
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description="CN course project backend (zero dependencies)")
    ap.add_argument("--name", required=True, choices=["A", "B"],
                    help="backend identifier — sent as the X-Backend header")
    ap.add_argument("--port", required=True, type=int,
                    help="TCP port to listen on (3001 for A, 3002 for B)")
    ap.add_argument("--host", default="0.0.0.0",
                    help="bind address — keep 0.0.0.0 so other machines can reach this backend")
    args = ap.parse_args()

    CFG.update(name=args.name, port=args.port, host=args.host)

    server = ThreadingHTTPServer((args.host, args.port), BackendHandler)
    server.daemon_threads = True

    def _shutdown(signum, _frame):
        sys.stdout.write("\n[backend %s] signal %d received — shutting down cleanly\n"
                         % (CFG["name"], signum))
        sys.stdout.flush()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    print("""
==============================================================
 Backend %s — CN Course Project (Task C)
--------------------------------------------------------------
 Listening : http://%s:%d   (LAN-reachable)
 Machine   : %s   PID %d
 Endpoints : GET /   /api/status   /api/cached   /health   /slow?seconds=N
 Identity  : every response carries   X-Backend: %s
 TLS       : terminated at the nginx edge, NOT here (plain HTTP upstream)
=============================================================="""
          % (CFG["name"], CFG["host"], CFG["port"], HOSTNAME, os.getpid(), CFG["name"]),
          flush=True)

    server.serve_forever(poll_interval=0.2)
    server.server_close()
    print("[backend %s] stopped after serving %d requests." % (CFG["name"], REQUEST_COUNT),
          flush=True)


if __name__ == "__main__":
    main()
