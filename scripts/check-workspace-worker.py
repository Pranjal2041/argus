#!/usr/bin/env python3
"""Exercise the real headless executable against an isolated loopback broker."""
import argparse
import http.server
import json
import os
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit


def check(binary, backend, corrections=False):
    requests = []
    snapshots = []
    publications = []
    cleared = []
    info = {"protocol": 1, "enabled": True, "workspaceID": "worker-check", "brokerID": "check-broker"}

    class Broker(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body):
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            path = self.path.split("?")[0]
            requests.append(path)
            if path == "/workspace/info":
                self.reply(200, info)
            elif path == "/workspace/snapshot":
                self.reply(200, dict(info, cursor=0, records=[]))
            elif path == "/workspace/changes":
                self.reply(200, dict(info, cursor=0, records=[], more=False))
            elif path == "/whoami":
                self.reply(200, {"service": "universal-tmux-broker", "proto": 1,
                                 "host": "fixture", "name": "fixture", "socket": "fixture",
                                 "os": backend, "brokerID": "check-broker", "workspace": info})
            elif path == "/mesh/peers":
                self.reply(200, {"peers": []})
            elif path == "/sessions":
                state = ["waiting", "working", "idle"][min(len(snapshots), 2)]
                snapshots.append(state)
                self.reply(200, {"sessions": [{"name": "fixture-session", "windows": 1,
                    "attached": False, "activity": len(snapshots), "state": state,
                    "agent": False, "id": "$1" if backend == "linux" else "",
                    "lineageID": backend + "-lifetime", "activityRevision": len(snapshots)}]})
            elif corrections and path == "/ccoverride":
                self.reply(200, {"overrides": [] if cleared else [{"session": "fixture-session", "label": "stuck", "ts": 1234}]})
            elif path == "/recent":
                # Empty output prevents any model invocation, even with the
                # status lease granted in the correction publication check.
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.reply(404, {"error": "not_found"})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            requests.append(self.path)
            path = urlsplit(self.path).path
            if corrections and path == "/workspace/lease":
                lease = json.loads(body)
                if lease.get("name") == "cc-status":
                    self.reply(200, dict(lease, fence=1, expiresAt=int(time.time() * 1000) + 120000))
                    return
            if corrections and path == "/ccstatus":
                publications.append(json.loads(body))
                # Retry after a rejected publication; never clear beforehand.
                self.reply(503 if len(publications) == 1 else 200, {"ok": len(publications) > 1})
                return
            if corrections and path == "/ccoverride":
                query = parse_qs(urlsplit(self.path).query)
                if query.get("clear") == ["1234"]:
                    assert len(publications) > 1, "Relay cleared before publication was accepted"
                    rows = publications[-1]["items"]
                    assert any(row["label"] == "stuck" and row.get("appliedOverrideTS") == 1234 for row in rows), rows
                    cleared.append(1234)
                self.reply(200, {"ok": True})
                return
            # Another owner holds all leases: no providers, credentials, journal
            # ingestion, or real accounts are touched by this process check.
            self.reply(409, {"error": "lease_held"})

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Broker)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="argus-worker-check-") as home:
            env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
            process = subprocess.Popen([binary, "--workspace-worker",
                f"--workspace-endpoint=http://127.0.0.1:{server.server_port}"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline and process.poll() is None:
                    if snapshots[:3] == ["waiting", "working", "idle"] and (not corrections or cleared):
                        time.sleep(0.5)  # allow the final transition callback to run
                        break
                    time.sleep(0.1)
                assert process.poll() is None, process.communicate()[0].decode(errors="replace")
                assert snapshots[:3] == ["waiting", "working", "idle"], (snapshots, requests)
                assert "/workspace/changes" in requests, requests
                if corrections:
                    assert cleared, (publications, requests)
                    print(f"PASS {backend}: rejected publication retried; correction receipt published before relay clear")
                print(f"PASS {backend}: real worker survived waiting → working → idle without an application window")
            finally:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--corrections", action="store_true")
    args = parser.parse_args()
    for implementation in ("linux", "windows"):
        check(os.path.abspath(args.binary), implementation, args.corrections)
