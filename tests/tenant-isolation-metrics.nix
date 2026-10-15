{ pkgs, nixosModule }:

# Metrics tenants through vmauth: a tenant token is routed to the tenant's own
# `/select/<id>/prometheus/` and `/insert/<id>/` path of the cluster, a list/all
# token picks by the AccountID header, a different tenant in the client path is
# vmauth's 400. `metrics` runs the real vminsert/vmselect with the spoofing
# rows; `combined` runs the same token x operation matrix over metrics, logs
# and traces at once. projectId is not used by metrics.
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

  vmauthTokens = {
    adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";
    writeTokensFile = yaml "write.yaml" ''
      tokens:
        - token: write-a # gitleaks:allow
          tenant: a
        - token: write-b # gitleaks:allow
          tenant: b
        - token: write-plain # gitleaks:allow
        - token: write-list # gitleaks:allow
          tenants: [a]
    '';
    readTokensFile = yaml "read.yaml" ''
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
    '';
  };

  # Shared by both boot tests: curl through vmauth, one writer and one reader
  # per backend, and the expectation of every (read token, AccountID) cell.
  matrixPython = ''
    import json
    import shlex
    import time
    import urllib.parse

    VMAUTH = "http://127.0.0.1:4204"
    ADMIN = "admin:admin-password-value"
    START = int(time.time()) - 3600
    PICKS = [1, 2, 3, 4, None]
    KINDS = ["read-plain", "read-a", "read-b", "read-list", "read-all", "admin"]


    def curl_cmd(path, token=None, headers=(), method="GET", data=None, basic=None):
        cmd = f"curl -s -g --path-as-is -w '\\n%{{http_code}}' -X {method} "
        if token:
            cmd += f"-H {shlex.quote('Authorization: Bearer ' + token)} "
        if basic:
            cmd += f"-u {shlex.quote(basic)} "
        for h in headers:
            cmd += f"-H {shlex.quote(h)} "
        if data is not None:
            cmd += f"--data-binary {shlex.quote(data)} "
        return cmd + shlex.quote(VMAUTH + path)


    def http(path, token=None, headers=(), method="GET", data=None, basic=None):
        out = machine.succeed(curl_cmd(path, token, headers, method, data, basic))
        body, code = out.rsplit("\n", 1)
        return code.strip(), body


    def http_batch(specs):
        # Many requests in ONE driver round trip: each machine.succeed costs
        # far more on a loaded host than the curl it runs (the hundreds of
        # refusal probes below took minutes as single calls). `set -e` keeps
        # a failing curl as fatal as it is in http().
        script = "set -e\n" + "".join(curl_cmd(**sp) + "; printf '\\n@@END@@\\n'\n" for sp in specs)
        out = machine.succeed(f"sh -c {shlex.quote(script)}")
        results = []
        for chunk in out.split("\n@@END@@\n")[:-1]:
            body, code = chunk.rsplit("\n", 1)
            results.append((code.strip(), body))
        assert len(results) == len(specs), (len(results), len(specs))
        return results


    def rows(res, parse):
        # (status, visible rows); a refusal is (status, "missing route") so a
        # 400 from anything but vmauth's route table does not pass.
        code, body = res
        if code == "200":
            return code, sorted(parse(body))
        return code, ("missing route" if "missing route" in body else body)


    def hdr(pick):
        return [] if pick is None else [f"AccountID: {pick}"]


    # ---- metrics: OTLP in, label values out ----
    def send_metric(token, name, headers=(), path="/opentelemetry/v1/metrics"):
        machine.succeed(f"${otlpMetricGenerator}/bin/gen-otlp-metric {name} 1 > /tmp/m.bin")
        return http(path, token, ["Content-Type: application/x-protobuf", *headers], "POST", "@/tmp/m.bin")


    def metric_names(token, headers=(), basic=None, extra=""):
        q = urllib.parse.quote('{__name__=~"probe_.*"}', safe="")
        return rows(
            http(f"/metrics/api/v1/label/__name__/values?match[]={q}&start={START}{extra}", token, headers, basic=basic),
            lambda b: json.loads(b)["data"])


    # ---- logs ----
    def send_log(token, message, headers=()):
        body = f"MESSAGE={message}\n__REALTIME_TIMESTAMP={int(time.time())}000000\n_HOSTNAME=h\n\n"
        return http("/insert/journald/upload?_stream_fields=_HOSTNAME", token,
                    ["Content-Type: application/vnd.fdo.journal", *headers], "POST", body)


    def log_rows(token, headers=(), basic=None):
        return rows(http("/logs/select/logsql/query", token, headers, "POST", "query=*", basic),
                    lambda b: [m for m in (json.loads(l)["_msg"] for l in b.splitlines() if l.strip())
                               if m.startswith("probe-")])


    # ---- traces ----
    def send_span(token, service, n, headers=()):
        now = time.time_ns()
        payload = json.dumps({"resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
            "scopeSpans": [{"spans": [{
                "traceId": f"{n:032x}", "spanId": f"{n:016x}", "name": "op", "kind": 1,
                "startTimeUnixNano": str(now), "endTimeUnixNano": str(now)}]}]}]})
        return http("/insert/opentelemetry/v1/traces", token, ["Content-Type: application/json", *headers],
                    "POST", payload)


    def services(token, headers=(), basic=None):
        return rows(http("/traces/select/jaeger/api/services", token, headers, basic=basic),
                    lambda b: [s for s in json.loads(b)["data"] if s.startswith("probe-")])


    # The tenant (0 = the default one) each read credential sees for each AccountID
    # the client sends, 400 = vmauth refuses. A stamped token ignores the header, a
    # list reads only the listed, `all` every declared tenant. The admin picks the
    # logs/traces tenant by header; its metrics route is the plain tenant-0 one.
    def expect(kind, backend, pick):
        if kind == "read-plain":
            return 0
        if kind == "read-a":
            return 1
        if kind == "read-b":
            return 2
        if kind == "read-list":
            return {1: 1, 2: 2}.get(pick, 400)
        if kind == "read-all":
            return {1: 1, 2: 2, 3: 3}.get(pick, 400)
        return 0 if backend == "metrics" else {1: 1, 2: 2, 3: 3, 4: 4}.get(pick, 0)


    # What each backend holds per tenant: one marker written with that tenant's
    # write token (and a spoofing AccountID/ProjectID header), none for 3 and 4.
    WRITERS = {0: "write-plain", 1: "write-a", 2: "write-b"}
    MARK = {"metrics": "probe_m_t{}", "logs": "probe-l-t{}", "traces": "probe-t-t{}"}
    READERS = {"metrics": metric_names, "logs": log_rows, "traces": services}
    SPOOF = ["AccountID: 9", "ProjectID: 9"]


    def data(backend, tenant):
        return [MARK[backend].format(tenant)] if tenant in WRITERS else []


    def eventually(fn, expected, what, tries=150):
        for _ in range(tries):
            if fn() == expected:
                return
            time.sleep(1)
        assert fn() == expected, (what, fn())


    def write_markers(backends):
        for t, token in WRITERS.items():
            if "metrics" in backends:
                assert send_metric(token, MARK["metrics"].format(t), SPOOF)[0] == "200", (token, "metrics")
            if "logs" in backends:
                assert send_log(token, MARK["logs"].format(t), SPOOF)[0] == "200", (token, "logs")
            if "traces" in backends:
                assert send_span(token, MARK["traces"].format(t), t + 1, SPOOF)[0] == "200", (token, "traces")
        for backend in backends:
            for t, reader_token in [(0, "read-plain"), (1, "read-a"), (2, "read-b")]:
                eventually(lambda: READERS[backend](reader_token), ("200", data(backend, t)), (backend, t))


    def check_matrix(backends):
        for backend in backends:
            for kind in KINDS:
                token, basic = (None, ADMIN) if kind == "admin" else (kind, None)
                for pick in PICKS:
                    tenant = expect(kind, backend, pick)
                    want = ("400", "missing route") if tenant == 400 else ("200", data(backend, tenant))
                    got = READERS[backend](token, hdr(pick), basic)
                    assert got == want, (backend, kind, pick, got, want)
  '';

  bootTest =
    {
      name,
      backends,
      units,
      extraServices ? { },
      script,
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-tenant-isolation-${name}";
      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = lib.recursiveUpdate (
          {
            inherit tenants;
            vmauth = vmauthTokens;
          }
          // backends
        ) extraServices;
      };
      testScript = ''
        ${testLib.waitActivePython}
        ${matrixPython}
        start_all()
        for unit in ${builtins.toJSON (units ++ [ "vmauth" ])}:
            wait_active(machine, f"{unit}.service")
        machine.wait_for_open_port(4204)
        ${script}
      '';
    };

  metricsUnits = [
    "vmstorage"
    "vminsert"
    "vmselect"
  ];

  renderPrelude = ''
    import json
    ${testLib.waitActivePython}
  '';
in
{
  # The real cluster behind vmauth: every token kind x {write, read A/B/C/4,
  # no pick}, then the spoofing rows.
  metrics = bootTest {
    name = "metrics";
    backends.metrics.enable = true;
    units = metricsUnits;
    script = ''
      write_markers(["metrics"])
      T0, T1, T2 = data("metrics", 0), data("metrics", 1), data("metrics", 2)

      def no_route(res, what=None):
          assert res[0] == "400" and res[1] == "missing route", (what, res)

      # Authoritative source: the cluster's own tenant paths, not vmauth.
      def backend_names(tenant):
          q = urllib.parse.quote('{__name__=~"probe_.*"}', safe="")
          out = machine.succeed(f"curl -sfg 'http://127.0.0.1:4201/select/{tenant}/prometheus/api/v1/label/__name__/values?match[]={q}&start={START}'")
          return sorted(json.loads(out)["data"])

      assert [backend_names(t) for t in (0, 1, 2, 3, 4)] == [T0, T1, T2, [], []]
      check_matrix(["metrics"])

      # A repeated AccountID: the first listed tenant whose header value matches wins, an
      # unlisted one never reaches a path.
      assert metric_names("read-list", ["AccountID: 2", "AccountID: 1"]) == ("200", T1)
      assert metric_names("read-list", ["AccountID: 1", "AccountID: 2"]) == ("200", T1)
      assert metric_names("read-list", ["AccountID: 3", "AccountID: 2"]) == ("200", T2)
      no_route(metric_names("read-list", ["AccountID: 3", "AccountID: 4"]))
      assert metric_names("read-all", ["AccountID: 4", "AccountID: 3"]) == ("200", [])
      for hdrs in (["AccountID: 0"], ["AccountID: 11"], ["AccountID: 4294967295"], ["AccountID:"], ["accountid: 1x"]):
          no_route(metric_names("read-list", hdrs))
          no_route(metric_names("read-all", hdrs))
      # A lower-case header name is the same header.
      assert metric_names("read-list", ["accountid: 2"]) == ("200", T2)

      # A label filter from the client can narrow, never widen, and never name another tenant.
      for token in ["read-a", "read-b", "read-list", "read-all", "read-plain"]:
          for extra in ["&extra_label=vm_account_id%3D2", "&extra_filters[]=%7Bvm_account_id%3D%222%22%7D",
                        "&extra_label=vm_account_id%3D1"]:
              code, names = metric_names(token, hdr(1), None, extra)
              assert code == "200" and set(names) <= set({"read-a": T1, "read-b": T2, "read-list": T1,
                                                            "read-all": T1, "read-plain": T0}[token]), (token, extra, names)

      # Another tenant in the client path: vmauth's 400, for every read credential, with and
      # without a header, every escape spelling.
      ESCAPES = [
          "/metrics/select/{o}/prometheus/api/v1/labels",
          "/metrics/select/0/prometheus/api/v1/labels",
          "/select/{o}/prometheus/api/v1/labels",
          "/metrics/../select/{o}/prometheus/api/v1/labels",
          "/metrics/api/v1/query/../../../../select/{o}/prometheus/api/v1/labels",
          "/metrics/api/v1/label/a/../../../../select/{o}/prometheus/api/v1/labels/values",
          "/metrics/%2e%2e/select/{o}/prometheus/api/v1/labels",
          "/metrics/api/v1/query/%2e%2e/%2e%2e/%2e%2e/select/{o}/prometheus/api/v1/labels",
          "/metrics/api/v1/label/x%2F..%2F..%2F..%2F..%2Fselect%2F{o}%2Fprometheus%2Fapi%2Fv1%2Flabels%2Fvalues",
          "/metrics/api/v1/export/../import",
          "/metrics/select/multitenant/prometheus/api/v1/labels",
          "/metrics/api/v1/admin/tsdb/delete_series",
      ]
      for token, basic, hdrs in [("read-a", None, []), ("read-b", None, []), ("read-plain", None, []),
                                 ("read-list", None, ["AccountID: 1"]), ("read-all", None, ["AccountID: 1"]),
                                 (None, ADMIN, [])]:
          specs = [dict(path=path.format(o=other), token=token, headers=hdrs, method=method, data=data_, basic=basic)
                   for other in (1, 2, 3, 4) for path in ESCAPES
                   for method, data_ in [("GET", None), ("POST", "match[]=probe_m_t1")]]
          for spec, res in zip(specs, http_batch(specs)):
              no_route(rows(res, json.loads), spec)

      # Writes: the tenant is the token's, in the path nothing else is accepted.
      WRITE_ESCAPES = [
          "/insert/{o}/opentelemetry/v1/metrics",
          "/insert/0/opentelemetry/v1/metrics",
          "/opentelemetry/../insert/{o}/opentelemetry/v1/metrics",
          "/opentelemetry/%2e%2e/insert/{o}/opentelemetry/v1/metrics",
          "/opentelemetry%2F..%2F..%2Finsert%2F{o}%2Fopentelemetry%2Fv1%2Fmetrics",
          "/insert/multitenant/opentelemetry/v1/metrics",
          "/api/v1/import/prometheus",
      ]
      machine.succeed("${otlpMetricGenerator}/bin/gen-otlp-metric probe_m_escape 1 > /tmp/m.bin")
      for token in ["write-a", "write-b", "write-plain"]:
          specs = [dict(path=path.format(o=other), token=token,
                        headers=["Content-Type: application/x-protobuf", "AccountID: 2"],
                        method="POST", data="@/tmp/m.bin")
                   for other in (1, 2, 3, 4) for path in WRITE_ESCAPES]
          for spec, res in zip(specs, http_batch(specs)):
              no_route(rows(res, json.loads), spec)
      # Read credentials cannot write, write tokens cannot read, a `tenants:` write entry has no access.
      for token in ["read-a", "read-list", "read-all", "read-plain"]:
          no_route(rows(send_metric(token, "probe_m_escape"), json.loads))
      for token in ["write-a", "write-plain"]:
          no_route(rows(http("/metrics/api/v1/labels", token), json.loads))
      unknown = send_metric("a-token-nobody-configured", "probe_m_escape")  # gitleaks:allow
      assert unknown[0] == "401", unknown
      assert send_metric("write-list", "probe_m_escape", ["AccountID: 1"]) == unknown

      # Nothing leaked, nothing landed elsewhere, the escapes wrote nothing.
      assert [backend_names(t) for t in (0, 1, 2, 3, 4)] == [T0, T1, T2, [], []]
      assert metric_names("read-all", ["AccountID: 1"]) == ("200", T1)

      # No token value reached the journal.
      journal = machine.succeed("journalctl -u vmauth.service --no-pager")
      for secret in ["write-a", "write-b", "write-plain", "write-list", "read-a", "read-b", "read-list",
                     "read-all", "read-plain", "admin-password-value"]:
          assert secret not in journal, secret
    '';
  };

  # The same cells over metrics, logs and traces in one stack.
  combined = bootTest {
    name = "combined";
    units = metricsUnits ++ [
      "victorialogs"
      "victoriatraces"
    ];
    backends = {
      metrics.enable = true;
      logs.enable = true;
      traces.enable = true;
    };
    script = ''
      write_markers(["metrics", "logs", "traces"])
      check_matrix(["metrics", "logs", "traces"])
      # A write token cannot read and a read credential cannot write, in any backend.
      for path, method, data_ in [("/metrics/api/v1/labels", "GET", None),
                                  ("/logs/select/logsql/query", "POST", "query=*"),
                                  ("/traces/select/jaeger/api/services", "GET", None)]:
          for token in ["write-a", "write-plain"]:
              code, body = http(path, token, [], method, data_)
              assert code == "400" and "missing route" in body, (path, token, code, body)
      for token in ["read-a", "read-list", "read-all", "read-plain"]:
          for res in [send_metric(token, "probe_m_x"), send_log(token, "probe-l-x"), send_span(token, "probe-t-x", 99)]:
              assert res[0] == "400" and "missing route" in res[1], (token, res)
    '';
  };

  # Rendered config for the metrics-specific shapes: an operator's own metrics
  # route (a url_prefix without the tenant-0 path) is not given to a tenant
  # token, a `tenants:` token gets one copy per declared tenant, tenant-less
  # tokens stay on tenant 0.
  render-metrics-routes = pkgs.testers.nixosTest {
    name = "victoria-stack-tenant-isolation-render-metrics";
    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics.enable = true;
        inherit tenants;
        vmauth = {
          requireAuthForWrites = false;
          writeTokensFile = yaml "write.yaml" ''
            tokens:
              - token: write-a # gitleaks:allow
                tenant: a
              - token: write-c # gitleaks:allow
                tenant: c
              - token: write-plain # gitleaks:allow
          '';
          readTokensFile = yaml "read.yaml" ''
            tokens:
              - token: read-list # gitleaks:allow
                tenants: [a, c]
              - token: read-all # gitleaks:allow
                tenants: all
              - token: read-plain # gitleaks:allow
          '';
          extraWriteUrlMap = [
            {
              src_paths = [ "/opentelemetry/custom.*" ];
              url_prefix = "http://192.0.2.1:9999/";
            }
          ];
        };
      };
    };
    testScript = ''
      ${renderPrelude}
      start_all()
      wait_active(machine, "vmauth.service")
      users = {u["bearer_token"]: u["url_map"] for u in json.loads(machine.succeed("cat /run/vmauth/config.json"))["users"]}

      def backend(routes):
          return [(r["src_paths"][0], r["url_prefix"], r.get("src_headers")) for r in routes]

      INS = "http://127.0.0.1:4209/insert/{}/"
      SEL = "http://127.0.0.1:4201/select/{}/prometheus/"
      # The operator's own route is dropped for a tenant (no place for the id), kept for tenant 0.
      assert backend(users["write-a"]) == [("/opentelemetry.*", INS.format(1), None)], users["write-a"]
      assert backend(users["write-c"]) == [("/opentelemetry.*", INS.format(3), None)], users["write-c"]
      assert ("/opentelemetry/custom.*", "http://192.0.2.1:9999/", None) in backend(users["write-plain"])
      assert ("/opentelemetry.*", INS.format(0), None) in backend(users["write-plain"])
      # projectId is not part of the metrics path; no AccountID/ProjectID header is sent either.
      for token in ("write-c", "read-list", "read-all"):
          for r in users[token]:
              assert not any(h.startswith(("AccountID", "ProjectID")) for h in r["headers"]), (token, r)
      # One copy per tenant, picked by the AccountID header.
      assert [(p, h) for _, p, h in backend(users["read-list"])] == [
          (SEL.format(1), ["AccountID: 1"]), (SEL.format(3), ["AccountID: 3"])], users["read-list"]
      assert [(p, h) for _, p, h in backend(users["read-all"])] == [
          (SEL.format(i), [f"AccountID: {i}"]) for i in (1, 2, 3)], users["read-all"]
      assert [p for _, p, _ in backend(users["read-plain"])] == [SEL.format(0)]
      # The anonymous write door stays tenant 0.
      config = json.loads(machine.succeed("cat /run/vmauth/config.json"))
      assert backend(config["unauthorized_user"]["url_map"]) == [("/opentelemetry.*", INS.format(0), None)], config
    '';
  };
}
