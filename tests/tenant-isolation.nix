{ pkgs, nixosModule }:

# Tenant-aware token entries (`tenant`, `tenants`) for logs and traces: the
# render script's output and the real stack through vmauth.
let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };

  yaml = name: text: "${pkgs.writeText name text}";

  # Python prelude of the render tests: config.json parsed, the build-time url
  # maps read back from the unit's environment, and the expected routes.
  renderPrelude = ''
    import json
    ${testLib.waitActivePython}

    def unit_env(name):
        env = machine.succeed("systemctl show vmauth.service -p Environment --value").split()
        return next(e.split("=", 1)[1] for e in env if e.startswith(name + "="))

    def load_json_file(path):
        return json.loads(machine.succeed(f"cat {path}"))

    def render():
        return json.loads(machine.succeed("cat /run/vmauth/config.json"))

    def by_token(config):
        return {u["bearer_token"]: u for u in config["users"] if "bearer_token" in u}

    def bare(routes):
        # The backend address is not what these tests are about.
        return [{k: v for k, v in r.items() if k != "url_prefix"} for r in routes]

    READ_LOGS = {"src_paths": ["/logs/select/.*"], "drop_src_path_prefix_parts": 1}
    READ_TRACES = {"src_paths": ["/traces/select/.*"], "drop_src_path_prefix_parts": 1}
    WRITE_LOGS = {"src_paths": ["/insert/journald.*"]}
    WRITE_TRACES = {"src_paths": ["/insert/opentelemetry/v1/traces.*"]}
    READ_METRICS = {
        "src_paths": [
            "/metrics/api/v1/query", "/metrics/api/v1/query_range", "/metrics/api/v1/series",
            "/metrics/api/v1/labels", "/metrics/api/v1/label/.+/values", "/metrics/api/v1/metadata",
            "/metrics/api/v1/export.*", "/metrics/federate",
        ],
        "drop_src_path_prefix_parts": 1,
    }
    WRITE_METRICS = {"src_paths": ["/opentelemetry.*"]}

    # The MCP routes: the module's own, the caller's Authorization kept (the MCP server sends it
    # back to the read tier, which stamps it).
    def mcp(svc):
        return {"src_paths": [f"/mcp/{svc}(/.*)?"], "drop_src_path_prefix_parts": 2, "headers": []}

    MCP_ALL = [mcp("metrics"), mcp("logs"), mcp("traces")]

    def mroute(base, pick=None):
        # A metrics route carries its tenant in the url_prefix, not in headers.
        r = dict(base)
        if pick is not None:
            r["src_headers"] = [f"AccountID: {pick}"]
        r["headers"] = ["Authorization:"]
        return r

    def backend_paths(routes):
        return [r["url_prefix"].split("/", 3)[3] for r in routes if r["src_paths"][0].startswith(("/metrics", "/opentelemetry"))]

    def route(base, account, project, pick=False):
        r = dict(base)
        if pick:
            r["src_headers"] = [f"AccountID: {account}"]
        r["headers"] = ["Authorization:", f"AccountID: {account}", f"ProjectID: {project}"]
        return r

    def journal_has(fragment):
        return fragment in machine.succeed("journalctl -u vmauth.service --no-pager")
  '';

  allBackends = {
    metrics.enable = true;
    metrics.mcp.enable = true;
    logs.enable = true;
    logs.mcp.enable = true;
    traces.enable = true;
    traces.mcp.enable = true;
  };

  mkRenderTest =
    {
      name,
      tenants,
      services ? { },
      script,
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-tenant-render-${name}";
      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = lib.recursiveUpdate (allBackends // { inherit tenants; }) services;
      };
      testScript = ''
        ${renderPrelude}
        start_all()
        wait_active(machine, "vmauth.service")
        ${script}
      '';
    };

  declared = {
    a.accountId = 1;
    b.accountId = 2;
    c = {
      accountId = 3;
      projectId = 7;
    };
  };

  # One boot test per token-file problem that must stop the render.
  mkStructuralErrorTest =
    {
      name,
      readYaml,
      expect,
      secrets,
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-tenant-structure-${name}";
      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          logs.enable = true;
          tenants = declared;
          vmauth.readTokensFile = yaml "bad-read-tokens.yaml" readYaml;
        };
      };
      testScript = ''
        start_all()
        machine.fail("systemctl is-active vmauth.service")
        journal = machine.succeed("journalctl -u vmauth.service --no-pager")
        for fragment in ${builtins.toJSON expect}:
            assert fragment in journal, (fragment, journal)
        for secret in ${builtins.toJSON secrets}:
            assert secret not in journal, secret
      '';
    };

in
{
  # Every token shape, with tenants declared: the routes vmauth is given.
  render-stamps-tenant-routes-per-token-shape = mkRenderTest {
    name = "shapes";
    tenants = declared;
    services.vmauth = {
      adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";
      readTokensFile = yaml "read.yaml" ''
        tokens:
          - token: read-single-a # gitleaks:allow
            tenant: a
          - token: read-list-a-c # gitleaks:allow
            tenants: [a, c]
          - token: read-all # gitleaks:allow
            tenants: all
          - token: read-plain # gitleaks:allow
          - token: read-single-c-logs-only # gitleaks:allow
            tenant: c
            backends: [logs]
      '';
      writeTokensFile = yaml "write.yaml" ''
        tokens:
          - token: write-single-a # gitleaks:allow
            tenant: a
          - token: write-plain # gitleaks:allow
      '';
    };
    script = ''
      users = by_token(render())
      read_map = load_json_file(unit_env("READ_URL_MAP_FILE"))
      write_map = load_json_file(unit_env("WRITE_URL_MAP_FILE"))

      # tenant: the entry's logs and traces routes carry the tenant, its metrics routes the
      # tenant's backend path, and the MCP routes are unstamped (the read tier they call stamps).
      assert bare(users["read-single-a"]["url_map"]) == [
          mroute(READ_METRICS), route(READ_LOGS, 1, 0), route(READ_TRACES, 1, 0), *MCP_ALL,
      ], users["read-single-a"]
      assert backend_paths(users["read-single-a"]["url_map"]) == ["select/1/prometheus/"]
      assert bare(users["read-single-c-logs-only"]["url_map"]) == [route(READ_LOGS, 3, 7), mcp("logs")]
      assert bare(users["write-single-a"]["url_map"]) == [
          mroute(WRITE_METRICS), route(WRITE_LOGS, 1, 0), route(WRITE_TRACES, 1, 0),
      ], users["write-single-a"]
      assert backend_paths(users["write-single-a"]["url_map"]) == ["insert/1/"]

      # tenants: [..]: per tenant, the client's AccountID selects, the project is forced.
      assert bare(users["read-list-a-c"]["url_map"]) == [
          mroute(READ_METRICS, 1), route(READ_LOGS, 1, 0, pick=True), route(READ_TRACES, 1, 0, pick=True),
          mroute(READ_METRICS, 3), route(READ_LOGS, 3, 7, pick=True), route(READ_TRACES, 3, 7, pick=True),
          *MCP_ALL,
      ], users["read-list-a-c"]
      assert backend_paths(users["read-list-a-c"]["url_map"]) == ["select/1/prometheus/", "select/3/prometheus/"]

      # tenants: all: every declared tenant.
      assert bare(users["read-all"]["url_map"]) == [
          x
          for a, p in [(1, 0), (2, 0), (3, 7)]
          for x in (mroute(READ_METRICS, a), route(READ_LOGS, a, p, pick=True), route(READ_TRACES, a, p, pick=True))
      ] + MCP_ALL, users["read-all"]
      assert backend_paths(users["read-all"]["url_map"]) == [f"select/{a}/prometheus/" for a in (1, 2, 3)]

      # No key: tenant 0:0 on logs and traces; every other route exactly as before.
      stamped_read = [
          dict(r, headers=r["headers"] + ["AccountID: 0", "ProjectID: 0"])
          if r["src_paths"][0] in ("/logs/select/.*", "/traces/select/.*") else r
          for r in read_map
      ]
      stamped_write = [
          dict(r, headers=r["headers"] + ["AccountID: 0", "ProjectID: 0"])
          if r["src_paths"][0] in ("/insert/journald.*", "/insert/opentelemetry/v1/traces.*") else r
          for r in write_map
      ]
      assert users["read-plain"]["url_map"] == stamped_read, users["read-plain"]
      assert users["write-plain"]["url_map"] == stamped_write, users["write-plain"]
      # ... in particular, metrics and the MCP routes are not stamped.
      assert any(r["src_paths"][0].startswith("/mcp/logs") and "AccountID: 0" not in r["headers"]
                 for r in users["read-plain"]["url_map"])
      assert any(r["src_paths"][0].startswith("/metrics") and "AccountID: 0" not in r["headers"]
                 for r in users["read-plain"]["url_map"])

      # Read tenant tokens get exactly the module's MCP routes; a write token has none (the MCP
      # servers are read-tier clients).
      for token in ("read-single-a", "read-list-a-c", "read-all"):
          got = [r for r in users[token]["url_map"] if r["src_paths"][0].startswith("/mcp")]
          assert bare(got) == MCP_ALL, (token, got)
          assert [r["url_prefix"] for r in got] == [r["url_prefix"] for r in read_map if r["src_paths"][0].startswith("/mcp")]
      assert not any(r["src_paths"][0].startswith("/mcp") for r in users["write-single-a"]["url_map"])

      # The admin tier is never stamped: the full read map, untouched.
      admin = next(u for u in render()["users"] if u.get("username") == "admin")
      assert admin["url_map"] == read_map, admin

      # Tenant entries lose nothing, so nothing is warned about.
      assert not journal_has("metrics tenants are not supported"), "the metrics warning is gone"
      journal = machine.succeed("journalctl -u vmauth.service --no-pager")
      for secret in ["read-single-a", "read-list-a-c", "read-all", "read-plain", "write-single-a",
                     "write-plain", "admin-password-value"]:
          assert secret not in journal, secret
    '';
  };

  render-tenant-entries-that-cannot-be-honoured-warn-and-grant-no-access = mkRenderTest {
    name = "warnings";
    tenants = declared // {
      # Shares an account with `a`: ambiguous in a list.
      a2 = {
        accountId = 1;
        projectId = 1;
      };
    };
    services.vmauth = {
      readTokensFile = yaml "read.yaml" ''
        tokens:
          - token: read-undeclared # gitleaks:allow
            tenant: nosuch
          - token: read-list-one-undeclared # gitleaks:allow
            tenants: [a, nosuch]
          - token: read-list-all-undeclared # gitleaks:allow
            tenants: [nosuch, ghost]
          - token: read-list-same-account # gitleaks:allow
            tenants: [a, a2]
          - token: read-empty-list # gitleaks:allow
            tenants: []
          - token: read-all-same-account # gitleaks:allow
            tenants: all
          - token: read-reserved-word # gitleaks:allow
            tenant: all
          - token: read-metrics-only # gitleaks:allow
            tenant: a
            backends: [metrics]
          - token: read-good # gitleaks:allow
            tenant: b
            backends: [traces]
      '';
      writeTokensFile = yaml "write.yaml" ''
        tokens:
          - token: write-list # gitleaks:allow
            tenants: [a]
          - token: write-all # gitleaks:allow
            tenants: all
          - token: write-undeclared # gitleaks:allow
            tenant: nosuch
          - token: write-good # gitleaks:allow
            tenant: a
            backends: [logs]
      '';
    };
    script = ''
      users = by_token(render())

      for fragment in [
          "readTokensFile entry #1 names undeclared tenant(s): nosuch",
          "readTokensFile entry #1 has no declared tenant -- the token gets no access",
          "readTokensFile entry #2 names undeclared tenant(s): nosuch",
          "readTokensFile entry #3 names undeclared tenant(s): nosuch, ghost",
          "readTokensFile entry #3 has no declared tenant -- the token gets no access",
          'readTokensFile entry #4: tenants "a2" and "a" share accountId 1; "a2" is ignored',
          "readTokensFile entry #5 has an empty `tenants` list -- the token gets no access",
          'readTokensFile entry #6: tenants "a2" and "a" share accountId 1; "a2" is ignored',
          'readTokensFile entry #7 names undeclared tenant(s): all',
          "writeTokensFile entry #1 has a `tenants` key, which only a read token may carry",
          "writeTokensFile entry #2 has a `tenants` key, which only a read token may carry",
          "writeTokensFile entry #3 names undeclared tenant(s): nosuch",
          "writeTokensFile entry #3 has no declared tenant -- the token gets no access",
      ]:
          assert journal_has(fragment), fragment

      # No access: left out of the configuration (callers get an unknown token's 401).
      for token in ["read-undeclared", "read-list-all-undeclared", "read-empty-list", "read-reserved-word",
                    "write-list", "write-all", "write-undeclared"]:
          assert token not in users, token

      # A name that is not declared is ignored; the others stay.
      assert [r.get("src_headers") for r in bare(users["read-list-one-undeclared"]["url_map"])] == [
          ["AccountID: 1"], ["AccountID: 1"], ["AccountID: 1"], None, None, None
      ], users["read-list-one-undeclared"]
      # Two tenants of one account: the first stays (metrics, logs, traces).
      assert [r["headers"][-2:] for r in bare(users["read-list-same-account"]["url_map"])] == [
          ["Authorization:"], ["AccountID: 1", "ProjectID: 0"], ["AccountID: 1", "ProjectID: 0"], [], [], []
      ], users["read-list-same-account"]
      assert backend_paths(users["read-list-same-account"]["url_map"]) == ["select/1/prometheus/"]
      assert sorted({r["src_headers"][0] for r in users["read-all-same-account"]["url_map"] if "src_headers" in r}) == [
          "AccountID: 1", "AccountID: 2", "AccountID: 3"
      ]
      # A tenant entry scoped to metrics keeps exactly the metrics route, in the tenant's path.
      assert bare(users["read-metrics-only"]["url_map"]) == [mroute(READ_METRICS), mcp("metrics")], users["read-metrics-only"]
      assert backend_paths(users["read-metrics-only"]["url_map"]) == ["select/1/prometheus/"]
      # A tenant entry scoped to traces keeps exactly that.
      assert bare(users["read-good"]["url_map"]) == [route(READ_TRACES, 2, 0), mcp("traces")]
      assert bare(users["write-good"]["url_map"]) == [route(WRITE_LOGS, 1, 0)]

      # vmauth keeps running; no token reaches the journal.
      journal = machine.succeed("journalctl -u vmauth.service --no-pager")
      for secret in ["read-undeclared", "read-list-one-undeclared", "read-list-all-undeclared",
                     "read-list-same-account", "read-empty-list", "read-all-same-account",
                     "read-reserved-word", "read-metrics-only", "read-good", "write-list", "write-all",
                     "write-undeclared", "write-good"]:
          assert secret not in journal, secret
    '';
  };

  render-tenants-all-without-declared-tenants-grants-no-access = mkRenderTest {
    name = "all-without-tenants";
    tenants = { };
    services.vmauth.readTokensFile = yaml "read.yaml" ''
      tokens:
        - token: read-all # gitleaks:allow
          tenants: all
        - token: read-tenant # gitleaks:allow
          tenant: a
        - token: read-plain # gitleaks:allow
    '';
    script = ''
      users = by_token(render())
      assert journal_has("readTokensFile entry #1 has `tenants: all`, but no tenant is declared")
      assert journal_has("readTokensFile entry #2 names undeclared tenant(s): a")
      assert "read-all" not in users and "read-tenant" not in users, users
      assert users["read-plain"]["url_map"] == load_json_file(unit_env("READ_URL_MAP_FILE"))
    '';
  };

  # Existing configurations: no tenant declared renders exactly the url maps
  # the build produced, for both tiers and the anonymous door.
  render-without-declared-tenants-is-the-plain-url-map = mkRenderTest {
    name = "unchanged";
    tenants = { };
    services.vmauth = {
      requireAuthForWrites = false;
      adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";
      readTokensFile = yaml "read.yaml" ''
        tokens:
          - token: read-plain # gitleaks:allow
          - token: read-logs # gitleaks:allow
            backends: [logs]
      '';
      writeTokensFile = yaml "write.yaml" ''
        tokens:
          - token: write-plain # gitleaks:allow
      '';
    };
    script = ''
      config = render()
      users = by_token(config)
      read_map = load_json_file(unit_env("READ_URL_MAP_FILE"))
      write_map = load_json_file(unit_env("WRITE_URL_MAP_FILE"))
      open_map = load_json_file(unit_env("OPEN_INGEST_PATHS_FILE"))
      assert users["read-plain"]["url_map"] == read_map
      assert users["write-plain"]["url_map"] == write_map
      assert config["unauthorized_user"]["url_map"] == open_map
      assert next(u for u in config["users"] if u.get("username") == "admin")["url_map"] == read_map
      assert [r["src_paths"] for r in users["read-logs"]["url_map"]] == [
          ["/logs/select/.*"], ["/mcp/logs(/.*)?"]
      ], users["read-logs"]
      text = machine.succeed("cat /run/vmauth/config.json")
      assert "AccountID" not in text and "ProjectID" not in text and "src_headers" not in text, text
    '';
  };

  # A header from the anonymous door must not pick a tenant either.
  render-open-ingest-door-is-stamped-when-tenants-exist = mkRenderTest {
    name = "open-door";
    tenants = declared;
    services.vmauth.requireAuthForWrites = false;
    script = ''
      config = render()
      open_map = load_json_file(unit_env("OPEN_INGEST_PATHS_FILE"))
      by_path = {r["src_paths"][0]: r for r in config["unauthorized_user"]["url_map"]}
      stamp = ["AccountID: 0", "ProjectID: 0"]
      for p in ("/insert/journald.*", "/insert/opentelemetry/v1/traces.*"):
          assert by_path[p]["headers"][-2:] == stamp, by_path[p]
      assert by_path["/opentelemetry.*"]["headers"][-2:] != stamp, by_path
      assert len(config["unauthorized_user"]["url_map"]) == len(open_map)
    '';
  };

  structural-tenant-key-errors-stop-the-render-per-entry = mkStructuralErrorTest {
    name = "errors";
    readYaml = ''
      tokens:
        - token: both-keys-secret # gitleaks:allow
          tenant: a
          tenants: [a]
        - token: number-tenant-secret # gitleaks:allow
          tenant: 5
        - token: null-tenant-secret # gitleaks:allow
          tenant:
        - token: object-tenants-secret # gitleaks:allow
          tenants: {a: b}
        - token: bad-item-secret # gitleaks:allow
          tenants: [a, 7]
        - token: bare-word-secret # gitleaks:allow
          tenants: everything
    '';
    expect = [
      "readTokensFile is malformed"
      "entry #1 has both `tenant` and `tenants`"
      "entry #2: tenant must be a tenant name (a string), got number"
      "entry #3: tenant must be a tenant name (a string), got null"
      "entry #4: tenants must be a list of tenant names or the word all, got object"
      "entry #5: tenants must be a list of strings, got an item of type number"
      "entry #6: tenants must be a list of tenant names or the word all, got a string other than all"
    ];
    secrets = [
      "both-keys-secret"
      "number-tenant-secret"
      "null-tenant-secret"
      "object-tenants-secret"
      "bad-item-secret"
      "bare-word-secret"
    ];
  };

  # The real stack through vmauth: two tenants (plus a third nobody writes
  # to), every token kind, logs and traces.
  logs-traces = pkgs.testers.nixosTest {
    name = "victoria-stack-tenant-isolation-logs-traces";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        logs.enable = true;
        logs.mcp.enable = true;
        traces.enable = true;
        traces.mcp.enable = true;
        tenants = declared;
        vmauth = {
          adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";
          writeTokensFile = yaml "write.yaml" ''
            tokens:
              - token: write-a # gitleaks:allow
                tenant: a
              - token: write-b # gitleaks:allow
                tenant: b
              - token: write-plain # gitleaks:allow
              - token: write-with-list # gitleaks:allow
                tenants: [a]
          '';
          readTokensFile = yaml "read.yaml" ''
            tokens:
              - token: read-a # gitleaks:allow
                tenant: a
              - token: read-b # gitleaks:allow
                tenant: b
              - token: read-list-a-b # gitleaks:allow
                tenants: [a, b]
              - token: read-all # gitleaks:allow
                tenants: all
              - token: read-plain # gitleaks:allow
          '';
        };
      };
    };

    testScript = ''
      import json
      import shlex
      import time
      ${testLib.waitActivePython}

      start_all()
      for unit in ["victorialogs", "victoriatraces", "mcp-victorialogs", "mcp-victoriatraces", "vmauth"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4204)

      VMAUTH = "http://127.0.0.1:4204"


      def http(path, token=None, headers=(), method="GET", data=None, basic=None):
          cmd = f"curl -s -w '\\n%{{http_code}}' -X {method} "
          if token:
              cmd += f"-H {shlex.quote('Authorization: Bearer ' + token)} "
          if basic:
              cmd += f"-u {shlex.quote(basic)} "
          for h in headers:
              cmd += f"-H {shlex.quote(h)} "
          if data is not None:
              cmd += f"--data-binary {shlex.quote(data)} "
          out = machine.succeed(cmd + shlex.quote(VMAUTH + path))
          body, code = out.rsplit("\n", 1)
          return code.strip(), body


      def missing_route(res, path):
          code, body = res
          assert code == "400", res
          assert body.startswith("user bearer_token:hash:") and body.strip().endswith(f'missing route for "{path}"'), res


      # ---- logs -------------------------------------------------------------
      def send_log(token, message, headers=()):
          # systemd-journal-upload's export format, the module's logs write route.
          body = f"MESSAGE={message}\n__REALTIME_TIMESTAMP={int(time.time())}000000\n_HOSTNAME=h\n\n"
          return http("/insert/journald/upload?_stream_fields=_HOSTNAME", token, [
              "Content-Type: application/vnd.fdo.journal", *headers], "POST", body)


      LOG_QUERY = "/logs/select/logsql/query"


      def log_rows(token, headers=(), basic=None):
          code, body = http(LOG_QUERY, token, headers, "POST", "query=*", basic)
          assert code == "200", (code, body)
          return sorted(json.loads(l)["_msg"] for l in body.splitlines() if l.strip())


      for token, msg, hdrs in [
          ("write-a", "log-a", []),
          ("write-a", "log-a-spoofed-b", ["AccountID: 2", "ProjectID: 5"]),
          ("write-b", "log-b", []),
          ("write-b", "log-b-spoofed-a", ["AccountID: 1"]),
          ("write-plain", "log-default", []),
          ("write-plain", "log-default-spoofed-a", ["AccountID: 1"]),
      ]:
          assert send_log(token, msg, hdrs)[0] == "200", (token, msg)

      ROWS_A = ["log-a", "log-a-spoofed-b"]
      ROWS_B = ["log-b", "log-b-spoofed-a"]
      ROWS_DEFAULT = ["log-default", "log-default-spoofed-a"]


      def eventually(fn, expected, what):
          for _ in range(60):
              if fn() == expected:
                  return
              time.sleep(1)
          assert fn() == expected, (what, fn())


      eventually(lambda: log_rows("read-a"), ROWS_A, "tenant a rows")
      eventually(lambda: log_rows("read-b"), ROWS_B, "tenant b rows")
      eventually(lambda: log_rows("read-plain"), ROWS_DEFAULT, "default tenant rows")

      # tenant: stamped. A client header changes nothing, in either direction.
      assert log_rows("read-a", ["AccountID: 2", "ProjectID: 5"]) == ROWS_A
      assert log_rows("read-b") == ROWS_B
      assert log_rows("read-b", ["AccountID: 1"]) == ROWS_B
      # No key: only the default tenant, whatever the client sends.
      assert log_rows("read-plain") == ROWS_DEFAULT
      assert log_rows("read-plain", ["AccountID: 1"]) == ROWS_DEFAULT
      assert log_rows("read-plain", ["AccountID: 2", "AccountID: 1"]) == ROWS_DEFAULT
      # Admin picks any tenant by sending the headers itself.
      admin = "admin:admin-password-value"
      assert log_rows(None, basic=admin) == ROWS_DEFAULT
      assert log_rows(None, ["AccountID: 1"], admin) == ROWS_A
      assert log_rows(None, ["AccountID: 2"], admin) == ROWS_B

      # tenants: [a, b]: the client picks, only from the list.
      assert log_rows("read-list-a-b", ["AccountID: 1"]) == ROWS_A
      assert log_rows("read-list-a-b", ["AccountID: 2"]) == ROWS_B
      # ... the project cannot be picked, and a second AccountID cannot widen the first.
      assert log_rows("read-list-a-b", ["AccountID: 1", "ProjectID: 9"]) == ROWS_A
      # vmauth matches ANY value of a repeated header, the first listed tenant wins; the
      # stamped AccountID replaces every value, so the backend only ever sees that one.
      assert log_rows("read-list-a-b", ["AccountID: 2", "AccountID: 1"]) == ROWS_A
      assert log_rows("read-list-a-b", ["AccountID: 1", "AccountID: 2"]) == ROWS_A
      assert log_rows("read-list-a-b", ["AccountID: 3", "AccountID: 2"]) == ROWS_B
      for hdrs in (["AccountID: 3"], ["AccountID: 0"], ["AccountID: 11"], ["AccountID: 4294967295"], []):
          missing_route(http(LOG_QUERY, "read-list-a-b", hdrs, "POST", "query=*"), LOG_QUERY)

      # tenants: all: every declared tenant (c is declared, nobody wrote to it), nothing else.
      assert log_rows("read-all", ["AccountID: 1"]) == ROWS_A
      assert log_rows("read-all", ["AccountID: 2"]) == ROWS_B
      assert log_rows("read-all", ["AccountID: 3"]) == []
      for hdrs in (["AccountID: 4"], ["AccountID: 0"], []):
          missing_route(http(LOG_QUERY, "read-all", hdrs, "POST", "query=*"), LOG_QUERY)

      # Write tier: a token stamped for a cannot write into b (the rows above sit in a), a
      # `tenants:` write entry has no access (an unknown token's 401).
      unknown = send_log("a-token-nobody-configured", "x")  # gitleaks:allow
      assert unknown[0] == "401", unknown
      assert send_log("write-with-list", "log-with-list", ["AccountID: 1"]) == unknown
      assert http("/insert/opentelemetry/v1/traces", "write-with-list", ["Content-Type: application/json"],
                  "POST", "{}") == http("/insert/opentelemetry/v1/traces", "a-token-nobody-configured",
                                       ["Content-Type: application/json"], "POST", "{}")
      assert log_rows("read-a") == ROWS_A and log_rows("read-b") == ROWS_B

      # ---- traces -----------------------------------------------------------
      def send_span(token, service, n, headers=()):
          now = time.time_ns()
          payload = json.dumps({"resourceSpans": [{
              "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
              "scopeSpans": [{"spans": [{
                  "traceId": f"{n:032x}", "spanId": f"{n:016x}", "name": "op", "kind": 1,
                  "startTimeUnixNano": str(now), "endTimeUnixNano": str(now)}]}]}]})
          return http("/insert/opentelemetry/v1/traces", token,
                      ["Content-Type: application/json", *headers], "POST", payload)


      SERVICES = "/traces/select/jaeger/api/services"


      def services(token, headers=(), basic=None):
          code, body = http(SERVICES, token, headers, "GET", None, basic)
          assert code == "200", (code, body)
          return sorted(json.loads(body)["data"])


      for n, (token, service, hdrs) in enumerate([
          ("write-a", "svc-a", []),
          ("write-a", "svc-a-spoofed-b", ["AccountID: 2"]),
          ("write-b", "svc-b", []),
          ("write-plain", "svc-default", []),
          ("write-plain", "svc-default-spoofed-a", ["AccountID: 1"]),
      ], start=1):
          assert send_span(token, service, n, hdrs)[0] == "200", (token, service)

      SVC_A = ["svc-a", "svc-a-spoofed-b"]
      SVC_B = ["svc-b"]
      SVC_DEFAULT = ["svc-default", "svc-default-spoofed-a"]

      eventually(lambda: services("read-a"), SVC_A, "tenant a services")
      eventually(lambda: services("read-b"), SVC_B, "tenant b services")
      eventually(lambda: services("read-plain"), SVC_DEFAULT, "default tenant services")
      assert services("read-a", ["AccountID: 2"]) == SVC_A
      assert services("read-b") == SVC_B
      assert services("read-b", ["AccountID: 1"]) == SVC_B
      assert services("read-plain") == SVC_DEFAULT
      assert services("read-plain", ["AccountID: 1"]) == SVC_DEFAULT
      assert services(None, basic=admin) == SVC_DEFAULT
      assert services(None, ["AccountID: 1"], admin) == SVC_A
      assert services(None, ["AccountID: 2"], admin) == SVC_B
      assert services("read-list-a-b", ["AccountID: 1"]) == SVC_A
      assert services("read-list-a-b", ["AccountID: 2"]) == SVC_B
      for hdrs in (["AccountID: 3"], ["AccountID: 0"], []):
          missing_route(http(SERVICES, "read-list-a-b", hdrs), SERVICES)
      assert services("read-all", ["AccountID: 1"]) == SVC_A
      assert services("read-all", ["AccountID: 3"]) == []
      for hdrs in (["AccountID: 4"], []):
          missing_route(http(SERVICES, "read-all", hdrs), SERVICES)

      # ---- MCP: every read token kind reaches the MCP routes (tests/tenant-mcp.nix covers the data) ----
      INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
          "protocolVersion": "2024-11-05", "capabilities": {},
          "clientInfo": {"name": "victoria-stack-test", "version": "1.0"}}})
      MCP_HDRS = ["Content-Type: application/json", "Accept: application/json, text/event-stream"]
      for route, name in [("logs", "VictoriaLogs"), ("traces", "VictoriaTraces")]:
          path = f"/mcp/{route}"
          for token, basic in [("read-a", None), ("read-b", None), ("read-list-a-b", None), ("read-all", None),
                               ("read-plain", None), (None, admin)]:
              code, body = http(path, token, MCP_HDRS, "POST", INIT, basic)
              assert code == "200" and name in body, (route, token, code, body)

      # No token value reached the journal.
      journal = machine.succeed("journalctl -u vmauth.service --no-pager")
      for secret in ["write-a", "write-b", "write-plain", "write-with-list", "read-a", "read-b",
                     "read-list-a-b", "read-all", "read-plain", "admin-password-value"]:
          assert secret not in journal, secret
    '';
  };
}
