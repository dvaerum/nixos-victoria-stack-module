{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith probeAndStartSeconds;

  mkTableCheck =
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

  # Same shape as storage.nix's mkHardeningCheck, minus LimitNOFILE --
  # no nixpkgs module to confirm a LimitNOFILE value against here. The
  # readiness probe itself (mcp.nix) has its own dedicated eval
  # check below, not folded into this one.
  mkMcpHardeningCheck =
    {
      name,
      serviceName,
      enableModule,
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith enableModule;
        sc = evaluated.config.systemd.services.${serviceName}.serviceConfig;
        hardeningChecks = {
          "full hardening profile (differs in: ${builtins.toJSON (testLib.hardeningDiff sc)})" =
            testLib.hardeningDiff sc == [ ];
        };
        failed = lib.filterAttrs (_: ok: !ok) hardeningChecks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s serviceConfig is missing expected hardening: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Previously untested for all 3 mcp services: mcp.package override
  # reaching ExecStart. Eval-only (checks the resolved ExecStart string)
  # rather than a nixosTest boot -- a derivation-path equality check
  # doesn't need a running system to be a genuine, non-vacuous assertion.
  #
  # Plain string equality, not lib.hasInfix: a regex needle carrying
  # store-path context (from "${overridePackage}") makes builtins.match
  # refuse to compile ("is not allowed to refer to a store path") --
  # confirmed by hitting this exact error.
  mkPackageOverrideCheck =
    {
      name,
      serviceName,
      serviceAttr,
      binaryName,
    }:
    pkgs.runCommand name { } (
      let
        overridePackage = pkgs.hello; # any derivation with a /bin -- content irrelevant, only the store path is checked
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            mcp = {
              enable = true;
              package = overridePackage;
            };
          };
        };
        execStart = evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStart;
        expected = "${overridePackage}/bin/${binaryName}";
      in
      if execStart == expected then
        "echo OK > $out"
      else
        throw "${serviceName}'s ExecStart did not resolve through the overridden mcp.package: expected ${expected}, got ${execStart}"
    );
in
{
  mcp-metrics-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-metrics-package-override-takes-effect";
    serviceName = "mcp-victoriametrics";
    serviceAttr = "metrics";
    binaryName = "mcp-victoriametrics";
  };

  mcp-logs-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-logs-package-override-takes-effect";
    serviceName = "mcp-victorialogs";
    serviceAttr = "logs";
    binaryName = "mcp-victorialogs";
  };

  mcp-traces-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-traces-package-override-takes-effect";
    serviceName = "mcp-victoriatraces";
    serviceAttr = "traces";
    binaryName = "mcp-victoriatraces";
  };

  mcp-metrics-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-metrics-hardening-profile";
    serviceName = "mcp-victoriametrics";
    enableModule = {
      services.victoriaStack.metrics = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-logs-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-logs-hardening-profile";
    serviceName = "mcp-victorialogs";
    enableModule = {
      services.victoriaStack.logs = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-traces-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-traces-hardening-profile";
    serviceName = "mcp-victoriatraces";
    enableModule = {
      services.victoriaStack.traces = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  # logLevel/logFormat are genuinely shared/inert-unless-configured
  # across all 3 backends -- exercised via logs here (not metrics, see
  # the dedicated disabledTools-union tests below for why metrics' own
  # disabledTools behavior needs separate, more specific coverage now).
  mcp-log-and-disabled-tools-options-are-inert-unless-configured =
    pkgs.runCommand "mcp-log-and-disabled-tools-inert-unless-configured" { }
      (
        let
          unset = evalWith {
            services.victoriaStack.logs = {
              enable = true;
              mcp.enable = true;
            };
          };
          set = evalWith {
            services.victoriaStack.logs = {
              enable = true;
              mcp = {
                enable = true;
                # Neither is the other's possible default or a value the module
                # could hardcode by accident: each must come from the option.
                logLevel = "warn";
                logFormat = "text";
                disabledTools = [
                  "documentation"
                  "some-other-tool"
                ];
              };
            };
          };
          envUnset = unset.config.systemd.services.mcp-victorialogs.environment;
          envSet = set.config.systemd.services.mcp-victorialogs.environment;
          checks = {
            "MCP_LOG_LEVEL absent when unset" = !(envUnset ? MCP_LOG_LEVEL);
            "MCP_LOG_FORMAT absent when unset" = !(envUnset ? MCP_LOG_FORMAT);
            # Only the module's own default (flags) when the option is unset.
            "MCP_DISABLED_TOOLS is just the module default when unset" =
              (envUnset.MCP_DISABLED_TOOLS or null) == "flags";
            "MCP_LOG_LEVEL present when set" = (envSet.MCP_LOG_LEVEL or null) == "warn";
            "MCP_LOG_FORMAT present when set" = (envSet.MCP_LOG_FORMAT or null) == "text";
            "MCP_DISABLED_TOOLS joined with commas when set" =
              (envSet.MCP_DISABLED_TOOLS or null) == "flags,documentation,some-other-tool";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "mcp logLevel/logFormat/disabledTools options broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # mcp-victoriametrics' own
  # binary (unlike logs/traces) hardcodes 6 tools disabled by default
  # when MCP_DISABLED_TOOLS is unset entirely -- confirmed directly
  # from its source (pinned version 1.20.2), including test_rules,
  # which WRITES synthetic series into the live instance. Before this
  # fix, setting disabledTools = ["documentation"] (this option's own
  # documented `example`) silently passed the user's list VERBATIM,
  # dropping the upstream default entirely and re-enabling all 6 --
  # confirmed live in a real container boot (tools/list genuinely
  # listed test_rules/export/flags after setting disabledTools).
  mcp-metrics-disabled-tools-preserves-upstream-defaults-even-when-set =
    pkgs.runCommand "mcp-metrics-disabled-tools-preserves-upstream-defaults" { }
      (
        let
          unset = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              mcp.enable = true;
            };
          };
          set = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              mcp = {
                enable = true;
                disabledTools = [ "documentation" ];
              };
            };
          };
          envUnset = unset.config.systemd.services.mcp-victoriametrics.environment;
          envSet = set.config.systemd.services.mcp-victoriametrics.environment;
          upstreamDefaults = [
            "export"
            "flags"
            "metric_relabel_debug"
            "downsampling_filters_debug"
            "retention_filters_debug"
            "test_rules"
          ];
          toolsUnset = lib.splitString "," (envUnset.MCP_DISABLED_TOOLS or "");
          toolsSet = lib.splitString "," (envSet.MCP_DISABLED_TOOLS or "");
          checks = {
            "MCP_DISABLED_TOOLS present even when unset (upstream defaults preserved)" =
              envUnset ? MCP_DISABLED_TOOLS;
            "upstream defaults present when unset" = lib.all (t: lib.elem t toolsUnset) upstreamDefaults;
            "upstream defaults STILL present after setting disabledTools" = lib.all (
              t: lib.elem t toolsSet
            ) upstreamDefaults;
            "user's own disabledTools entry also present" = lib.elem "documentation" toolsSet;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "mcp-victoriametrics disabledTools union broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Control: logs/traces have no upstream-default-disabled set of their
  # own (confirmed from their own sources, no such hardcoded fallback), so
  # the metrics-specific upstream union above must not leak into them:
  # traces stays a plain passthrough, logs adds only its own module default.
  mcp-logs-and-traces-disabled-tools-stay-a-plain-passthrough =
    pkgs.runCommand "mcp-logs-and-traces-disabled-tools-plain-passthrough" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              logs.enable = true;
              logs.mcp = {
                enable = true;
                disabledTools = [ "documentation" ];
              };
              traces.enable = true;
              traces.mcp = {
                enable = true;
                disabledTools = [ "documentation" ];
              };
            };
          };
          logsVal = evaluated.config.systemd.services.mcp-victorialogs.environment.MCP_DISABLED_TOOLS;
          tracesVal = evaluated.config.systemd.services.mcp-victoriatraces.environment.MCP_DISABLED_TOOLS;
          checks = {
            "logs disabledTools adds only the module default (flags)" = logsVal == "flags,documentation";
            "traces disabledTools stays a plain passthrough" = tracesVal == "documentation";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "logs/traces disabledTools unexpectedly unioned with something: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # The MCP servers call their backend directly, outside vmauth's read-tier
  # endpoint allow-list (docs/decisions/0021, 0023), so tools whose backend
  # endpoint is not on that list are off by default.
  mcp-leaky-tools-are-disabled-by-default =
    pkgs.runCommand "mcp-leaky-tools-disabled-by-default" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              metrics.mcp.enable = true;
              logs.enable = true;
              logs.mcp.enable = true;
              traces.enable = true;
              traces.mcp.enable = true;
            };
          };
          tools =
            unit:
            lib.splitString "," (
              evaluated.config.systemd.services.${unit}.environment.MCP_DISABLED_TOOLS or ""
            );
          checks = {
            "logs disables flags" = lib.elem "flags" (tools "mcp-victorialogs");
            "metrics disables active_queries" = lib.elem "active_queries" (tools "mcp-victoriametrics");
            "metrics disables top_queries" = lib.elem "top_queries" (tools "mcp-victoriametrics");
            "metrics disables tsdb_status" = lib.elem "tsdb_status" (tools "mcp-victoriametrics");
            "metrics keeps the upstream defaults" = lib.all (t: lib.elem t (tools "mcp-victoriametrics")) [
              "export"
              "flags"
              "test_rules"
            ];
            "metrics does not disable query tools" = !(lib.elem "query" (tools "mcp-victoriametrics"));
            "traces has nothing to disable" =
              !(evaluated.config.systemd.services.mcp-victoriatraces.environment ? MCP_DISABLED_TOOLS);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "MCP default-disabled tools wrong: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # enabledTools lifts a module default; the operator's disabledTools still adds.
  mcp-enabled-tools-lifts-a-module-default =
    pkgs.runCommand "mcp-enabled-tools-lifts-a-module-default" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              metrics.mcp = {
                enable = true;
                enabledTools = [ "tsdb_status" ];
                disabledTools = [ "documentation" ];
              };
              logs.enable = true;
              logs.mcp = {
                enable = true;
                enabledTools = [ "flags" ];
              };
            };
          };
          tools =
            unit:
            lib.splitString "," (
              evaluated.config.systemd.services.${unit}.environment.MCP_DISABLED_TOOLS or ""
            );
          checks = {
            "logs flags re-enabled (variable absent)" =
              !(evaluated.config.systemd.services.mcp-victorialogs.environment ? MCP_DISABLED_TOOLS);
            "metrics tsdb_status re-enabled" = !(lib.elem "tsdb_status" (tools "mcp-victoriametrics"));
            "metrics other module defaults stay" =
              lib.elem "active_queries" (tools "mcp-victoriametrics")
              && lib.elem "top_queries" (tools "mcp-victoriametrics");
            "metrics upstream defaults stay" = lib.elem "test_rules" (tools "mcp-victoriametrics");
            "metrics disabledTools still added" = lib.elem "documentation" (tools "mcp-victoriametrics");
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "MCP enabledTools wrong: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Real binaries over JSON-RPC through vmauth: the disabled tools are gone
  # from tools/list and refused on tools/call, query tools still answer, and
  # enabledTools brings a tool back.
  mcp-leaky-tools-refused-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-leaky-tools";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics.enable = true;
        metrics.mcp.enable = true;
        logs.enable = true;
        logs.mcp.enable = true;
        traces.enable = true;
        traces.mcp.enable = true;
        vmauth.adminPasswordFile = "${pkgs.writeText "mcp-test-admin-password" "mcp-test-admin-password-value"}";
      };
    };

    containers.reenabled = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        logs.enable = true;
        logs.mcp = {
          enable = true;
          enabledTools = [ "flags" ];
        };
        vmauth.adminPasswordFile = "${pkgs.writeText "mcp-test-admin-password" "mcp-test-admin-password-value"}";
      };
    };

    testScript = ''
      import json
      ${testLib.waitActivePython}

      AUTH = "-u admin:mcp-test-admin-password-value"  # gitleaks:allow
      HDRS = "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'"


      def post(node, route, body, session=None):
          sess = f"-H 'Mcp-Session-Id: {session}' " if session else ""
          return node.succeed(
              f"curl -sf -D - {AUTH} {HDRS} {sess}"
              f"-X POST 'http://127.0.0.1:4204/mcp/{route}' -d '{json.dumps(body)}'"
          )


      def parse(out):
          head, _, payload = out.replace("\r\n", "\n").partition("\n\n")
          sid = next((l.split(":", 1)[1].strip() for l in head.splitlines()
                      if l.lower().startswith("mcp-session-id:")), None)
          data = "".join(l[5:] for l in payload.splitlines() if l.startswith("data:")) or payload
          return sid, (json.loads(data) if data.strip() else None)


      def open_session(node, route):
          out = post(node, route, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
              "protocolVersion": "2024-11-05", "capabilities": {},
              "clientInfo": {"name": "victoria-stack-test", "version": "1.0"}}})
          sid, _ = parse(out)
          post(node, route, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
          return sid


      def rpc(node, route, sid, method, params):
          _, r = parse(post(node, route, {"jsonrpc": "2.0", "id": 2, "method": method, "params": params}, sid))
          return r


      def tool_names(node, route):
          sid = open_session(node, route)
          r = rpc(node, route, sid, "tools/list", {})
          return sid, {t["name"] for t in r["result"]["tools"]}


      def refused(r):
          return "error" in r or r.get("result", {}).get("isError", False)


      start_all()
      for unit in ("mcp-victoriametrics", "mcp-victorialogs", "mcp-victoriatraces", "vmauth"):
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4204)
      wait_active(reenabled, "mcp-victorialogs.service")
      wait_active(reenabled, "vmauth.service")
      reenabled.wait_for_open_port(4204)

      sid, names = tool_names(machine, "logs")
      assert "flags" not in names, f"logs: flags must be disabled, got {sorted(names)}"
      assert "query" in names, f"logs: query must stay, got {sorted(names)}"
      assert refused(rpc(machine, "logs", sid, "tools/call", {"name": "flags", "arguments": {}})), \
          "logs: flags call must be refused"
      ok = rpc(machine, "logs", sid, "tools/call", {"name": "query", "arguments": {"query": "*", "limit": 1, "start": "2000-01-01T00:00:00Z"}})
      assert not refused(ok), f"logs: query must still work: {ok!r}"

      sid, names = tool_names(machine, "metrics")
      for gone in ("active_queries", "top_queries", "tsdb_status", "flags", "export", "test_rules"):
          assert gone not in names, f"metrics: {gone} must be disabled, got {sorted(names)}"
      for kept in ("query", "labels", "series", "metrics_metadata"):
          assert kept in names, f"metrics: {kept} must stay, got {sorted(names)}"
      assert refused(rpc(machine, "metrics", sid, "tools/call", {"name": "tsdb_status", "arguments": {}})), \
          "metrics: tsdb_status call must be refused"
      ok = rpc(machine, "metrics", sid, "tools/call", {"name": "labels", "arguments": {}})
      assert not refused(ok), f"metrics: labels must still work: {ok!r}"

      sid, names = tool_names(machine, "traces")
      assert "services" in names and "traces" in names, f"traces: query tools missing: {sorted(names)}"

      sid, names = tool_names(reenabled, "logs")
      assert "flags" in names, f"enabledTools = [ flags ] must bring flags back, got {sorted(names)}"
      ok = rpc(reenabled, "logs", sid, "tools/call", {"name": "flags", "arguments": {}})
      # The tool is back, but /flags is outside vmauth's read allow-list and the
      # MCP now calls vmauth, so enabling it only yields vmauth's refusal.
      assert refused(ok) and "missing route" in json.dumps(ok), f"re-enabled flags must hit vmauth's 400: {ok!r}"
    '';
  };

  # The metrics and logs MCP servers call vmauth's read tier with the CALLER'S
  # token (docs/decisions/0023): vmauth decides who may read what, and the
  # tool arguments cannot steer a request outside its allow-list.
  mcp-uses-the-callers-token-through-vmauth =
    let
      # Same JSON-RPC client for both containers: `auth` is the curl
      # credential flags, `route` is metrics or logs.
      clientPython = ''
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


        def open_session(node, route, auth):
            status, sid, data = post(node, route, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "victoria-stack-test", "version": "1.0"}}}, auth)
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
      adminPassword = "${pkgs.writeText "mcp-test-admin-password" "mcp-test-admin-password-value"}";
      readTokens = pkgs.writeText "mcp-caller-read-tokens.yaml" ''
        tokens:
          - token: mcp-metrics-only-read-token # gitleaks:allow
            backends: ["metrics"]
          - token: mcp-logs-only-read-token # gitleaks:allow
            backends: ["logs"]
      '';
      fakeBackend = pkgs.writeText "mcp-fake-backend.py" ''
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
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-mcp-callers-token";

      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp.enable = true;
          logs.enable = true;
          logs.mcp.enable = true;
          vmauth.adminPasswordFile = adminPassword;
          vmauth.readTokensFile = "${readTokens}";
        };
      };

      # vmauth's metrics and logs backends are a recording fake: it sees every
      # request vmauth lets through, so "the backend never saw it" is checkable.
      containers.recorder = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp.enable = true;
          metrics.effectiveUrl = lib.mkForce "http://127.0.0.1:9101";
          logs.enable = true;
          logs.mcp.enable = true;
          logs.effectiveUrl = lib.mkForce "http://127.0.0.1:9101";
          vmauth.adminPasswordFile = adminPassword;
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

        ADMIN = "-u admin:mcp-test-admin-password-value"  # gitleaks:allow
        METRICS_TOKEN = "-H 'Authorization: Bearer mcp-metrics-only-read-token'"  # gitleaks:allow
        LOGS_TOKEN = "-H 'Authorization: Bearer mcp-logs-only-read-token'"  # gitleaks:allow

        start_all()
        for unit in ("mcp-victoriametrics", "mcp-victorialogs", "vmauth"):
            wait_active(machine, f"{unit}.service")
            wait_active(recorder, f"{unit}.service")
        machine.wait_for_open_port(4204)
        recorder.wait_for_open_port(4204)

        # Seed real data in the real backends (raw ports: the write door is not
        # under test here).
        machine.succeed("curl -sf -X POST 'http://127.0.0.1:4201/api/v1/import/prometheus' "
                        "-d 'mcp_caller_token_test_metric 1'")
        machine.succeed(
            "echo '{\"log\":{\"message\":\"mcp_caller_token_test_log\"},\"date\":\"0\",\"stream\":\"mcp-test\"}' | "
            "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
            "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'")
        machine.wait_until_succeeds(
            "curl -sf -u admin:mcp-test-admin-password-value "  # gitleaks:allow
            "'http://127.0.0.1:4204/metrics/api/v1/query?query=mcp_caller_token_test_metric' | grep -q '\"value\"'")
        machine.wait_until_succeeds(
            "curl -sf -u admin:mcp-test-admin-password-value "  # gitleaks:allow
            "'http://127.0.0.1:4204/logs/select/logsql/query' -d 'query=mcp_caller_token_test_log' "
            "| grep -q mcp_caller_token_test_log")

        METRICS_CALL = ("metrics", "label_values", {"label_name": "__name__"})
        LOGS_CALL = ("logs", "query", {"query": "*", "limit": 5, "start": "2000-01-01T00:00:00Z"})

        # The authorised token gets data through the MCP server: it only works
        # because the caller's own token reaches vmauth's read tier (without
        # passthrough the MCP sends an empty bearer and vmauth answers 401).
        for token, (route, tool, args), needle in (
            (METRICS_TOKEN, METRICS_CALL, "mcp_caller_token_test_metric"),
            (LOGS_TOKEN, LOGS_CALL, "mcp_caller_token_test_log"),
            (ADMIN, METRICS_CALL, "mcp_caller_token_test_metric"),
            (ADMIN, LOGS_CALL, "mcp_caller_token_test_log"),
        ):
            status, _, sid = open_session(machine, route, token)
            assert status == 200, f"{route}: initialize with an authorised credential: {status}"
            status, r = call(machine, route, token, sid, tool, args)
            assert status == 200 and not is_error(r) and needle in tool_text(r), \
                f"{route}/{tool}: authorised caller must get data, got {status} {r!r}"

        # The other scope gets vmauth's own refusal, not data: its token has no
        # route to this MCP server at all.
        for token, route in ((LOGS_TOKEN, "metrics"), (METRICS_TOKEN, "logs")):
            status, _, data = post(machine, route, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "victoria-stack-test", "version": "1.0"}}}, token)
            print(f"REFUSAL {route}: {status} {data!r}")
            assert status == 400 and "missing route" in data, \
                f"/mcp/{route} with the other backend's token must be vmauth's 400 missing route, got {status} {data!r}"

        # No credential at all: vmauth's 401 before any MCP server is reached.
        status, _, data = post(machine, "metrics", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, "")
        print(f"NOAUTH: {status} {data!r}")
        assert status == 401, f"no credential must be 401, got {status} {data!r}"

        # Hostile tool arguments. The recording backend sees every request
        # vmauth lets through; the self-monitoring pushes the backend itself
        # receives are filtered out.
        def recorded():
            lines = recorder.succeed("cat /var/lib/fake-backend/requests.log").splitlines()
            return [l for l in lines if "/api/v1/import/" not in l]


        status, _, sid = open_session(recorder, "metrics", ADMIN)
        assert status == 200
        _, r = call(recorder, "metrics", ADMIN, sid, "labels", {})
        assert not is_error(r), f"control call must reach the recording backend: {r!r}"
        assert [l.split(" | ")[0] for l in recorded()] == ["GET /api/v1/labels HTTP/1.1"], \
            f"the recording backend must see the control call: {recorded()!r}"


        def hostile(route, tool, args, refusal):
            before = recorded()
            _, _, sid = open_session(recorder, route, ADMIN)
            st, r = call(recorder, route, ADMIN, sid, tool, args)
            assert st == 200 and is_error(r) and refusal in tool_text(r), \
                f"{route}/{tool} {args!r}: expected an error containing {refusal!r}, got {r!r}"
            assert recorded() == before, \
                f"{route}/{tool} {args!r}: the backend saw a request: {recorded()[len(before):]!r}"


        # The Go client cleans `..` before sending, and the cleaned or
        # percent-encoded path is no allow-listed route: vmauth's 400.
        for label in ("x/../../flags", "x\r\nX-Injected: 1", "%2e%2e/%2e%2e/flags"):
            hostile("metrics", "label_values", {"label_name": label}, "400: user admin missing route")
        # The logs tenant never leaves the MCP server: it must parse as
        # AccountID:ProjectID numbers.
        for tenant in ("0:0/../../flags", "http://evil.example.invalid", "0\r\nX-Injected: 1"):
            hostile("logs", "query", {"query": "*", "start": "2000-01-01T00:00:00Z", "tenant": tenant},
                    "failed to get tenant")

        # An absolute URL as a name stays a path SEGMENT: it is an ordinary
        # allow-listed label-values read of a label with a strange name, sent to
        # the same backend, never to the host named in it.
        before = recorded()
        _, _, sid = open_session(recorder, "metrics", ADMIN)
        call(recorder, "metrics", ADMIN, sid, "label_values", {"label_name": "http://evil.example.invalid/x"})
        new = recorded()[len(before):]
        assert [l.split(" | ")[0] for l in new] == ["GET /api/v1/label/http:/evil.example.invalid/x/values HTTP/1.1"], \
            f"an absolute-URL label name must be a plain label read, got {new!r}"

        assert not any("flags" in l or "X-Injected=None" not in l for l in recorded()), recorded()
      '';
    };

  mcp-reachable-only-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-through-vmauth";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics.enable = true;
        metrics.mcp.enable = true;
        logs.enable = true;
        logs.mcp.enable = true;
        traces.enable = true;
        traces.mcp.enable = true;
        vmauth.adminPasswordFile = "${pkgs.writeText "mcp-test-admin-password" "mcp-test-admin-password-value"}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "mcp-victoriametrics.service")
      wait_active(machine, "mcp-victorialogs.service")
      wait_active(machine, "mcp-victoriatraces.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)

      # /mcp/* routes sit behind the read tier (vmauth.nix's readUrlMap),
      # same as every other read-only route -- confirmed empirically
      # before this fix: with no credential at all, vmauth rejects at
      # 401 ("missing 'Authorization' request header") before ever
      # reaching the backend, which the PREVIOUS version of this test
      # mistook for "routing reached the backend" (it never did -- every
      # route always got the exact same vmauth-local 401, proving
      # nothing about the 3 individual backend connections).
      no_cred_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' -X POST "
          "'http://127.0.0.1:4204/mcp/metrics' -H 'Content-Type: application/json' -d '{}'"
      )
      assert no_cred_code == "401", f"expected 401 with no credential, got {no_cred_code!r}"

      # With a real credential and a real MCP initialize handshake (not
      # just a generic malformed body -- confirmed live that `{}` alone
      # only ever gets a generic "Invalid session ID" 404 regardless of
      # which backend answered, not a distinguishing response), each
      # service's own serverInfo.name in the response proves this
      # specific route reached this specific backend, not just "a"
      # backend.
      expected_names = {
          "metrics": "VictoriaMetrics",
          "logs": "VictoriaLogs",
          "traces": "VictoriaTraces",
      }
      initialize_body = (
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
          '{"protocolVersion":"2024-11-05","capabilities":{},'
          '"clientInfo":{"name":"victoria-stack-test","version":"1.0"}}}'
      )
      for route, expected_name in expected_names.items():
          response = machine.succeed(
              f"curl -sf -u admin:mcp-test-admin-password-value -X POST "  # gitleaks:allow
              f"'http://127.0.0.1:4204/mcp/{route}' -H 'Content-Type: application/json' "
              "-H 'Accept: application/json, text/event-stream' "
              f"-d '{initialize_body}'"
          )
          assert expected_name in response, (
              f"/mcp/{route} through vmauth: expected serverInfo.name to "
              f"contain {expected_name!r}, got: {response!r}"
          )

      # The MCP route ends at a path boundary: a longer name that merely starts
      # with it is no route (vmauth's 400 "missing route"), not the MCP server.
      for route in ("metricsX", "logsX", "tracesX", "metrics-x"):
          code = machine.succeed(
              "curl -s -o /dev/null -w '%{http_code}' -u admin:mcp-test-admin-password-value "  # gitleaks:allow
              f"-X POST 'http://127.0.0.1:4204/mcp/{route}' -H 'Content-Type: application/json' -d '{{}}'"
          )
          assert code == "400", f"/mcp/{route} must be vmauth's 400 (no such route), got {code!r}"

      # The MCP servers' own listenAddress stay loopback-only by default
      # -- not directly reachable from outside without vmauth routing or
      # an explicit listenAddress override (checked separately below).
      machine.wait_for_open_port(4205)
      machine.wait_for_open_port(4206)
      machine.wait_for_open_port(4207)
    '';
  };

  # The metrics and logs MCP servers reach their backend through vmauth's read
  # tier with the caller's own Authorization header (docs/decisions/0023), so
  # vmauth stays the one authority. Traces keeps its direct backend connection
  # until its binary can forward a token. The backend's effectiveUrl hop
  # (docs/decisions/0019) is now vmauth's business, not the MCP unit's.
  mcp-passthrough-env-and-entrypoint =
    let
      evalMcp =
        extra:
        (evalWith {
          services.victoriaStack = lib.recursiveUpdate {
            metrics.enable = true;
            metrics.mcp.enable = true;
            logs.enable = true;
            logs.mcp.enable = true;
            traces.enable = true;
            traces.mcp.enable = true;
          } extra;
        }).config;
      env = cfg: unit: cfg.systemd.services.${unit}.environment;
      default = evalMcp { };
      moved = evalMcp { vmauth.listenAddress = "127.0.0.1:4300"; };
      wildcard = evalMcp { vmauth.listenAddress = "0.0.0.0:4301"; };
      overridden = evalMcp {
        metrics.effectiveUrl = lib.mkForce "http://victoria-stack-test.example.invalid:9999";
      };
      metricsEnv = env default "mcp-victoriametrics";
      logsEnv = env default "mcp-victorialogs";
      tracesEnv = env default "mcp-victoriatraces";
    in
    mkTableCheck "mcp-passthrough-env-and-entrypoint" {
      "metrics forwards the Authorization header" =
        (metricsEnv.MCP_PASSTHROUGH_HEADERS or null) == "Authorization";
      "logs forwards the Authorization header" =
        (logsEnv.MCP_PASSTHROUGH_HEADERS or null) == "Authorization";
      "metrics entrypoint is vmauth plus /metrics" =
        metricsEnv.VM_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4204/metrics";
      "logs entrypoint is vmauth plus /logs" =
        logsEnv.VL_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4204/logs";
      "the entrypoint follows vmauth.listenAddress" =
        (env moved "mcp-victoriametrics").VM_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4300/metrics"
        && (env moved "mcp-victorialogs").VL_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4300/logs";
      "a wildcard vmauth address is dialled on loopback" =
        (env wildcard "mcp-victoriametrics").VM_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4301/metrics";
      "metrics.effectiveUrl no longer reaches the MCP unit" =
        (env overridden "mcp-victoriametrics").VM_INSTANCE_ENTRYPOINT == "http://127.0.0.1:4204/metrics";
      "traces is left alone: no passthrough, raw backend" =
        !(tracesEnv ? MCP_PASSTHROUGH_HEADERS)
        && tracesEnv.VT_INSTANCE_ENTRYPOINT == default.services.victoriaStack.traces.effectiveUrl;
      # No Wants=: it would let an MCP restart cut short vmauth's restart backoff.
      "metrics and logs MCP start after vmauth, without pulling it in" =
        lib.all
          (
            unit:
            lib.elem "vmauth.service" default.systemd.services.${unit}.after
            && !lib.elem "vmauth.service" default.systemd.services.${unit}.wants
          )
          [
            "mcp-victoriametrics"
            "mcp-victorialogs"
          ];
    };

  mcp-metrics-requires-vmauth = testLib.mkAssertionFiresCheck {
    name = "mcp-metrics-requires-vmauth";
    module =
      { lib, ... }:
      {
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp.enable = true;
          vmauth.enable = lib.mkForce false;
        };
      };
    expectMessageSubstring = "metrics.mcp.enable requires services.victoriaStack.vmauth.enable";
  };

  mcp-logs-requires-vmauth = testLib.mkAssertionFiresCheck {
    name = "mcp-logs-requires-vmauth";
    module =
      { lib, ... }:
      {
        services.victoriaStack = {
          logs.enable = true;
          logs.mcp.enable = true;
          vmauth.enable = lib.mkForce false;
        };
      };
    expectMessageSubstring = "logs.mcp.enable requires services.victoriaStack.vmauth.enable";
  };

  # vmauth's own `after=` must include the traces MCP service -- without it,
  # vmauth could route to /mcp/traces before that unit's readiness probe has
  # passed. The metrics and logs MCP units start AFTER vmauth instead (they
  # call its read tier); listing them here too would be an ordering cycle.
  vmauth-after-includes-the-traces-mcp-service =
    pkgs.runCommand "vmauth-after-includes-the-traces-mcp-service" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              metrics.mcp.enable = true;
              logs.enable = true;
              logs.mcp.enable = true;
              traces.enable = true;
              traces.mcp.enable = true;
            };
          };
          after = evaluated.config.systemd.services.vmauth.after;
        in
        if
          lib.elem "mcp-victoriatraces.service" after
          && !lib.elem "mcp-victoriametrics.service" after
          && !lib.elem "mcp-victorialogs.service" after
        then
          "echo OK > $out"
        else
          throw "vmauth.service's `after` must list only the traces MCP unit: ${builtins.toJSON after}"
      );

  # Each MCP unit starts after the backend it talks to; without it the MCP
  # server can come up first and its readiness probe waits on a backend that
  # has not started.
  mcp-units-start-after-their-backend = pkgs.runCommand "mcp-units-start-after-their-backend" { } (
    let
      evaluated = evalWith {
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp.enable = true;
          logs.enable = true;
          logs.mcp.enable = true;
          traces.enable = true;
          traces.mcp.enable = true;
        };
      };
      after = unit: evaluated.config.systemd.services.${unit}.after;
      expected = {
        mcp-victoriametrics = "victoriametrics.service";
        mcp-victorialogs = "victorialogs.service";
        mcp-victoriatraces = "victoriatraces.service";
      };
      missing = lib.attrNames (
        lib.filterAttrs (unit: backend: !(lib.elem backend (after unit))) expected
      );
    in
    if missing == [ ] then
      "echo OK > $out"
    else
      throw "MCP units not ordered after their backend: ${builtins.toJSON missing}"
  );

  mcp-reachable-directly-when-vmauth-off = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-direct-without-vmauth";

    containers.machine =
      { lib, ... }:
      {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          traces.enable = true;
          traces.mcp = {
            enable = true;
            listenAddress = "0.0.0.0:4207";
          };
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "mcp-victoriatraces.service")
      # (Only traces: the metrics and logs MCP servers need vmauth.) vmauth must not even exist/start -- confirmed separately in the
      # vmauth test group's own no-op check; here the point is that mcp
      # itself works fine standalone.
      machine.wait_for_open_port(4207)
    '';
  };

  # Same wildcard handling storage.nix pins for the 3 storage services:
  # probing a wildcard address as a destination is unreliable, so the
  # readiness probe must substitute loopback for each wildcard form.
  mcp-wildcard-listen-address-readiness-substitutes-loopback =
    pkgs.runCommand "mcp-wildcard-readiness-substitutes-loopback" { }
      (
        let
          execStartPost =
            listenAddress:
            (evalWith {
              services.victoriaStack.metrics = {
                enable = true;
                mcp = {
                  enable = true;
                  inherit listenAddress;
                };
              };
            }).config.systemd.services.mcp-victoriametrics.serviceConfig.ExecStartPost;
          checks = {
            "IPv4 wildcard" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (
              execStartPost "0.0.0.0:19997"
            );
            "IPv6 wildcard" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (
              execStartPost "[::]:19997"
            );
            "bare :port" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (execStartPost ":19997");
            "specific address is probed as-is" = lib.hasInfix "http://10.1.2.3:19997/health/readiness" (
              execStartPost "10.1.2.3:19997"
            );
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "mcp wildcard readiness substitution broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Same margin as vmauth and the storage services: the 90s readiness probe must
  # not expire together with systemd's start timeout.
  mcp-start-timeout-leaves-a-minute-above-the-readiness-probe =
    pkgs.runCommand "mcp-start-timeout-margin" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
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
          };
          perUnit =
            unit:
            let
              t = probeAndStartSeconds evaluated.config.systemd.services.${unit};
            in
            {
              "${unit}: readiness waits up to 90s" = t.probe == 90;
              "${unit}: TimeoutStartSec is set, in whole seconds" = t.start != null;
              "${unit}: TimeoutStartSec is the probe plus 60s" = t.start == t.probe + 60;
            };
          checks =
            perUnit "mcp-victoriametrics" // perUnit "mcp-victorialogs" // perUnit "mcp-victoriatraces";
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "mcp start timeouts wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # vmauth off + MCP's listenAddress left at its loopback default: the
  # unit must come up cleanly and stay loopback-only -- no crash loop, no
  # surprise wildcard bind.
  mcp-without-vmauth-stays-loopback-by-default = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-loopback-default-without-vmauth";

    containers.machine =
      { lib, ... }:
      {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          traces.enable = true;
          traces.mcp.enable = true;
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "mcp-victoriatraces.service")
      machine.wait_for_open_port(4207)

      restarts = machine.succeed(
          "systemctl show mcp-victoriatraces.service --property=NRestarts --value"
      ).strip()
      assert restarts == "0", f"mcp unit restarted {restarts} times -- crash loop"

      listeners = machine.succeed("ss -Hltn 'sport = :4207'")
      assert "127.0.0.1:4207" in listeners, f"expected a loopback listener: {listeners!r}"
      for wildcard in ["0.0.0.0:4207", "[::]:4207", "*:4207"]:
          assert wildcard not in listeners, f"unexpected wildcard bind {wildcard}: {listeners!r}"
    '';
  };

  # An MCP server that dies at start must fail the start at once; its HTTP probe
  # used to keep polling for its whole 90s. The package override is a stand-in
  # that exits immediately.
  broken-mcp-unit-fails-when-its-main-process-dies-not-at-the-deadline = pkgs.testers.nixosTest {
    name = "victoria-stack-broken-mcp-unit";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        mcp = {
          enable = true;
          package = pkgs.writeShellScriptBin "mcp-victoriametrics" "exit 3";
        };
      };
      # A unit failing in a loop keeps the container's boot job pending.
      systemd.services.mcp-victoriametrics.wantedBy = lib.mkForce [ ];
    };

    testScript = ''
      ${testLib.brokenUnitFailureSeconds}
      start_all()
      took = broken_unit_failure_seconds(machine, "mcp-victoriametrics.service")
      print(f"mcp-victoriametrics.service: probe gave up {took:.1f}s after the start")
      assert took < 20, f"mcp-victoriametrics.service: took {took:.1f}s; its probe deadline is 90s"
    '';
  };

  # An MCP listener beyond loopback bypasses vmauth (no authentication, direct
  # backend access): one warning per service. A port below 1024 would crash-loop
  # the unit (no CAP_NET_BIND_SERVICE), so it is an assertion.
  mcp-exposure-warning-and-low-port-assertion =
    let
      eval =
        svc: mcp:
        (evalWith {
          services.victoriaStack.${svc} = {
            enable = true;
            mcp = {
              enable = true;
            }
            // mcp;
          };
        }).config;
      ours = lib.filter (lib.hasInfix "services.victoriaStack");
      warningsOf = svc: mcp: ours (eval svc mcp).warnings;
      warns = svc: addr: lib.length (warningsOf svc { listenAddress = addr; }) == 1;
      quiet = svc: addr: warningsOf svc { listenAddress = addr; } == [ ];
      lowPort =
        svc: addr:
        lib.any (a: !a.assertion && lib.hasInfix "${svc}.mcp.listenAddress" a.message)
          (eval svc { listenAddress = addr; }).assertions;
      perSvc =
        f:
        lib.all f [
          "metrics"
          "logs"
          "traces"
        ];
      disabledLogs =
        (evalWith {
          services.victoriaStack.logs = {
            enable = true;
            mcp.listenAddress = "0.0.0.0:80";
          };
        }).config;
    in
    mkTableCheck "mcp-exposure-warning-and-low-port-assertion" {
      "0.0.0.0:PORT warns" = perSvc (s: warns s "0.0.0.0:4300");
      ":PORT warns" = perSvc (s: warns s ":4300");
      "[::]:PORT warns" = perSvc (s: warns s "[::]:4300");
      "LAN-style address warns" = perSvc (s: warns s "192.0.2.10:4300");
      "a hostname warns" = perSvc (s: warns s "mcp.example.test:4300");
      "127.0.0.1 is quiet" = perSvc (s: quiet s "127.0.0.1:4300");
      "127.0.0.2 is quiet" = perSvc (s: quiet s "127.0.0.2:4300");
      "localhost is quiet" = perSvc (s: quiet s "localhost:4300");
      "[::1] is quiet" = perSvc (s: quiet s "[::1]:4300");
      "the default is quiet" = perSvc (s: warningsOf s { } == [ ]);
      "suppress silences it" = perSvc (
        s:
        warningsOf s {
          listenAddress = "0.0.0.0:4300";
          suppressExposureWarning = true;
        } == [ ]
      );
      "the warning names option, value, vmauth route and the suppress option" =
        let
          w = lib.concatStrings (warningsOf "logs" { listenAddress = "0.0.0.0:4300"; });
        in
        lib.all (n: lib.hasInfix n w) [
          "logs.mcp.listenAddress"
          "0.0.0.0:4300"
          "/mcp/logs"
          "logs.mcp.suppressExposureWarning"
        ];
      "disabled MCP gives no warning" = ours disabledLogs.warnings == [ ];
      "port 1 is rejected" = perSvc (s: lowPort s "127.0.0.1:1");
      "port 80 on the wildcard is rejected" = perSvc (s: lowPort s "0.0.0.0:80");
      "port 1023 is rejected" = perSvc (s: lowPort s "127.0.0.1:1023");
      "port 1024 is accepted" = perSvc (s: !lowPort s "127.0.0.1:1024");
      "the default port is accepted" = perSvc (s: !lowPort s "127.0.0.1:4205");
      "a disabled MCP service is not asserted" =
        !lib.any (a: !a.assertion && lib.hasInfix "mcp.listenAddress" a.message) disabledLogs.assertions;
    };
}
