{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith probeAndStartSeconds;

  # Same shape as storage.nix's mkHardeningCheck, minus LimitNOFILE --
  # no nixpkgs module to confirm a LimitNOFILE value against here. The
  # wait4x readiness probe itself (mcp.nix) has its own dedicated eval
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
            # logs has no upstream-default-disabled set of its own
            # (unlike metrics, see below) -- stays absent when unset.
            "MCP_DISABLED_TOOLS absent when unset" = !(envUnset ? MCP_DISABLED_TOOLS);
            "MCP_LOG_LEVEL present when set" = (envSet.MCP_LOG_LEVEL or null) == "warn";
            "MCP_LOG_FORMAT present when set" = (envSet.MCP_LOG_FORMAT or null) == "text";
            "MCP_DISABLED_TOOLS joined with commas when set" =
              (envSet.MCP_DISABLED_TOOLS or null) == "documentation,some-other-tool";
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
  # own (confirmed from their own sources, no such hardcoded fallback),
  # so disabledTools stays a plain, unmodified passthrough there -- the
  # metrics-specific union above must not leak into the other two.
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
            "logs disabledTools stays a plain passthrough" = logsVal == "documentation";
            "traces disabledTools stays a plain passthrough" = tracesVal == "documentation";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "logs/traces disabledTools unexpectedly unioned with something: ${builtins.toJSON (builtins.attrNames failed)}"
      );

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

  # effectiveUrl (docs/decisions/0019), not listenAddress directly -- a
  # future remoteUrl-style override only reaches mcp.nix's own backend
  # connection through this seam; confirms it's genuinely honored, not
  # just present in the option schema.
  mcp-metrics-entrypoint-uses-effective-url =
    pkgs.runCommand "mcp-metrics-entrypoint-uses-effective-url" { }
      (
        let
          overrideUrl = "http://victoria-stack-test.example.invalid:9999";
          evaluated = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              mcp.enable = true;
              effectiveUrl = lib.mkForce overrideUrl;
            };
          };
          entrypoint =
            evaluated.config.systemd.services.mcp-victoriametrics.environment.VM_INSTANCE_ENTRYPOINT;
        in
        if entrypoint == overrideUrl then
          "echo OK > $out"
        else
          throw "VM_INSTANCE_ENTRYPOINT did not track metrics.effectiveUrl: expected ${overrideUrl}, got ${entrypoint}"
      );

  # vmauth's own `after=` must include each enabled MCP service -- without
  # it, vmauth could start routing to /mcp/* before the corresponding
  # mcp-victoria* unit (and its own wait4x readiness probe) has even
  # begun, the same ordering gap already fixed for the 3 storage backends.
  vmauth-after-includes-enabled-mcp-services =
    pkgs.runCommand "vmauth-after-includes-enabled-mcp-services" { }
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
          expected = [
            "mcp-victoriametrics.service"
            "mcp-victorialogs.service"
            "mcp-victoriatraces.service"
          ];
          missing = lib.filter (e: !(lib.elem e after)) expected;
        in
        if missing == [ ] then
          "echo OK > $out"
        else
          throw "vmauth.service's `after` is missing: ${builtins.toJSON missing}"
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
          metrics.enable = true;
          metrics.mcp = {
            enable = true;
            listenAddress = "0.0.0.0:4205";
          };
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "mcp-victoriametrics.service")
      # vmauth must not even exist/start -- confirmed separately in the
      # vmauth test group's own no-op check; here the point is that mcp
      # itself works fine standalone.
      machine.wait_for_open_port(4205)
    '';
  };

  # Same wildcard handling storage.nix pins for the 3 storage services:
  # probing a wildcard address as a destination is unreliable, so the
  # readiness probe must substitute loopback for each wildcard form.
  mcp-wildcard-listen-address-readiness-substitutes-loopback =
    pkgs.runCommand "mcp-wildcard-readiness-substitutes-loopback" { }
      (
        let
          postStart =
            listenAddress:
            (evalWith {
              services.victoriaStack.metrics = {
                enable = true;
                mcp = {
                  enable = true;
                  inherit listenAddress;
                };
              };
            }).config.systemd.services.mcp-victoriametrics.postStart;
          checks = {
            "IPv4 wildcard" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (
              postStart "0.0.0.0:19997"
            );
            "IPv6 wildcard" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (postStart "[::]:19997");
            "bare :port" = lib.hasInfix "http://127.0.0.1:19997/health/readiness" (postStart ":19997");
            "specific address is probed as-is" = lib.hasInfix "http://10.1.2.3:19997/health/readiness" (
              postStart "10.1.2.3:19997"
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
          metrics.enable = true;
          metrics.mcp.enable = true;
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "mcp-victoriametrics.service")
      machine.wait_for_open_port(4205)

      restarts = machine.succeed(
          "systemctl show mcp-victoriametrics.service --property=NRestarts --value"
      ).strip()
      assert restarts == "0", f"mcp unit restarted {restarts} times -- crash loop"

      listeners = machine.succeed("ss -Hltn 'sport = :4205'")
      assert "127.0.0.1:4205" in listeners, f"expected a loopback listener: {listeners!r}"
      for wildcard in ["0.0.0.0:4205", "[::]:4205", "*:4205"]:
          assert wildcard not in listeners, f"unexpected wildcard bind {wildcard}: {listeners!r}"
    '';
  };
}
