"""Run the real mcp-victoriatraces binary against a recording HTTP backend and
check which headers of the client's MCP request reach the backend.

usage: mcp-passthrough.py <path to mcp-victoriatraces>
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BINARY = sys.argv[1]
seen = []  # one dict of lower-cased request headers per backend request


class Backend(BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append({k.lower(): v for k, v in self.headers.items()})
        out = b'{"data":["svc"]}'
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
ENTRYPOINT = f"http://127.0.0.1:{backend.server_address[1]}"


def env_for(mode, extra):
    env = {
        "PATH": os.environ["PATH"],
        "VT_INSTANCE_ENTRYPOINT": ENTRYPOINT,
        "MCP_SERVER_MODE": mode,
    }
    env.update(extra)
    return env


def rpc(url, headers, sid, method, params=None, rid=None):
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if rid is not None:
        body["id"] = rid
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **headers,
    }
    if sid:
        h["Mcp-Session-Id"] = sid
    req = urllib.request.Request(url, json.dumps(body).encode(), h, method="POST")
    resp = urllib.request.urlopen(req, timeout=20)
    return resp.headers.get("Mcp-Session-Id"), resp.read().decode()


def call_over_http(extra_env, client_headers):
    """Start the server in http mode, call the `services` tool with
    client_headers on every request, return the backend's requests."""
    port = free_port()
    proc = subprocess.Popen(
        [BINARY],
        env=env_for("http", {"MCP_LISTEN_ADDR": f"127.0.0.1:{port}", **extra_env}),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health/readiness", timeout=2
                )
                break
            except (urllib.error.URLError, OSError):
                time.sleep(0.2)
        else:
            raise SystemExit("mcp-victoriatraces did not become ready")
        url = f"http://127.0.0.1:{port}/mcp"
        sid, _ = rpc(
            url,
            client_headers,
            None,
            "initialize",
            {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "t", "version": "0"},
            },
            1,
        )
        rpc(url, client_headers, sid, "notifications/initialized")
        del seen[:]
        _, text = rpc(
            url,
            client_headers,
            sid,
            "tools/call",
            {"name": "services", "arguments": {}},
            2,
        )
        assert "svc" in text, f"tool call did not reach the backend: {text!r}"
        return list(seen)
    finally:
        proc.kill()
        proc.wait()


def call_over_stdio(extra_env):
    proc = subprocess.Popen(
        [BINARY],
        env=env_for("stdio", extra_env),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        msgs = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "t", "version": "0"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
        for m in msgs:
            proc.stdin.write(json.dumps(m) + "\n")
        proc.stdin.flush()
        proc.stdout.readline()  # initialize result
        del seen[:]
        proc.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {"name": "services", "arguments": {}},
                }
            )
            + "\n"
        )
        proc.stdin.flush()
        out = proc.stdout.readline()
        assert "svc" in out, f"stdio tool call failed: {out!r}"
        return list(seen)
    finally:
        proc.kill()
        proc.wait()


CLIENT = {"Authorization": "Bearer CLIENT-TOKEN"}
failures = []


def check(name, ok, detail):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(f"{name}: {detail}")


def auth_of(reqs):
    assert len(reqs) == 1, f"expected exactly one backend request, got {reqs}"
    return reqs[0].get("authorization")


# (a) listed header is forwarded
r = call_over_http({"MCP_PASSTHROUGH_HEADERS": "Authorization,AccountID"}, CLIENT)
check(
    "(a) a listed header reaches the backend",
    auth_of(r) == "Bearer CLIENT-TOKEN",
    f"backend saw Authorization={auth_of(r)!r}",
)

# (b) off by default
r = call_over_http({}, CLIENT)
check(
    "(b) nothing is forwarded without MCP_PASSTHROUGH_HEADERS",
    auth_of(r) is None,
    f"backend saw Authorization={auth_of(r)!r}",
)

# (c) only the listed names are forwarded
r = call_over_http(
    {"MCP_PASSTHROUGH_HEADERS": "Authorization"},
    {**CLIENT, "X-Not-Listed": "leak"},
)
check(
    "(c) an unlisted header is not forwarded",
    auth_of(r) == "Bearer CLIENT-TOKEN" and "x-not-listed" not in r[0],
    f"backend saw {r}",
)

# (d) a forwarded header wins over the instance headers and bearer token
instance = {
    "VT_INSTANCE_HEADERS": "Authorization=Bearer INSTANCE-HEADER",
    "VT_INSTANCE_BEARER_TOKEN": "INSTANCE-BEARER",
}
r = call_over_http(instance, {})
check(
    "(d0) control: VT_INSTANCE_HEADERS applies when nothing is forwarded",
    auth_of(r) == "Bearer INSTANCE-HEADER",
    f"backend saw Authorization={auth_of(r)!r}",
)
r = call_over_http({**instance, "MCP_PASSTHROUGH_HEADERS": "Authorization"}, CLIENT)
check(
    "(d) a forwarded header overrides VT_INSTANCE_HEADERS and the bearer token",
    auth_of(r) == "Bearer CLIENT-TOKEN",
    f"backend saw Authorization={auth_of(r)!r}",
)
r = call_over_http(
    {**instance, "MCP_PASSTHROUGH_HEADERS": "Authorization"},
    {"X-Unrelated": "1"},
)
check(
    "(d2) a listed header the client did not send leaves the instance value alone",
    auth_of(r) == "Bearer INSTANCE-HEADER",
    f"backend saw Authorization={auth_of(r)!r}",
)

# (e) names are case-insensitive, entries are trimmed
r = call_over_http({"MCP_PASSTHROUGH_HEADERS": " , authorization , "}, CLIENT)
check(
    "(e) listed names are case-insensitive and trimmed",
    auth_of(r) == "Bearer CLIENT-TOKEN",
    f"backend saw Authorization={auth_of(r)!r}",
)

# (f) stdio has no incoming HTTP request: the setting changes nothing
r = call_over_stdio({**instance, "MCP_PASSTHROUGH_HEADERS": "Authorization"})
check(
    "(f) stdio mode keeps using the instance headers",
    auth_of(r) == "Bearer INSTANCE-HEADER",
    f"backend saw Authorization={auth_of(r)!r}",
)

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
