"""Run the real mcp-victoriatraces binary against a recording HTTP backend and
check which headers of the client's MCP request reach the backend.

usage: mcp-passthrough.py <path to mcp-victoriatraces>

Each call goes through the `trace` tool; its trace_id shows up in the backend
request path, which ties every backend request to the call that caused it.
The server's stderr is captured and printed when a server does not become
ready or a case fails.
"""

import http.client
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import namedtuple
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BINARY = sys.argv[1]
TRACE_PATH = "/select/jaeger/api/traces/"
INIT_PARAMS = {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {"name": "t", "version": "0"},
}

# Obviously fake fixtures for a throwaway backend.
CLIENT_TOKEN = "Bearer client-fixture-token"  # gitleaks:allow
INSTANCE_HEADER_TOKEN = "Bearer instance-header-fixture-token"  # gitleaks:allow
INSTANCE_BEARER_TOKEN = "instance-bearer-fixture-token"  # gitleaks:allow
CALLER_TOKENS = {
    "alice": "Bearer alice-fixture-token",  # gitleaks:allow
    "bob": "Bearer bob-fixture-token",  # gitleaks:allow
}

seen = []  # one dict of lower-cased request headers (plus "path") per backend request
Run = namedtuple("Run", "requests stderr")


class Backend(BaseHTTPRequestHandler):
    def do_GET(self):
        # A short delay keeps concurrent calls overlapping inside the server.
        time.sleep(0.005)
        seen.append({**{k.lower(): v for k, v in self.headers.items()}, "path": self.path})
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


class Server:
    """The binary under test, with stderr captured into a file."""

    def __init__(self, mode, extra_env):
        self.mode = mode
        self.port = free_port()
        env = {
            "PATH": os.environ["PATH"],
            "VT_INSTANCE_ENTRYPOINT": ENTRYPOINT,
            "MCP_SERVER_MODE": mode,
            **extra_env,
        }
        if mode != "stdio":
            env["MCP_LISTEN_ADDR"] = f"127.0.0.1:{self.port}"
        self.errfile = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(
            [BINARY],
            env=env,
            stdin=subprocess.PIPE if mode == "stdio" else subprocess.DEVNULL,
            stdout=subprocess.PIPE if mode == "stdio" else subprocess.DEVNULL,
            stderr=self.errfile,
            text=True,
        )

    def stderr(self):
        self.errfile.seek(0)
        return self.errfile.read().decode(errors="replace")

    def wait_ready(self):
        for _ in range(100):
            if self.proc.poll() is not None:
                break
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/health/readiness", timeout=2
                )
                return
            except (urllib.error.URLError, OSError):
                time.sleep(0.2)
        raise SystemExit(
            f"mcp-victoriatraces ({self.mode}) did not become ready; stderr:\n{self.stderr()}"
        )

    def close(self):
        self.proc.kill()
        self.proc.wait()
        self.errfile.close()


def tool_call(rid, marker):
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "method": "tools/call",
        "params": {"name": "trace", "arguments": {"trace_id": marker}},
    }


def rpc(url, headers, sid, body):
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


class HttpSession:
    """A streamable-http MCP client that sends `headers` on every request."""

    def __init__(self, port, headers):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.headers = headers
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS}
        self.sid, _ = rpc(self.url, headers, None, init)
        note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        rpc(self.url, headers, self.sid, note)

    def call(self, rid, marker):
        _, text = rpc(self.url, self.headers, self.sid, tool_call(rid, marker))
        return text


class SseSession:
    """An sse-mode MCP client: replies to POSTs arrive on the event stream."""

    def __init__(self, port, headers):
        self.port = port
        self.headers = headers
        self.replies = queue.Queue()
        self.stream = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
        self.stream.request("GET", "/sse", headers=headers)
        self.resp = self.stream.getresponse()
        endpoint = queue.Queue()
        threading.Thread(target=self._read, args=(endpoint,), daemon=True).start()
        self.endpoint = endpoint.get(timeout=20)
        self._post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS})
        self.replies.get(timeout=20)
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self, endpoint):
        event = None
        try:
            for raw in self.resp:
                line = raw.decode().rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    data = line[5:].strip()
                    if event == "endpoint":
                        endpoint.put(data)
                    else:
                        self.replies.put(data)
        except (OSError, ValueError):
            pass  # close() or the server ended the stream; a missing reply fails the waiting caller

    def _post(self, body):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        conn.request(
            "POST",
            self.endpoint,
            json.dumps(body),
            {"Content-Type": "application/json", **self.headers},
        )
        status = conn.getresponse().status
        conn.close()
        assert status in (200, 202), f"sse message POST returned {status}"

    def call(self, rid, marker):
        self._post(tool_call(rid, marker))
        return self.replies.get(timeout=20)

    def close(self):
        self.stream.close()


def call_once(mode, extra_env, client_headers=None):
    """Start the server in `mode`, make one `trace` call carrying
    client_headers on every request, return the backend's requests."""
    server = Server(mode, extra_env)
    try:
        if mode == "stdio":
            text = stdio_call(server)
        else:
            server.wait_ready()
            session = (HttpSession if mode == "http" else SseSession)(
                server.port, client_headers or {}
            )
            del seen[:]
            text = session.call(2, "marker-1")
            if mode == "sse":
                session.close()
        assert "svc" in text, f"tool call did not reach the backend: {text!r}"
        return Run(list(seen), server.stderr())
    except BaseException:
        print(f"--- {mode} server stderr ---\n{server.stderr()}", file=sys.stderr)
        raise
    finally:
        server.close()


def stdio_call(server):
    proc = server.proc
    for m in (
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
    ):
        proc.stdin.write(json.dumps(m) + "\n")
    proc.stdin.flush()
    proc.stdout.readline()  # initialize result
    del seen[:]
    proc.stdin.write(json.dumps(tool_call(2, "marker-1")) + "\n")
    proc.stdin.flush()
    return proc.stdout.readline()


failures = []


def check(name, ok, detail, run=None):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(f"{name}: {detail}")
        if run is not None:
            failures.append(f"  server stderr:\n{run.stderr}")


def header_of(run, name="authorization"):
    assert len(run.requests) == 1, f"expected exactly one backend request, got {run.requests}"
    return run.requests[0].get(name)


def check_authorization(name, run, expected):
    got = header_of(run)
    check(name, got == expected, f"backend saw Authorization={got!r}, expected {expected!r}", run)


CLIENT = {"Authorization": CLIENT_TOKEN}
INSTANCE = {
    "VT_INSTANCE_HEADERS": f"Authorization={INSTANCE_HEADER_TOKEN}",
    "VT_INSTANCE_BEARER_TOKEN": INSTANCE_BEARER_TOKEN,
}

run = call_once("http", {"MCP_PASSTHROUGH_HEADERS": "Authorization"}, CLIENT)
check_authorization("a listed header reaches the backend", run, CLIENT_TOKEN)

# AccountID is on the list, but the tool's tenant argument is applied last.
run = call_once(
    "http",
    {"MCP_PASSTHROUGH_HEADERS": "Authorization,AccountID"},
    {**CLIENT, "AccountID": "99"},
)
check(
    "a forwarded AccountID header cannot override the tenant argument",
    header_of(run, "accountid") == "0" and header_of(run) == CLIENT_TOKEN,
    f"backend saw {run.requests}",
    run,
)

run = call_once("http", {}, CLIENT)
check_authorization("nothing is forwarded without MCP_PASSTHROUGH_HEADERS", run, None)

run = call_once(
    "http", {"MCP_PASSTHROUGH_HEADERS": "Authorization"}, {**CLIENT, "X-Not-Listed": "leak"}
)
check(
    "an unlisted header is not forwarded",
    header_of(run) == CLIENT_TOKEN and "x-not-listed" not in run.requests[0],
    f"backend saw {run.requests}",
    run,
)

run = call_once("http", INSTANCE, {})
check_authorization(
    "without a forwarded header the instance headers apply", run, INSTANCE_HEADER_TOKEN
)

run = call_once("http", {**INSTANCE, "MCP_PASSTHROUGH_HEADERS": "Authorization"}, CLIENT)
check_authorization(
    "a forwarded header overrides the instance headers and the bearer token", run, CLIENT_TOKEN
)

run = call_once(
    "http", {**INSTANCE, "MCP_PASSTHROUGH_HEADERS": "Authorization"}, {"X-Unrelated": "1"}
)
check_authorization(
    "a listed header the client did not send leaves the instance value alone",
    run,
    INSTANCE_HEADER_TOKEN,
)

run = call_once("http", {"MCP_PASSTHROUGH_HEADERS": " , authorization , "}, CLIENT)
check_authorization("listed names are case-insensitive and trimmed", run, CLIENT_TOKEN)

# stdio has no incoming HTTP request: the setting changes nothing.
run = call_once("stdio", {**INSTANCE, "MCP_PASSTHROUGH_HEADERS": "Authorization"})
check_authorization("stdio mode keeps using the instance headers", run, INSTANCE_HEADER_TOKEN)

run = call_once("sse", {"MCP_PASSTHROUGH_HEADERS": "Authorization"}, CLIENT)
check_authorization("sse mode forwards a listed header", run, CLIENT_TOKEN)


def concurrent_callers(calls_per_caller=20):
    """Two callers with different tokens call the same server in parallel;
    every backend request must carry exactly its own caller's token."""
    server = Server("http", {"MCP_PASSTHROUGH_HEADERS": "Authorization"})
    errors = []
    try:
        server.wait_ready()
        sessions = {
            who: HttpSession(server.port, {"Authorization": token})
            for who, token in CALLER_TOKENS.items()
        }
        del seen[:]
        barrier = threading.Barrier(len(sessions))

        def worker(who):
            try:
                barrier.wait()
                for i in range(calls_per_caller):
                    text = sessions[who].call(100 + i, f"{who}-{i}")
                    assert "svc" in text, f"{who}-{i}: {text!r}"
            except BaseException as e:  # reported by the main thread
                errors.append(f"{who}: {e!r}")

        threads = [threading.Thread(target=worker, args=(who,)) for who in sessions]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=120)
        return list(seen), errors, server.stderr()
    finally:
        server.close()


requests, errors, err = concurrent_callers()
wrong = []
for r in requests:
    who = r["path"][len(TRACE_PATH):].rsplit("-", 1)[0]
    if r.get("authorization") != CALLER_TOKENS[who]:
        wrong.append((r["path"], r.get("authorization")))
check(
    "concurrent callers never see each other's token",
    not errors and not wrong and len(requests) == 2 * 20,
    f"{len(requests)} backend requests, wrong token on {wrong}, client errors {errors}",
    Run(requests, err),
)

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
