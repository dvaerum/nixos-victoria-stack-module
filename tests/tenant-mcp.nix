{ pkgs, nixosModule }:

# A tenant token through the MCP servers (docs/decisions/0032). The servers
# forward the CALLER's Authorization to vmauth's read tier, where the tenant
# stamp applies: the caller sees exactly its tenant, and nothing the tool
# arguments say can change that. `machine` is the real stack (data per tenant,
# every token kind x every MCP server); `recorder` has a recording fake in
# place of the backends, so "the backend never saw it" is checkable.
let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) otlpMetricGenerator;

  yaml = name: text: "${pkgs.writeText name text}";

  # c is declared but nobody writes to it; account 4 is not declared.
  tenants = {
    a.accountId = 1;
    b.accountId = 2;
    c = {
      accountId = 3;
      projectId = 7;
    };
  };

  adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";

  readTokens = yaml "read.yaml" ''
    tokens:
      - token: read-a # gitleaks:allow
        tenant: a
      - token: read-b # gitleaks:allow
        tenant: b
      - token: read-list # gitleaks:allow
        tenants: [a, b]
      - token: read-all # gitleaks:allow
        tenants: all
      - token: read-plain # gitleaks:allow
      - token: read-a-logs-only # gitleaks:allow
        tenant: a
        backends: [logs]
  '';

  allServices = {
    metrics = {
      enable = true;
      mcp.enable = true;
    };
    logs = {
      enable = true;
      mcp.enable = true;
    };
    traces = {
      enable = true;
      mcp.enable = true;
    };
  };

  fakeBackend = pkgs.writeText "tenant-mcp-fake-backend.py" ''
    import http.server


    class Handler(http.server.BaseHTTPRequestHandler):
        def handle_any(self):
            with open("/var/lib/fake-backend/requests.log", "a") as f:
                f.write(f"{self.requestline} | AccountID={self.headers.get('AccountID')}"
                        f" ProjectID={self.headers.get('ProjectID')}"
                        f" X-Injected={self.headers.get('X-Injected')}\n")
            body = b'{"status":"success","data":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = handle_any
        do_POST = handle_any

        def log_message(self, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", 9101), Handler).serve_forever()
  '';

  clientPython = ''
    import json
    import shlex

    HDRS = "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'"
    VMAUTH = "http://127.0.0.1:4204"
    ADMIN = "admin:admin-password-value"


    def auth(token):
        return "-u " + shlex.quote(ADMIN) if token == "admin" else "-H " + shlex.quote("Authorization: Bearer " + token)


    def post(node, route, body, token, session=None):
        sess = f"-H 'Mcp-Session-Id: {session}' " if session else ""
        out = node.succeed(
            f"curl -s -D - {auth(token)} {HDRS} {sess}"
            f"-X POST '{VMAUTH}/mcp/{route}' -d {shlex.quote(json.dumps(body))}"
        ).replace("\r\n", "\n")
        head, _, payload = out.partition("\n\n")
        status = int(head.split()[1])
        sid = next((l.split(":", 1)[1].strip() for l in head.splitlines()
                    if l.lower().startswith("mcp-session-id:")), None)
        data = "".join(l[5:] for l in payload.splitlines() if l.startswith("data:")) or payload
        return status, sid, data


    INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "victoria-stack-test", "version": "1.0"}}}


    def open_session(node, route, token):
        status, sid, data = post(node, route, INIT, token)
        if status != 200:
            return status, data, None
        post(node, route, {"jsonrpc": "2.0", "method": "notifications/initialized"}, token, sid)
        return status, data, sid


    def call(node, route, token, sid, tool, arguments):
        status, _, data = post(node, route, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                             "params": {"name": tool, "arguments": arguments}}, token, sid)
        return status, json.loads(data)


    def tool_text(r):
        return "".join(c.get("text", "") for c in r.get("result", {}).get("content", []))


    def is_error(r):
        return "error" in r or r.get("result", {}).get("isError", False)
  '';

in
{
  # Real stack, real MCP servers, through vmauth /mcp/<svc>: every token kind x
  # server, with and without a tool `tenant` argument naming another tenant.
  tenant-callers = pkgs.testers.nixosTest {
    name = "victoria-stack-tenant-mcp-callers";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = allServices // {
        inherit tenants;
        vmauth = {
          inherit adminPasswordFile;
          readTokensFile = readTokens;
          writeTokensFile = yaml "write.yaml" ''
            tokens:
              - token: write-a # gitleaks:allow
                tenant: a
              - token: write-b # gitleaks:allow
                tenant: b
              - token: write-plain # gitleaks:allow
          '';
          # Neither an operator route nor a lookalike of the MCP prefix is a tenant's.
          extraReadUrlMap = [
            {
              src_paths = [ "/ops/.*" ];
              url_prefix = "http://127.0.0.1:4202/";
            }
            {
              src_paths = [ "/mcp/extra(/.*)?" ];
              url_prefix = "http://127.0.0.1:4202/";
            }
          ];
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      import posixpath
      import re
      import time
      import urllib.parse
      ${clientPython}
      NAME = re.compile(r"probe[-_](?:m|log|svc)[-_]\w+")

      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "victorialogs", "victoriatraces", "mcp-victoriametrics",
                   "mcp-victorialogs", "mcp-victoriatraces", "vmauth"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4204)


      def http(path, token=None, headers=(), method="GET", data=None):
          cmd = f"curl -s -g --path-as-is -w '\\n%{{http_code}}' -X {method} "
          if token:
              cmd += auth(token) + " "
          for h in headers:
              cmd += f"-H {shlex.quote(h)} "
          if data is not None:
              cmd += f"--data-binary {shlex.quote(data)} "
          out = machine.succeed(cmd + shlex.quote(VMAUTH + path))
          body, code = out.rsplit("\n", 1)
          return code.strip(), body


      # ---- data: one write token per tenant, every signal ----
      def send_metric(token, name):
          machine.succeed(f"${otlpMetricGenerator}/bin/gen-otlp-metric {name} 1 > /tmp/m.bin")
          code, body = http("/opentelemetry/v1/metrics", token, ["Content-Type: application/x-protobuf"], "POST", "@/tmp/m.bin")
          assert code == "200", (token, name, code, body)


      def send_log(token, message):
          body = f"MESSAGE={message}\n__REALTIME_TIMESTAMP={int(time.time())}000000\n_HOSTNAME=h\n\n"
          code, out = http("/insert/journald/upload?_stream_fields=_HOSTNAME", token,
                           ["Content-Type: application/vnd.fdo.journal"], "POST", body)
          assert code == "200", (token, message, code, out)


      def send_span(token, service, n):
          now = time.time_ns()
          payload = json.dumps({"resourceSpans": [{
              "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
              "scopeSpans": [{"spans": [{
                  "traceId": f"{n:032x}", "spanId": f"{n:016x}", "name": "op", "kind": 1,
                  "startTimeUnixNano": str(now), "endTimeUnixNano": str(now)}]}]}]})
          code, out = http("/insert/opentelemetry/v1/traces", token, ["Content-Type: application/json"], "POST", payload)
          assert code == "200", (token, service, code, out)


      for n, (token, who) in enumerate([("write-a", "a"), ("write-b", "b"), ("write-plain", "default")], start=1):
          send_metric(token, f"probe_m_{who}")
          send_log(token, f"probe-log-{who}")
          send_span(token, f"probe-svc-{who}", n)

      NOW = int(time.time())
      WIN = {"start": str(NOW - 3600), "end": str(NOW + 60)}
      # Per server, groups of calls whose names are unioned; the groups must agree.
      CALLS = {
          "metrics": [
              [("label_values", {"label_name": "__name__", **WIN})],
              [("series", {"match": f"probe_m_{who}", **WIN}) for who in ("a", "b", "default")],
              [("query", {"query": f"probe_m_{who}"}) for who in ("a", "b", "default")],
          ],
          "logs": [[("query", {"query": "*", "start": "2000-01-01T00:00:00Z", "limit": 100})]],
          "traces": [[("services", {})]],
      }
      WHO = {"metrics": "probe_m_{}", "logs": "probe-log-{}", "traces": "probe-svc-{}"}


      def data(route, *who):
          return ("data", sorted(WHO[route].format(w) for w in who))


      def outcome(route, token, tenant=None):
          """What a caller sees: ("init", status) | ("refused",) | ("data", [names]) | ("error", text).
          Every tool of the server must agree."""
          status, body, sid = open_session(machine, route, token)
          if status != 200:
              assert "missing route" in body, (route, token, status, body)
              return ("init", status)
          seen = []
          for group in CALLS[route]:
              names, failure = set(), None
              for tool, args in group:
                  st, r = call(machine, route, token, sid, tool, {**args, **({"tenant": tenant} if tenant else {})})
                  assert st == 200, (route, token, tenant, tool, st, r)
                  if is_error(r):
                      failure = ("refused",) if "missing route" in tool_text(r) else ("error", tool_text(r))
                  else:
                      names |= set(NAME.findall(tool_text(r)))
              seen.append(failure or ("data", sorted(names)))
          assert all(s == seen[0] for s in seen), (route, token, tenant, seen)
          return seen[0]


      def eventually(route, token, tenant, expected):
          for _ in range(60):
              if outcome(route, token, tenant) == expected:
                  return
              time.sleep(2)
          assert outcome(route, token, tenant) == expected, (route, token, tenant)


      # The read API itself shows every sample before the first MCP call.
      for token, who in [("read-a", "a"), ("read-b", "b"), ("read-plain", "default")]:
          for path in [f"/metrics/api/v1/series?match[]=probe_m_{who}&start={NOW - 3600}&end={NOW + 60}",
                       f"/metrics/api/v1/query?query=probe_m_{who}"]:
              for _ in range(90):
                  code, body = http(path, token)
                  if code == "200" and f"probe_m_{who}" in body:
                      break
                  time.sleep(2)
              assert f"probe_m_{who}" in body, (path, token, code, body)

      for route in CALLS:
          eventually(route, "read-a", None, data(route, "a"))
          eventually(route, "read-b", None, data(route, "b"))
          eventually(route, "read-plain", None, data(route, "default"))

      REFUSED = ("refused",)
      MISSING = ("init", 400)
      NONE = ("data", [])

      # Cells: (token, tenant argument) -> what the caller sees.
      #  - a tenant token sees its tenant, whatever the `tenant` argument says;
      #  - list/all tokens pick by the AccountID the MCP server sends, which only the logs and
      #    traces tools can set (metrics sends none: vmauth's 400);
      #  - no key: tenant 0 whatever is asked; admin is unstamped and picks;
      #  - a backend-scoped token has no route to the other servers.
      for route in ("logs", "traces"):
          cells = [
              ("read-a", None, data(route, "a")),
              ("read-a", "2", data(route, "a")),
              ("read-a", "2:5", data(route, "a")),
              ("read-a", "1", data(route, "a")),
              ("read-b", None, data(route, "b")),
              ("read-b", "1", data(route, "b")),
              ("read-list", None, REFUSED),
              ("read-list", "1", data(route, "a")),
              ("read-list", "2", data(route, "b")),
              ("read-list", "1:9", data(route, "a")),
              ("read-list", "3", REFUSED),
              ("read-list", "0", REFUSED),
              ("read-all", None, REFUSED),
              ("read-all", "1", data(route, "a")),
              ("read-all", "2", data(route, "b")),
              ("read-all", "3", NONE),
              ("read-all", "4", REFUSED),
              ("read-plain", None, data(route, "default")),
              ("read-plain", "1", data(route, "default")),
              ("admin", None, data(route, "default")),
              ("admin", "1", data(route, "a")),
              ("admin", "2", data(route, "b")),
          ]
          for token, tenant, expected in cells:
              got = outcome(route, token, tenant)
              assert got == expected, (route, token, tenant, got, expected)
      # A backends scope on a tenant token bounds its MCP routes too.
      for route, tenant, expected in [("logs", None, data("logs", "a")), ("logs", "2", data("logs", "a")),
                                      ("traces", None, MISSING), ("metrics", None, MISSING)]:
          got = outcome(route, "read-a-logs-only", tenant)
          assert got == expected, (route, tenant, got, expected)

      for token, expected in [
          ("read-a", data("metrics", "a")),
          ("read-b", data("metrics", "b")),
          ("read-list", REFUSED),
          ("read-all", REFUSED),
          ("read-plain", data("metrics", "default")),
          ("admin", data("metrics", "default")),
          ("read-a-logs-only", MISSING),
      ]:
          got = outcome("metrics", token)
          assert got == expected, ("metrics", token, got, expected)

      # No credential, an unknown one: vmauth's own 401 before any server.
      for route in CALLS:
          res = post(machine, route, INIT, "an-unknown-token")  # gitleaks:allow
          assert res[0] == 401, (route, res)

      # ---- the MCP prefix gives a tenant token nothing else ----
      def refused_path(path, token, code="400"):
          got, body = http(path, token, ["Content-Type: application/json"], "POST", json.dumps(INIT))
          assert got == code and ("missing route" in body or code != "400"), (path, token, got, body)

      for token in ["read-a", "read-list", "read-all", "read-a-logs-only"]:
          # Lookalikes and siblings of the MCP prefix, and an operator's own route.
          for path in ["/mcp", "/mcp/", "/mcp/other", "/mcp/metricsX", "/mcp/extra", "/mcp/extra/x", "/ops/x",
                       "/flags", "/metrics/api/v1/admin/tsdb/delete_series"]:
              refused_path(path, token)
          # Dot-dot in any spelling: vmauth routes the CLEANED path, so a path that cleans into a
          # route the token holds is that route (nothing more), any other is vmauth's 400.
          for path in [
              "/mcp/metrics/../logs", "/mcp/logs/../../metrics/api/v1/labels", "/mcp/traces/../metrics",
              "/mcp/metrics/%2e%2e/%2e%2e/flags", "/mcp/traces/..%2f..%2fflags",
              "/mcp/metrics/../../select/2/prometheus/api/v1/labels", "/mcp/logs/%2E%2E/%2E%2E/ops/x",
              "/mcp/logs/../../ops/x", "/mcp/logs/../../mcp/extra", "/mcp/logs/../../flags",
          ]:
              got, body = http(path, token, ["Content-Type: application/json"], "POST", json.dumps(INIT))
              # vmauth decodes and cleans the path first (the 400 names the cleaned one).
              cleaned = posixpath.normpath(urllib.parse.unquote(path))
              mcp_held = ["/mcp/logs"] if token == "read-a-logs-only" else ["/mcp/metrics", "/mcp/logs", "/mcp/traces"]
              if cleaned in mcp_held or (token == "read-a" and cleaned == "/metrics/api/v1/labels"):
                  assert got == "200", (token, path, cleaned, got, body)
              else:
                  assert got == "400" and body.strip().endswith(f'missing route for "{cleaned}"'), (token, path, cleaned, got, body)
      # Control: the operator's routes exist (admin is routed, whatever the backend answers).
      for path in ["/mcp/extra", "/ops/x"]:
          code, body = http(path, "admin", ["Content-Type: application/json"], "POST", json.dumps(INIT))
          assert "missing route" not in body, (path, code, body)

      # No token value reached the journal.
      journal = machine.succeed("journalctl -u vmauth.service --no-pager")
      for secret in ["write-a", "write-b", "write-plain", "read-a", "read-b", "read-list", "read-all",
                     "read-plain", "read-a-logs-only", "admin-password-value"]:
          assert secret not in journal, secret
    '';
  };

  # A recording fake in place of the backends: what the MCP servers send on a
  # tenant token's behalf, and what hostile arguments cannot make them send.
  tenant-hostile-arguments = pkgs.testers.nixosTest {
    name = "victoria-stack-tenant-mcp-hostile";

    containers.recorder = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        inherit tenants;
        metrics = {
          enable = true;
          mcp.enable = true;
          effectiveSelectUrl = lib.mkForce "http://127.0.0.1:9101";
        };
        logs = {
          enable = true;
          mcp.enable = true;
          effectiveUrl = lib.mkForce "http://127.0.0.1:9101";
        };
        traces = {
          enable = true;
          mcp.enable = true;
          effectiveUrl = lib.mkForce "http://127.0.0.1:9101";
        };
        vmauth = {
          inherit adminPasswordFile;
          readTokensFile = readTokens;
        };
      };
      systemd.services.fake-backend = {
        wantedBy = [ "multi-user.target" ];
        before = [ "vmauth.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 -I ${fakeBackend}";
          StateDirectory = "fake-backend";
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      ${clientPython}

      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "mcp-victoriametrics", "mcp-victorialogs",
                   "mcp-victoriatraces", "vmauth", "fake-backend"]:
          wait_active(recorder, f"{unit}.service")
      recorder.wait_for_open_port(4204)

      A = "read-a"
      # The fake creates the log on its first request; the first `before` needs it to exist.
      recorder.succeed("touch /var/lib/fake-backend/requests.log")


      def recorded():
          lines = recorder.succeed("cat /var/lib/fake-backend/requests.log").splitlines()
          return [l for l in lines if "/api/v1/import/" not in l]


      def seen_by_backend(route, token, tool, args):
          before = recorded()
          status, _, sid = open_session(recorder, route, token)
          assert status == 200, (route, status)
          st, r = call(recorder, route, token, sid, tool, args)
          return st, r, recorded()[len(before):]


      # Control: tenant a's token reaches the backend as tenant a, with a's headers.
      st, r, new = seen_by_backend("metrics", A, "labels", {})
      assert st == 200 and not is_error(r), r
      assert [l.split(" | ")[0] for l in new] == ["GET /select/1/prometheus/api/v1/labels HTTP/1.1"], new
      st, r, new = seen_by_backend("logs", A, "query", {"query": "*", "start": "2000-01-01T00:00:00Z"})
      assert st == 200 and not is_error(r), r
      assert len(new) == 1 and new[0].endswith("| AccountID=1 ProjectID=0 X-Injected=None"), new
      st, r, new = seen_by_backend("traces", A, "services", {})
      assert st == 200 and not is_error(r), r
      assert len(new) == 1 and new[0].endswith("| AccountID=1 ProjectID=0 X-Injected=None"), new

      # A tool call that NAMES another tenant still reaches the backend as tenant a.
      for tenant in ["2", "2:5", "3:7", "0"]:
          st, r, new = seen_by_backend("logs", A, "query",
                                       {"query": "*", "start": "2000-01-01T00:00:00Z", "tenant": tenant})
          assert len(new) == 1 and new[0].endswith("| AccountID=1 ProjectID=0 X-Injected=None"), (tenant, new)
          st, r, new = seen_by_backend("traces", A, "services", {"tenant": tenant})
          assert len(new) == 1 and new[0].endswith("| AccountID=1 ProjectID=0 X-Injected=None"), (tenant, new)
      # The metrics tools take no tenant: an extra argument is ignored or refused, the path is a's.
      st, r, new = seen_by_backend("metrics", A, "labels", {"tenant": "2"})
      assert [l.split(" | ")[0] for l in new] in ([], ["GET /select/1/prometheus/api/v1/labels HTTP/1.1"]), new

      def hostile(route, token, tool, args, refusal):
          st, r, new = seen_by_backend(route, token, tool, args)
          assert st == 200 and is_error(r) and refusal in tool_text(r), (route, tool, args, r)
          assert new == [], (route, tool, args, new)

      # Arguments that try to steer the path leave vmauth's 400 (the allow-list under
      # /select/1/prometheus/ is closed); the backend sees no request.
      for label in ["x/../../flags", "x\r\nX-Injected: 1", "%2e%2e/%2e%2e/flags",
                    "x/../../../select/2/prometheus/api/v1/labels"]:
          hostile("metrics", A, "label_values", {"label_name": label}, "missing route")
      # The logs tenant must parse as AccountID:ProjectID before anything is sent.
      for tenant in ["0:0/../../flags", "http://evil.example.invalid", "0\r\nX-Injected: 1"]:
          hostile("logs", A, "query", {"query": "*", "start": "2000-01-01T00:00:00Z", "tenant": tenant},
                  "failed to get tenant")
      deep = "../" * 5 + "flags"
      for tool, args in [
          ("trace", {"trace_id": deep}),
          ("trace", {"trace_id": "%2e%2e/" * 5 + "flags"}),
          ("service_operations", {"service_name": "x/" + deep}),
          ("service_operations", {"service_name": "x\r\nX-Injected: 1"}),
      ]:
          hostile("traces", A, tool, args, "missing route")
      # A CRLF tenant is refused by the traces server before a request leaves.
      st, r, new = seen_by_backend("traces", A, "services", {"tenant": "0\r\nX-Injected: 1"})
      assert new == [], new
      # An absolute URL as a name stays a path SEGMENT of the one backend, in tenant a's path.
      st, r, new = seen_by_backend("metrics", A, "label_values", {"label_name": "http://evil.example.invalid/x"})
      assert [l.split(" | ")[0] for l in new] == [
          "GET /select/1/prometheus/api/v1/label/http:/evil.example.invalid/x/values HTTP/1.1"], new
      st, r, new = seen_by_backend("traces", A, "service_operations", {"service_name": "http://evil.example.invalid/x"})
      assert all(l.startswith("GET /select/jaeger/api/services/") and "AccountID=1 ProjectID=0" in l for l in new) and len(new) <= 1, new

      # Nothing outside the stamped paths, and never another tenant's id or header.
      assert not any(" /flags HTTP" in l or "X-Injected=None" not in l for l in recorded()), recorded()
      assert not any("/select/2/" in l or "/select/3/" in l or "AccountID=2" in l or "AccountID=0" in l
                     for l in recorded()), recorded()
    '';
  };
}
