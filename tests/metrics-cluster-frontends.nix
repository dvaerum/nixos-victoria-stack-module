{ pkgs, nixosModule }:

# Grafana, the metrics MCP server and nginx in front of the metrics cluster. Both
# frontends keep speaking the plain Prometheus client paths to vmauth's `/metrics`
# read tier; vmauth rewrites them onto vmselect's
# `/select/0/prometheus/...` (tests/vmauth-cluster.nix), so nothing in the
let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    evalWith
    grafanaReadTokenFile
    vmauthReadTokensWithGrafana
    ;

  table =
    name: checks:
    pkgs.runCommand name { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${name} wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";
  grafanaConsumerConfig = {
    services.grafana = {
      enable = true;
      settings.security.secret_key = "$__file{${secretKeyFixture}}";
    };
  };

  # A Prometheus import path for the write tier, as an operator would add it
  # (the module only derives the OTLP route).
  importRoute = {
    src_paths = [ "/api/v1/import/prometheus" ];
    url_prefix = "http://127.0.0.1:4209/insert/0/prometheus/";
  };
  writeTokens = pkgs.writeText "frontends-write-tokens.yaml" ''
    tokens:
      - token: frontends-write-token # gitleaks:allow
  '';
  readTokens = pkgs.writeText "frontends-read-tokens.yaml" ''
    tokens:
      - token: frontends-metrics-read-token # gitleaks:allow
        backends: ["metrics"]
      - token: frontends-logs-only-read-token # gitleaks:allow
        backends: ["logs"]
  '';
  adminPassword = pkgs.writeText "frontends-admin-password" "frontends-admin-password-value";

  # ---- eval ----
  cluster = evalWith {
    services.victoriaStack = {
      metrics = {
        enable = true;
        mcp.enable = true;
      };
      grafana = {
        enable = true;
        readTokenFile = "${grafanaReadTokenFile}";
      };
      vmauth.readTokensFile = "${vmauthReadTokensWithGrafana}";
      nginx = {
        enable = true;
        domain = "victoria-stack-test.example.com";
      };
    };
    services.grafana.enable = true;
  };

  svc = e: unit: e.config.systemd.services.${unit};
  after = e: unit: (svc e unit).after;
  env = e: unit: (svc e unit).environment;
  # The single-node unit is gone: no frontend may name it either.
  dataUnits = [
    "victoriametrics.service"
    "vmselect.service"
    "vminsert.service"
    "vmstorage.service"
  ];
  datasourceUrls =
    e:
    lib.listToAttrs (
      map (
        d: lib.nameValuePair d.uid d.url
      ) e.config.services.grafana.provision.datasources.settings.datasources
    );

  # ---- booted ----
  mcpClientPython = ''
    import json

    HDRS = "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'"


    def post(node, route, body, auth, session=None):
        sess = f"-H 'Mcp-Session-Id: {session}' " if session else ""
        out = node.succeed(
            f"curl -s -D - {auth} {HDRS} {sess}"
            f"-X POST 'http://127.0.0.1:4204/mcp/{route}' -d '{json.dumps(body)}'"
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


    def open_session(node, route, auth):
        status, sid, data = post(node, route, INIT, auth)
        if status != 200:
            return status, data, None
        post(node, route, {"jsonrpc": "2.0", "method": "notifications/initialized"}, auth, sid)
        return status, data, sid


    def call(node, route, auth, sid, tool, arguments):
        status, _, data = post(node, route, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                             "params": {"name": tool, "arguments": arguments}}, auth, sid)
        return status, json.loads(data)


    def tool_text(r):
        return "".join(c.get("text", "") for c in r.get("result", {}).get("content", []))


    def is_error(r):
        return "error" in r or r.get("result", {}).get("isError", False)
  '';

  fakeBackend = pkgs.writeText "frontends-fake-backend.py" ''
    import http.server


    class Handler(http.server.BaseHTTPRequestHandler):
        def handle_any(self):
            with open("/var/lib/fake-backend/requests.log", "a") as f:
                f.write(f"{self.requestline}\n")
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
in
{
  # --- eval ---

  cluster-frontends-ordering-lists = table "cluster-frontends-ordering" {
    "the metrics MCP waits for vmselect and vmauth, exactly" =
      after cluster "mcp-victoriametrics" == [
        "network.target"
        "vmselect.service"
        "vmauth.service"
      ];
    "grafana and nginx are ordered after no data unit" =
      !(lib.any
        (
          u: lib.any (d: lib.elem d (after cluster u) || lib.elem d ((svc cluster u).wants or [ ])) dataUnits
        )
        [
          "grafana"
          "nginx"
        ]
      );
    "nginx still waits for vmauth and grafana" =
      lib.all (u: lib.elem u (after cluster "nginx") && lib.elem u (svc cluster "nginx").wants)
        [
          "vmauth.service"
          "grafana.service"
        ];
    "vmauth carries the cluster ordering (vmselect and vminsert)" =
      lib.all (u: lib.elem u (after cluster "vmauth"))
        [
          "vmselect.service"
          "vminsert.service"
        ];
    "the MCP entrypoint is vmauth's /metrics prefix, type single" =
      (env cluster "mcp-victoriametrics").VM_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4204/metrics"
      && (env cluster "mcp-victoriametrics").VM_INSTANCE_TYPE == "single"
      && (env cluster "mcp-victoriametrics").MCP_PASSTHROUGH_HEADERS == "Authorization"
      && !(env cluster "mcp-victoriametrics" ? VM_DEFAULT_TENANT_ID);
    "the Grafana metrics datasource is vmauth's /metrics read tier, never vmselect" =
      (datasourceUrls cluster).victoriametrics-ds == "http://127.0.0.1:4204/metrics";
  };

  # --- booted ---

  grafana-reads-the-cluster-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-reads-the-cluster";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
        };
        grafana = {
          enable = true;
          readTokenFile = "${grafanaReadTokenFile}";
        };
        vmauth = {
          adminPasswordFile = "${adminPassword}";
          readTokensFile = "${vmauthReadTokensWithGrafana}";
          writeTokensFile = "${writeTokens}";
          extraWriteUrlMap = [ importRoute ];
        };
      };
    };

    testScript = ''
      import time
      ${testLib.waitActivePython}

      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "vmauth", "grafana"]:
          wait_active(machine, f"{unit}.service")
      for port in [3000, 4204]:
          machine.wait_for_open_port(port)

      admin = "-u admin:admin"  # gitleaks:allow
      viewer = "-u viewer:viewer-fixture-password"  # gitleaks:allow
      grafana = "http://127.0.0.1:3000"
      machine.wait_until_succeeds(f"curl -sf {admin} {grafana}/api/health")
      machine.succeed(
          f"curl -sf {admin} -X POST {grafana}/api/admin/users "
          "-H 'Content-Type: application/json' "
          "-d '{\"name\":\"viewer\",\"login\":\"viewer\",\"password\":\"viewer-fixture-password\"}'"  # gitleaks:allow
      )

      def proxy(path):
          out = machine.succeed(
              f"curl -sg -w '\\n%{{http_code}}' {viewer} "
              f"'{grafana}/api/datasources/proxy/uid/victoriametrics-ds{path}'"
          )
          text, code = out.rsplit("\n", 1)
          return int(code), text

      # The series goes in through vmauth's write route; an old timestamp keeps
      # it readable by an explicit time=, past vmselect's 30 s latency offset.
      old = int(time.time()) - 600
      machine.succeed(
          f"curl -sf -H 'Authorization: Bearer frontends-write-token' -X POST "  # gitleaks:allow
          f"--data-binary 'grafana_cluster_probe 7 {old * 1000}' "
          "http://127.0.0.1:4204/api/v1/import/prometheus"
      )
      win = f"start={old - 60}&end={old + 120}"

      def read_ok(path, needle):
          # A fresh write is not visible at once (flush); poll with a deadline.
          deadline = time.monotonic() + 90
          while True:
              code, text = proxy(path)
              if code == 200 and needle in text:
                  return
              assert time.monotonic() < deadline, (path, code, text[:300])
              time.sleep(2)

      read_ok(f"/api/v1/query?query=grafana_cluster_probe&time={old + 30}", '"value":[' + str(old + 30) + ',"7"]')
      read_ok(f"/api/v1/query_range?query=grafana_cluster_probe&{win}&step=30", '"values":[[')
      read_ok(f"/api/v1/series?match[]=grafana_cluster_probe&{win}", '"__name__":"grafana_cluster_probe"')
      read_ok(f"/api/v1/labels?{win}", '"__name__"')
      read_ok(f"/api/v1/label/__name__/values?{win}", '"grafana_cluster_probe"')
      # The Metrics browser loads this together with the label values and shows
      # "Failed to load metrics" when either fails (docs/decisions/0021).
      read_ok("/api/v1/metadata", '"status":"success"')

      # The datasource still goes through vmauth's closed list: the cluster's
      # own paths and every write are refused by vmauth itself.
      for method, path in [
          ("GET", "/select/0/prometheus/api/v1/labels"),
          ("GET", "/api/v1/status/tsdb"),
          ("POST", "/api/v1/admin/tsdb/delete_series?match[]=grafana_cluster_probe"),
          ("POST", "/api/v1/import/prometheus"),
      ]:
          out = machine.succeed(
              f"curl -sg -w '\\n%{{http_code}}' {viewer} -X {method} "
              f"'{grafana}/api/datasources/proxy/uid/victoriametrics-ds{path}'"
          )
          text, code = out.rsplit("\n", 1)
          assert code == "400" and "missing route" in text, (method, path, code, text[:300])
      # ...and nothing was deleted.
      read_ok(f"/api/v1/series?match[]=grafana_cluster_probe&{win}", '"__name__":"grafana_cluster_probe"')
    '';
  };

  metrics-mcp-reads-the-cluster-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-mcp-reads-the-cluster";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        logs.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPassword}";
          readTokensFile = "${readTokens}";
          writeTokensFile = "${writeTokens}";
          extraWriteUrlMap = [ importRoute ];
        };
      };
    };

    # vmauth's metrics backend is a recording fake: it sees every request vmauth
    # lets through, so "never reached vmselect" is checkable.
    containers.recorder = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
          effectiveSelectUrl = lib.mkForce "http://127.0.0.1:9101";
        };
        vmauth.adminPasswordFile = "${adminPassword}";
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
      import time
      ${testLib.waitActivePython}
      ${mcpClientPython}

      READ = "-H 'Authorization: Bearer frontends-metrics-read-token'"  # gitleaks:allow
      LOGS_ONLY = "-H 'Authorization: Bearer frontends-logs-only-read-token'"  # gitleaks:allow
      ADMIN = "-u admin:frontends-admin-password-value"  # gitleaks:allow

      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "vmauth", "mcp-victoriametrics"]:
          wait_active(machine, f"{unit}.service")
          wait_active(recorder, f"{unit}.service")
      machine.wait_for_open_port(4204)
      recorder.wait_for_open_port(4204)

      old = int(time.time()) - 600
      machine.succeed(
          f"curl -sf -H 'Authorization: Bearer frontends-write-token' -X POST "  # gitleaks:allow
          f"--data-binary 'mcp_cluster_probe{{job=\"mcp_probe_job\"}} 7 {old * 1000}' "
          "http://127.0.0.1:4204/api/v1/import/prometheus"
      )
      win = {"start": str(old - 60), "end": str(old + 120)}

      def until(route, token, tool, args, needle):
          deadline = time.monotonic() + 90
          while True:
              status, _, sid = open_session(machine, route, token)
              assert status == 200, (route, status)
              status, r = call(machine, route, token, sid, tool, args)
              if status == 200 and not is_error(r) and needle in tool_text(r):
                  return
              assert time.monotonic() < deadline, (tool, args, status, r)
              time.sleep(2)

      for token in [READ, ADMIN]:
          until("metrics", token, "labels", win, "job")
          until("metrics", token, "label_values", {"label_name": "job", **win}, "mcp_probe_job")
          until("metrics", token, "label_values", {"label_name": "__name__", **win}, "mcp_cluster_probe")
          until("metrics", token, "series", {"match": "mcp_cluster_probe", **win}, "mcp_cluster_probe")
          until("metrics", token, "query", {"query": "mcp_cluster_probe", "time": str(old + 30)}, "mcp_cluster_probe")
      # The tool answers; the data of a fresh series is not what it is about.
      status, _, sid = open_session(machine, "metrics", READ)
      status, r = call(machine, "metrics", READ, sid, "metrics_metadata", {})
      assert status == 200 and not is_error(r), r

      # A token without the metrics backend gets vmauth's own refusal.
      status, _, data = post(machine, "metrics", INIT, LOGS_ONLY)
      assert status == 400 and "missing route" in data, (status, data)
      status, _, data = post(machine, "metrics", INIT, "")
      assert status == 401, (status, data)

      # ---- the recording front: what vmselect would have been sent ----
      def recorded():
          lines = recorder.succeed("cat /var/lib/fake-backend/requests.log").splitlines()
          return [l.split(" HTTP/")[0] for l in lines]

      status, _, sid = open_session(recorder, "metrics", ADMIN)
      assert status == 200
      call(recorder, "metrics", ADMIN, sid, "labels", {})
      assert recorded() == ["GET /select/0/prometheus/api/v1/labels"], recorded()

      def hostile(args):
          before = recorded()
          _, _, sid = open_session(recorder, "metrics", ADMIN)
          st, r = call(recorder, "metrics", ADMIN, sid, "label_values", args)
          assert st == 200 and is_error(r) and "400: user admin missing route" in tool_text(r), (args, r)
          assert recorded() == before, (args, recorded()[len(before):])

      for label in ["x/../../flags", "x\r\nX-Injected: 1", "%2e%2e/%2e%2e/flags", "x/../../../select/1/prometheus/api/v1/labels"]:
          hostile({"label_name": label})

      # An absolute URL stays a path SEGMENT of the one cluster endpoint.
      before = recorded()
      _, _, sid = open_session(recorder, "metrics", ADMIN)
      call(recorder, "metrics", ADMIN, sid, "label_values", {"label_name": "http://evil.example.invalid/x"})
      assert recorded()[len(before):] == [
          "GET /select/0/prometheus/api/v1/label/http:/evil.example.invalid/x/values"
      ], recorded()
    '';
  };
}
