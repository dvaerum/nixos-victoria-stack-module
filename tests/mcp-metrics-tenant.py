"""Run the real mcp-victoriametrics binary (VM_INSTANCE_TYPE=single) against a
recording HTTP backend and check the optional `tenant` tool argument: a valid
value becomes the AccountID/ProjectID headers of the backend request, no value
sends no tenant headers, and a malformed value is refused before any request.

usage: mcp-metrics-tenant.py <path to mcp-victoriametrics>
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BINARY = sys.argv[1]
INIT_PARAMS = {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {"name": "t", "version": "0"},
}
CLIENT_TOKEN = "Bearer client-fixture-token"  # gitleaks:allow

# Tools of a single-node instance that do not query the instance's select API.
NO_TENANT_TOOLS = {"flags", "test_rules"}

seen = []  # one dict of lower-cased request headers (plus "path") per backend request


class Backend(BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append({**{k.lower(): v for k, v in self.headers.items()}, "path": self.path})
        out = b'{"status":"success","data":{"resultType":"vector","result":[]}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


backend = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
threading.Thread(target=backend.serve_forever, daemon=True).start()

port = free_port()
errfile = tempfile.TemporaryFile()
proc = subprocess.Popen(
    [BINARY],
    env={
        "PATH": os.environ["PATH"],
        "VM_INSTANCE_ENTRYPOINT": f"http://127.0.0.1:{backend.server_address[1]}",
        "VM_INSTANCE_TYPE": "single",
        "MCP_SERVER_MODE": "http",
        "MCP_LISTEN_ADDR": f"127.0.0.1:{port}",
        "MCP_PASSTHROUGH_HEADERS": "Authorization,AccountID",
        # Only the documentation tool is off (it loads a large embedded index).
        "MCP_DISABLED_TOOLS": "documentation",
    },
    stdout=subprocess.DEVNULL,
    stderr=errfile,
)


def stderr():
    errfile.seek(0)
    return errfile.read().decode(errors="replace")


def die(msg):
    print(f"{msg}\n--- server stderr ---\n{stderr()}", file=sys.stderr)
    proc.kill()
    sys.exit(1)


for _ in range(100):
    if proc.poll() is not None:
        break
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/health/readiness", timeout=2)
        break
    except (urllib.error.URLError, OSError):
        time.sleep(0.2)
else:
    die("mcp-victoriametrics did not become ready")
if proc.poll() is not None:
    die("mcp-victoriametrics exited")

URL = f"http://127.0.0.1:{port}/mcp"


def rpc(headers, sid, body):
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **headers,
    }
    if sid:
        h["Mcp-Session-Id"] = sid
    req = urllib.request.Request(URL, json.dumps(body).encode(), h, method="POST")
    resp = urllib.request.urlopen(req, timeout=20)
    text = resp.read().decode()
    payload = "".join(line[5:] for line in text.splitlines() if line.startswith("data:")) or text
    return resp.headers.get("Mcp-Session-Id"), (json.loads(payload) if payload.strip() else None)


class Session:
    def __init__(self, headers):
        self.headers = headers
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS}
        self.sid, _ = rpc(headers, None, init)
        rpc(headers, self.sid, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.n = 1

    def request(self, method, params):
        self.n += 1
        body = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}
        return rpc(self.headers, self.sid, body)[1]

    def call(self, tool, arguments):
        """Returns (is_error, backend requests caused by the call)."""
        del seen[:]
        r = self.request("tools/call", {"name": tool, "arguments": arguments})
        return "error" in r or r["result"].get("isError", False), list(seen)


failures = []


def check(name, ok, detail):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(f"{name}: {detail}")


session = Session({"Authorization": CLIENT_TOKEN, "AccountID": "99"})

# every tool that queries the instance offers the optional string argument
tools = session.request("tools/list", {})["result"]["tools"]
names = {t["name"] for t in tools}
check("the query tool is listed", "query" in names, names)
missing = sorted(
    t["name"]
    for t in tools
    if t["name"] not in NO_TENANT_TOOLS
    and t["inputSchema"].get("properties", {}).get("tenant", {}).get("type") != "string"
)
check("every instance tool has a string tenant argument", not missing, f"without: {missing}")
required = sorted(t["name"] for t in tools if "tenant" in t["inputSchema"].get("required", []))
check("the tenant argument is optional everywhere", not required, f"required by: {required}")

is_error, reqs = session.call("query", {"query": "up", "tenant": "3:7"})
check(
    "a tenant argument becomes the AccountID and ProjectID headers",
    not is_error
    and len(reqs) == 1
    and reqs[0].get("accountid") == "3"
    and reqs[0].get("projectid") == "7"
    and reqs[0]["path"].startswith("/api/v1/query"),
    f"error={is_error} backend saw {reqs}",
)
check(
    "the forwarded Authorization still reaches the backend",
    len(reqs) == 1 and reqs[0].get("authorization") == CLIENT_TOKEN,
    f"backend saw {reqs}",
)

is_error, reqs = session.call("query", {"query": "up", "tenant": "5"})
check(
    "an account-only tenant sends ProjectID 0",
    not is_error and len(reqs) == 1 and reqs[0].get("accountid") == "5" and reqs[0].get("projectid") == "0",
    f"error={is_error} backend saw {reqs}",
)

# a forwarded AccountID (client sent 99, and the list names it) loses to the argument
check(
    "the tenant argument wins over a forwarded AccountID header",
    len(reqs) == 1 and reqs[0].get("accountid") == "5",
    f"backend saw {reqs}",
)

is_error, reqs = session.call("query", {"query": "up"})
check(
    "without a tenant argument no ProjectID header is sent and the forwarded AccountID stays",
    not is_error and len(reqs) == 1 and "projectid" not in reqs[0] and reqs[0].get("accountid") == "99",
    f"error={is_error} backend saw {reqs}",
)

plain = Session({"Authorization": CLIENT_TOKEN})
is_error, reqs = plain.call("query", {"query": "up"})
check(
    "without a tenant argument no tenant headers are sent",
    not is_error and len(reqs) == 1 and "accountid" not in reqs[0] and "projectid" not in reqs[0],
    f"error={is_error} backend saw {reqs}",
)
is_error, reqs = plain.call("query", {"query": "up", "tenant": ""})
check(
    "an empty tenant argument counts as absent",
    not is_error and len(reqs) == 1 and "accountid" not in reqs[0] and "projectid" not in reqs[0],
    f"error={is_error} backend saw {reqs}",
)

for bad in ["x/../y", "a:b", "1:2:3", "-1:2", "4294967296:1", " 3:7", "3:7\r\nX-Evil: 1", 1, ["3:7"]]:
    for tool, args in [("query", {"query": "up"}), ("labels", {}), ("series", {"match": "up"})]:
        is_error, reqs = plain.call(tool, {**args, "tenant": bad})
        check(
            f"{tool}: tenant {bad!r} is refused before any request",
            is_error and not reqs,
            f"error={is_error} backend saw {reqs}",
        )

proc.kill()
proc.wait()
if failures:
    print("\n".join(failures), file=sys.stderr)
    print(f"--- server stderr ---\n{stderr()}", file=sys.stderr)
    sys.exit(1)
