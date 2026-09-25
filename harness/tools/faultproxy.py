#!/usr/bin/env python3
"""A JSON-RPC fault proxy, so a scenario can degrade ONE node's view of the chain.

It forwards HTTP JSON-RPC from a listen address to an upstream sequencer and
applies whatever fault its control file names at the moment each request
arrives. Pointing a single node's wallet_config.json at the proxy leaves the
harness's own oracles dialling the sequencer directly, which is the whole point:
the harness can still see the chain during an outage it induced.

Modes (the control file holds one line, re-read per request):

    pass                  forward untouched
    refuse                close the connection with no reply (RPC unreachable)
    blackhole             read the request and never answer (hangs the caller)
    delay:<ms>            forward, but only after <ms> of latency
    error5xx              answer 503 without forwarding

A second word scopes the fault to matching JSON-RPC methods (fnmatch glob,
case-insensitive); everything else passes. That is what makes a chain-liveness
stall expressible -- "reads answer, my transaction never lands" is
`blackhole *send*Transaction*`, which pausing a sequencer process cannot say.

Every request is appended to the trace file as

    <unix_ms> <method> <mode_applied> <status> <upstream_ms>

so `pass` mode doubles as an RPC recorder: the per-phase method counts are the
call-amplification baseline you want before pointing anything at a hosted
endpoint that has rate limits and a cold-start latency.
"""

import argparse
import fnmatch
import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# A blackholed request holds its thread. Threads are daemons and the proxy is
# torn down with the scenario, but an unbounded hold plus a retrying client
# still grows the thread count without limit, so cap the hold well past any
# caller timeout in the stack (the wallet's per-request bound is 60s and the
# module's provider gives up at 190s).
BLACKHOLE_HOLD_S = 600


class Control:
    """The control file, read fresh per request. A file beats a control socket
    here because the callers are bash: `printf blackhole > $ctl` is the API."""

    def __init__(self, path):
        self.path = path

    def read(self):
        try:
            with open(self.path) as fh:
                line = fh.read().strip()
        except OSError:
            return "pass", None
        if not line:
            return "pass", None
        parts = line.split(None, 1)
        mode = parts[0]
        glob = parts[1].strip() if len(parts) > 1 else None
        return mode, glob


class Trace:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def add(self, method, mode, status, upstream_ms):
        if not self.path:
            return
        line = "%d %s %s %s %s\n" % (
            int(time.time() * 1000),
            method or "-",
            mode,
            status,
            "-" if upstream_ms is None else "%d" % upstream_ms,
        )
        with self.lock:
            try:
                with open(self.path, "a") as fh:
                    fh.write(line)
            except OSError:
                pass


def rpc_method(body):
    """The JSON-RPC method name, or None. A batch reports its first call: the
    faults here are all-or-nothing per request anyway."""
    try:
        doc = json.loads(body)
    except (ValueError, TypeError):
        return None
    if isinstance(doc, list):
        doc = doc[0] if doc else {}
    if not isinstance(doc, dict):
        return None
    method = doc.get("method")
    return method if isinstance(method, str) else None


def applies(glob, method):
    if glob is None:
        return True
    if method is None:
        return False
    return fnmatch.fnmatch(method.lower(), glob.lower())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "e2e-faultproxy"

    # Per-request logging goes to the trace file; the default handler writes a
    # line per request to stderr, which buries the scenario's own output.
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        method = rpc_method(body)
        mode, glob = self.server.control.read()

        if not applies(glob, method):
            mode = "pass"

        if mode == "refuse":
            self.server.trace.add(method, mode, "refused", None)
            self.close_connection = True
            return

        if mode == "blackhole":
            self.server.trace.add(method, mode, "blackhole", None)
            time.sleep(BLACKHOLE_HOLD_S)
            self.close_connection = True
            return

        if mode == "error5xx":
            self.server.trace.add(method, mode, "503", None)
            self._respond(503, b'{"error":"faultproxy: upstream unavailable"}')
            return

        if mode.startswith("delay:"):
            try:
                time.sleep(int(mode.split(":", 1)[1]) / 1000.0)
            except ValueError:
                pass

        t0 = time.time()
        try:
            status, payload = self._forward(body)
        except Exception as exc:  # upstream unreachable, socket error, timeout
            self.server.trace.add(method, mode, "upstream-error", (time.time() - t0) * 1000)
            self._respond(502, json.dumps({"error": "faultproxy: %s" % exc}).encode())
            return
        self.server.trace.add(method, mode, status, (time.time() - t0) * 1000)
        self._respond(status, payload)

    def _forward(self, body):
        req = urllib.request.Request(
            self.server.upstream,
            data=body,
            method="POST",
            headers={"Content-Type": self.headers.get("Content-Type", "application/json")},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.server.upstream_timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            # A 4xx/5xx from the sequencer is a real answer -- pass it through
            # rather than reporting it as a proxy failure.
            return err.code, err.read()

    def _respond(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="HOST:PORT to listen on")
    ap.add_argument("--upstream", required=True, help="sequencer URL to forward to")
    ap.add_argument("--control", required=True, help="file holding the current mode")
    ap.add_argument("--trace", default="", help="append a line per request here")
    ap.add_argument("--upstream-timeout", type=float, default=120.0)
    args = ap.parse_args()

    host, _, port = args.listen.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    srv.daemon_threads = True
    srv.upstream = args.upstream
    srv.upstream_timeout = args.upstream_timeout
    srv.control = Control(args.control)
    srv.trace = Trace(args.trace)

    # The parent waits on this line before pointing anything at the proxy.
    sys.stderr.write("faultproxy: listening on %s -> %s\n" % (args.listen, args.upstream))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
