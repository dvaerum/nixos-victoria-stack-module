{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkWarningFiresCheck mkNoWarningsCheck evalWith;

  # Shared across the hardening/readiness/manageTmpfiles checks below --
  # one evalModules pass per service is enough to introspect all of it.
  mkHardeningCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      enableModule,
      expectLimitNOFILE, # true for metrics/traces, false for logs -- matches nixpkgs' own asymmetry
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith enableModule;
        sc = evaluated.config.systemd.services.${serviceName}.serviceConfig;
        postStart = evaluated.config.systemd.services.${serviceName}.postStart or "";
        # A representative subset of nixpkgs' own profile -- not every
        # single field, enough to catch "the hardening pass was dropped or
        # never applied" as a class of regression.
        hardeningChecks = {
          "NoNewPrivileges" = (sc.NoNewPrivileges or null) == true;
          "ProtectSystem" = (sc.ProtectSystem or null) == "full";
          "PrivateDevices" = (sc.PrivateDevices or null) == true;
          "MemoryDenyWriteExecute" = (sc.MemoryDenyWriteExecute or null) == true;
          "RestrictAddressFamilies" =
            (sc.RestrictAddressFamilies or null) == [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
          "LimitNOFILE" = (sc.LimitNOFILE or null) == (if expectLimitNOFILE then 1048576 else null);
          "wait4x readiness (not a hand-rolled curl loop)" = lib.hasInfix "wait4x" postStart;
          # Orders the unit after the dataDir's own mount (e.g. a ZFS
          # dataset) -- a no-op for the default path under /.
          "RequiresMountsFor dataDir" =
            (evaluated.config.systemd.services.${serviceName}.unitConfig.RequiresMountsFor or null) == toString
              evaluated.config.services.victoriaStack.${lib.removePrefix "victoria" serviceName}.dataDir;
        };
        failed = lib.filterAttrs (_: ok: !ok) hardeningChecks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw ''
          ${serviceName}'s serviceConfig is missing expected hardening/readiness:
          ${builtins.toJSON (builtins.attrNames failed)}
        ''
    );

  # Previously only the IPv4 wildcard (0.0.0.0) substitution was
  # exercised (indirectly, via the default listenAddress never being a
  # wildcard in any other test) -- the IPv6 wildcard form ([::]) is an
  # equally legitimate -httpListenAddr value but was never confirmed to
  # get the same loopback substitution in the readiness probe. Found
  # during Round 2 review: the substitution condition only checked for
  # the IPv4 prefix, so [::]:PORT fell through to probing the wildcard
  # address itself as a destination, unlike the documented/tested
  # 0.0.0.0 case.
  #
  # A THIRD wildcard form -- a bare ":<port>" with no host part at all --
  # was added in Phase 43, found by a fresh-agent review that confirmed
  # it empirically: the real pinned-nixpkgs victoriametrics/victorialogs/
  # victoriatraces modules' own postStart already handles this exact
  # prefix the same way, but this project's own isWildcard check never
  # did, and curl (which wait4x's underlying Go HTTP client does NOT
  # share the same failure mode with) flatly rejects a host-less URL.
  # Reproduced directly: wait4x against a real running instance behind a
  # bare ":<port>" listenAddress succeeded 5/5 times in one run, then
  # timed out 20/20 times in an immediately following run -- a genuine,
  # non-deterministic flake tied to IPv6-vs-IPv4 getaddrinfo() ordering,
  # not a one-off fluke.
  mkWildcardReadinessCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      serviceAttr, # "metrics" | "logs" | "traces"
    }:
    pkgs.runCommand name { } (
      let
        ipv4 = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = "0.0.0.0:19998";
          };
        };
        ipv6 = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = "[::]:19998";
          };
        };
        bare = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = ":19998";
          };
        };
        postStart = evaluated: evaluated.config.systemd.services.${serviceName}.postStart;
        checks = {
          "IPv4 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart ipv4);
          "IPv6 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart ipv6);
          "bare :port substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart bare);
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s wildcard-listenAddress readiness substitution broken: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraFlags, and a listenAddress override all reaching ExecStart /
  # effectiveUrl correctly. One shared check applied per service rather
  # than 3x near-identical hand-written tests.
  mkExecStartOptionsCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      serviceAttr, # "metrics" | "logs" | "traces"
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            retentionPeriod = "30d";
            extraFlags = [ "-search.maxUniqueTimeseries=300000" ];
            listenAddress = "127.0.0.1:19999";
          };
        };
        execStart = evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStart;
        effectiveUrl = evaluated.config.services.victoriaStack.${serviceAttr}.effectiveUrl;
        checks = {
          "retentionPeriod flag present" = lib.hasInfix "-retentionPeriod=30d" execStart;
          "extraFlags flag present" = lib.hasInfix "-search.maxUniqueTimeseries=300000" execStart;
          "listenAddress override reaches ExecStart" =
            lib.hasInfix "-httpListenAddr=127.0.0.1:19999" execStart;
          "listenAddress override reaches effectiveUrl" = effectiveUrl == "http://127.0.0.1:19999";
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s ExecStart is missing: ${builtins.toJSON (builtins.attrNames failed)}\n${execStart}"
    );

  # Shared across all 3 storage services -- previously only metrics had
  # this coverage, even though manageTmpfiles/the tmpfiles-rule code path
  # is identical (copy-pasted) across metrics.nix/logs.nix/traces.nix.
  mkManageTmpfilesCheck =
    {
      name,
      serviceAttr, # "metrics" | "logs" | "traces"
      dataDir ? null, # null: leave dataDir at its default
      expectRule, # true: default (manageTmpfiles unset) should render a rule;
      # false: manageTmpfiles = false should suppress it entirely
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            dynamicUser = false;
          }
          // lib.optionalAttrs (dataDir != null) { inherit dataDir; }
          // lib.optionalAttrs (!expectRule) { manageTmpfiles = false; };
        };
        rules = evaluated.config.systemd.tmpfiles.rules;
        effectiveDir = toString evaluated.config.services.victoriaStack.${serviceAttr}.dataDir;
        hasRule = lib.any (lib.hasInfix effectiveDir) rules;
      in
      if hasRule == expectRule then
        "echo OK > $out"
      else if expectRule then
        throw "manageTmpfiles defaults to true -- expected a tmpfiles rule for ${effectiveDir}"
      else
        throw "manageTmpfiles = false must suppress the every-boot tmpfiles ownership rule entirely for ${effectiveDir}"
    );
in
{
  # Phase 3: metrics only. logs/traces checks are added here as their own
  # phases (4, 5) land, same file -- this is the `storage` test group as a
  # whole, built up incrementally with a red->green cycle per service.

  # --- eval-only: dynamicUser/dataDir warning behavior (fast, no container boot) ---

  metrics-dynamic-user-warning-fires-on-custom-data-dir = mkWarningFiresCheck {
    name = "metrics-dynamic-user-warning-fires-on-custom-data-dir";
    expectMessageSubstring = "dynamicUser";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        dataDir = "/data/victoria/metrics";
        # dynamicUser left at its true default -- exactly the
        # known-broken combination (docs/decisions/0009).
      };
    };
  };

  metrics-dynamic-user-warning-suppressible = mkNoWarningsCheck {
    name = "metrics-dynamic-user-warning-suppressible";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        dataDir = "/data/victoria/metrics";
        suppressDynamicUserWarning = true;
      };
    };
  };

  metrics-default-data-dir-no-warning = mkNoWarningsCheck {
    name = "metrics-default-data-dir-no-warning";
    module = {
      services.victoriaStack.metrics.enable = true;
      # dataDir left at its default, dynamicUser left at its true default --
      # the ordinary, non-broken case must never warn.
    };
  };

  metrics-static-user-custom-data-dir-no-warning = mkNoWarningsCheck {
    name = "metrics-static-user-custom-data-dir-no-warning";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        dataDir = "/data/victoria/metrics";
        dynamicUser = false;
        # The actual fix (dynamicUser = false) must never warn either --
        # only the broken combination should.
      };
    };
  };

  # Permanent regression guard for docs/decisions/0017's sequential
  # renumbering -- catches an accidental revert/drift back to any
  # individual binary's own upstream default, or vmauth/mcp's old
  # project-chosen numbers.
  port-defaults-match-the-sequential-scheme =
    pkgs.runCommand "port-defaults-match-sequential-scheme" { }
      (
        let
          evaluated = evalWith { };
          c = evaluated.config.services.victoriaStack;
          expected = {
            "metrics.listenAddress" = c.metrics.listenAddress == "127.0.0.1:4201";
            "logs.listenAddress" = c.logs.listenAddress == "127.0.0.1:4202";
            "traces.listenAddress" = c.traces.listenAddress == "127.0.0.1:4203";
            "vmauth.listenAddress" = c.vmauth.listenAddress == "127.0.0.1:4204";
            "metrics.mcp.listenAddress" = c.metrics.mcp.listenAddress == "127.0.0.1:4205";
            "logs.mcp.listenAddress" = c.logs.mcp.listenAddress == "127.0.0.1:4206";
            "traces.mcp.listenAddress" = c.traces.mcp.listenAddress == "127.0.0.1:4207";
          };
          failed = lib.filterAttrs (_: ok: !ok) expected;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "port defaults drifted from docs/decisions/0017's sequential scheme: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # docs/decisions/0019's structural seam: consumers (vmauth, Grafana)
  # must read effectiveUrl, never listenAddress directly -- this is the
  # one place a future remoteUrl feature would need to override.
  effective-url-is-internal-and-derived-from-listen-address =
    pkgs.runCommand "effective-url-is-internal-and-derived" { }
      (
        let
          evaluated = evalWith { services.victoriaStack.metrics.enable = true; };
          opt = evaluated.options.services.victoriaStack.metrics.effectiveUrl;
          checks = {
            "marked internal (excluded from generated docs)" = opt.internal or false;
            "derived from listenAddress by default" =
              evaluated.config.services.victoriaStack.metrics.effectiveUrl == "http://127.0.0.1:4201";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "effectiveUrl structural seam broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  metrics-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "metrics-wildcard-readiness-substitutes-loopback";
    serviceName = "victoriametrics";
    serviceAttr = "metrics";
  };

  logs-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "logs-wildcard-readiness-substitutes-loopback";
    serviceName = "victorialogs";
    serviceAttr = "logs";
  };

  traces-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "traces-wildcard-readiness-substitutes-loopback";
    serviceName = "victoriatraces";
    serviceAttr = "traces";
  };

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraFlags, and a listenAddress override all reaching ExecStart /
  # effectiveUrl correctly. One shared check applied per service rather
  # than 3x near-identical hand-written tests.
  metrics-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "metrics-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victoriametrics";
    serviceAttr = "metrics";
  };

  logs-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "logs-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victorialogs";
    serviceAttr = "logs";
  };

  traces-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "traces-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victoriatraces";
    serviceAttr = "traces";
  };

  metrics-hardening-profile-and-readiness = mkHardeningCheck {
    name = "metrics-hardening-profile-and-readiness";
    serviceName = "victoriametrics";
    enableModule = {
      services.victoriaStack.metrics.enable = true;
    };
    expectLimitNOFILE = true; # same as nixpkgs' own victoriametrics module
  };

  metrics-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "metrics";
    dataDir = "/data/victoria/metrics";
    expectRule = true;
  };

  metrics-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-false-rule-absent";
    serviceAttr = "metrics";
    dataDir = "/data/victoria/metrics";
    expectRule = false;
  };

  logs-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "logs";
    dataDir = "/data/victoria/logs";
    expectRule = true;
  };

  logs-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-false-rule-absent";
    serviceAttr = "logs";
    dataDir = "/data/victoria/logs";
    expectRule = false;
  };

  traces-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "traces";
    dataDir = "/data/victoria/traces";
    expectRule = true;
  };

  traces-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-false-rule-absent";
    serviceAttr = "traces";
    dataDir = "/data/victoria/traces";
    expectRule = false;
  };

  # --- container-boot: real systemd unit behavior ---

  metrics-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      # Prometheus exposition-format ingest -- the simplest real write path
      # VictoriaMetrics' own HTTP API supports natively, no extra tooling
      # needed beyond curl.
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_test_metric{label=\"roundtrip\"} 42' "
          "'http://127.0.0.1:4201/api/v1/import/prometheus'"
      )

      # VictoriaMetrics ingestion is not synchronous-to-query -- give it a
      # moment before asserting the value is queryable.
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_test_metric' "
          "| grep -q '\"value\":\\[.*,\"42\"\\]'"
      )
    '';
  };

  metrics-static-user-custom-data-dir = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-static-user-custom-data-dir";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        dataDir = "/data/victoria/metrics";
        dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      # Confirm it's genuinely running as the static user, not DynamicUser,
      # and that the custom dataDir is real and owned correctly -- the
      # whole point of this option combination (docs/decisions/0001).
      user = machine.succeed(
          "systemctl show victoriametrics.service --property=User --value"
      ).strip()
      assert user == "victoriametrics", f"expected static User=victoriametrics, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/metrics").strip()
      assert owner == "victoriametrics", f"expected /data/victoria/metrics owned by victoriametrics, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/metrics").strip()
      assert group == "victoriametrics", f"expected /data/victoria/metrics group-owned by victoriametrics, got {group!r}"

      # User+ownership alone doesn't prove the service can actually write
      # to and read from that directory -- a real ingest/query roundtrip
      # against the static-user + custom-dataDir combination specifically
      # (the default-dynamicUser combination already has its own
      # roundtrip test above; this confirms the same path isn't broken
      # by the static-user/custom-dataDir option combination).
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_static_user_test_metric{label=\"roundtrip\"} 7' "
          "'http://127.0.0.1:4201/api/v1/import/prometheus'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_static_user_test_metric' "
          "| grep -q victoria_stack_static_user_test_metric"
      )
    '';
  };

  metrics-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victoriametrics-override-marker";
        paths = [ pkgs.victoriametrics ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-metrics-package-override-takes-effect";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack.metrics = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("victoriametrics.service")
        exec_start = machine.succeed(
            "systemctl show victoriametrics.service --property=ExecStart --value"
        )
        assert "${overridePackage}" in exec_start, (
            f"expected ExecStart to resolve through the overridden package "
            f"(${overridePackage}), got: {exec_start!r}"
        )
      '';
    };

  # --- Phase 4: logs (same pattern as metrics above) ---

  logs-dynamic-user-warning-fires-on-custom-data-dir = mkWarningFiresCheck {
    name = "logs-dynamic-user-warning-fires-on-custom-data-dir";
    expectMessageSubstring = "dynamicUser";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
      };
    };
  };

  logs-dynamic-user-warning-suppressible = mkNoWarningsCheck {
    name = "logs-dynamic-user-warning-suppressible";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        suppressDynamicUserWarning = true;
      };
    };
  };

  logs-default-data-dir-no-warning = mkNoWarningsCheck {
    name = "logs-default-data-dir-no-warning";
    module = {
      services.victoriaStack.logs.enable = true;
    };
  };

  logs-static-user-custom-data-dir-no-warning = mkNoWarningsCheck {
    name = "logs-static-user-custom-data-dir-no-warning";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        dynamicUser = false;
      };
    };
  };

  logs-hardening-profile-and-readiness = mkHardeningCheck {
    name = "logs-hardening-profile-and-readiness";
    serviceName = "victorialogs";
    enableModule = {
      services.victoriaStack.logs.enable = true;
    };
    expectLimitNOFILE = false; # matches nixpkgs' own victorialogs module (no LimitNOFILE set)
  };

  logs-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)

      # JSON stream (ndjson) ingest -- VictoriaLogs' own HTTP API
      # (/insert/jsonline), confirmed from its real data-ingestion docs
      # rather than assumed to mirror VictoriaMetrics' API shape.
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_test_log_roundtrip\"}" 
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=victoria_stack_test_log_roundtrip' "
          "| grep -q victoria_stack_test_log_roundtrip"
      )
    '';
  };

  logs-static-user-custom-data-dir = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-static-user-custom-data-dir";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)

      user = machine.succeed(
          "systemctl show victorialogs.service --property=User --value"
      ).strip()
      assert user == "victorialogs", f"expected static User=victorialogs, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/logs").strip()
      assert owner == "victorialogs", f"expected /data/victoria/logs owned by victorialogs, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/logs").strip()
      assert group == "victorialogs", f"expected /data/victoria/logs group-owned by victorialogs, got {group!r}"

      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_static_user_test_log\"}" 
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=victoria_stack_static_user_test_log' "
          "| grep -q victoria_stack_static_user_test_log"
      )
    '';
  };

  logs-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victorialogs-override-marker";
        paths = [ pkgs.victorialogs ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-logs-package-override-takes-effect";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack.logs = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("victorialogs.service")
        exec_start = machine.succeed(
            "systemctl show victorialogs.service --property=ExecStart --value"
        )
        assert "${overridePackage}" in exec_start, (
            f"expected ExecStart to resolve through the overridden package "
            f"(${overridePackage}), got: {exec_start!r}"
        )
      '';
    };

  # --- Phase 5: traces (same pattern again) ---

  traces-dynamic-user-warning-fires-on-custom-data-dir = mkWarningFiresCheck {
    name = "traces-dynamic-user-warning-fires-on-custom-data-dir";
    expectMessageSubstring = "dynamicUser";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
      };
    };
  };

  traces-dynamic-user-warning-suppressible = mkNoWarningsCheck {
    name = "traces-dynamic-user-warning-suppressible";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        suppressDynamicUserWarning = true;
      };
    };
  };

  traces-default-data-dir-no-warning = mkNoWarningsCheck {
    name = "traces-default-data-dir-no-warning";
    module = {
      services.victoriaStack.traces.enable = true;
    };
  };

  traces-static-user-custom-data-dir-no-warning = mkNoWarningsCheck {
    name = "traces-static-user-custom-data-dir-no-warning";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        dynamicUser = false;
      };
    };
  };

  traces-hardening-profile-and-readiness = mkHardeningCheck {
    name = "traces-hardening-profile-and-readiness";
    serviceName = "victoriatraces";
    enableModule = {
      services.victoriaStack.traces.enable = true;
    };
    expectLimitNOFILE = true; # same as nixpkgs' own victoriatraces module
  };

  traces-retention-period-doc-states-real-7-day-default =
    pkgs.runCommand "traces-retention-period-doc-states-real-7-day-default" { }
      (
        let
          evaluated = evalWith { };
          description = evaluated.options.services.victoriaStack.traces.retentionPeriod.description;
        in
        if
          lib.hasInfix "7 day" description
          && !lib.hasInfix "effectively unbounded for this binary" description
        then
          "echo OK > $out"
        else
          throw ''
            traces.retentionPeriod's description must state the real
            upstream default (7 days), not claim it's unbounded. Actual
            description: ${description}
          ''
      );

  # Phase 39: metrics' and logs' own descriptions had the exact same
  # factually-wrong "effectively unbounded" claim traces' had (fixed in
  # docs/decisions/0020, for traces only, at the time) -- confirmed via
  # each binary's own --help: metrics defaults to 1 month, logs to 7
  # days, neither to unbounded. Same pattern as the traces check above.
  metrics-retention-period-doc-states-real-1-month-default =
    pkgs.runCommand "metrics-retention-period-doc-states-real-1-month-default" { }
      (
        let
          evaluated = evalWith { };
          description = evaluated.options.services.victoriaStack.metrics.retentionPeriod.description;
        in
        if
          lib.hasInfix "1 month" description
          && !lib.hasInfix "effectively unbounded for this binary" description
        then
          "echo OK > $out"
        else
          throw ''
            metrics.retentionPeriod's description must state the real
            upstream default (1 month), not claim it's unbounded. Actual
            description: ${description}
          ''
      );

  logs-retention-period-doc-states-real-7-day-default =
    pkgs.runCommand "logs-retention-period-doc-states-real-7-day-default" { }
      (
        let
          evaluated = evalWith { };
          description = evaluated.options.services.victoriaStack.logs.retentionPeriod.description;
        in
        if
          lib.hasInfix "7 day" description
          && !lib.hasInfix "effectively unbounded for this binary" description
        then
          "echo OK > $out"
        else
          throw ''
            logs.retentionPeriod's description must state the real
            upstream default (7 days), not claim it's unbounded. Actual
            description: ${description}
          ''
      );

  traces-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)

      # Minimal valid OTLP/HTTP JSON ExportTraceServiceRequest -- confirmed
      # from VictoriaTraces' own docs: it accepts OTLP natively and exposes
      # Jaeger Query Service JSON APIs for querying (it's built on top of
      # VictoriaLogs internally, but the ingest/query surface is OTLP in,
      # Jaeger API out, not VictoriaLogs' own LogsQL).
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000001\","
          "\"spanId\":\"0000000000000001\","
          "\"name\":\"victoria_stack_test_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_test_service"
      )
    '';
  };

  traces-static-user-custom-data-dir = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-static-user-custom-data-dir";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)

      user = machine.succeed(
          "systemctl show victoriatraces.service --property=User --value"
      ).strip()
      assert user == "victoriatraces", f"expected static User=victoriatraces, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/traces").strip()
      assert owner == "victoriatraces", f"expected /data/victoria/traces owned by victoriatraces, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/traces").strip()
      assert group == "victoriatraces", f"expected /data/victoria/traces group-owned by victoriatraces, got {group!r}"

      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_static_user_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000002\","
          "\"spanId\":\"0000000000000002\","
          "\"name\":\"victoria_stack_static_user_test_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_static_user_test_service"
      )
    '';
  };

  traces-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victoriatraces-override-marker";
        paths = [ pkgs.victoriatraces ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-traces-package-override-takes-effect";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack.traces = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("victoriatraces.service")
        exec_start = machine.succeed(
            "systemctl show victoriatraces.service --property=ExecStart --value"
        )
        assert "${overridePackage}" in exec_start, (
            f"expected ExecStart to resolve through the overridden package "
            f"(${overridePackage}), got: {exec_start!r}"
        )
      '';
    };

  # Disk-usage retention is logs/traces only -- victoria-metrics has no
  # such flag (its own `-help`).
  disk-usage-retention-reaches-execstart-for-logs-and-traces =
    pkgs.runCommand "disk-usage-retention" { }
      (
        let
          execStart =
            svc: unit: extra:
            (evalWith {
              services.victoriaStack.${svc} = {
                enable = true;
              }
              // extra;
            }).config.systemd.services.${unit}.serviceConfig.ExecStart;
          perService =
            svc: unit:
            let
              unset = execStart svc unit { };
              bytes = execStart svc unit { retentionMaxDiskSpaceUsageBytes = "500GB"; };
              percent = execStart svc unit { retentionMaxDiskUsagePercent = 80; };
            in
            {
              "${svc}: absent by default" = !(lib.hasInfix "retention.maxDisk" unset);
              "${svc}: bytes flag" = lib.hasInfix "-retention.maxDiskSpaceUsageBytes=500GB" bytes;
              "${svc}: percent flag" = lib.hasInfix "-retention.maxDiskUsagePercent=80" percent;
            };
          checks =
            perService "logs" "victorialogs"
            // perService "traces" "victoriatraces"
            // {
              "not offered on metrics" =
                !((evalWith { }).options.services.victoriaStack.metrics ? retentionMaxDiskSpaceUsageBytes);
            };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "disk-usage retention wiring broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  disk-usage-retention-bytes-and-percent-are-mutually-exclusive =
    pkgs.runCommand "disk-usage-retention-mutually-exclusive" { }
      (
        let
          fires =
            svc:
            lib.any
              (
                m: lib.hasInfix "retentionMaxDiskSpaceUsageBytes" m && lib.hasInfix "retentionMaxDiskUsagePercent" m
              )
              (
                map (a: a.message) (
                  builtins.filter (a: !a.assertion)
                    (evalWith {
                      services.victoriaStack.${svc} = {
                        enable = true;
                        retentionMaxDiskSpaceUsageBytes = "500GB";
                        retentionMaxDiskUsagePercent = 80;
                      };
                    }).config.assertions
                )
              );
        in
        if fires "logs" && fires "traces" then
          "echo OK > $out"
        else
          throw "expected a mutual-exclusion assertion for both logs and traces (logs=${builtins.toJSON (fires "logs")} traces=${builtins.toJSON (fires "traces")})"
      );

  metrics-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "metrics";
    expectRule = false;
  };

  logs-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "logs";
    expectRule = false;
  };

  traces-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "traces";
    expectRule = false;
  };

  # extraOptions was renamed to extraFlags (docs/decisions/0024): the old
  # name must keep working, produce the standard rename warning, and
  # render the identical ExecStart as the new name.
  extra-options-old-name-still-works-and-warns =
    pkgs.runCommand "extra-options-old-name-still-works-and-warns" { }
      (
        let
          flag = "-search.maxUniqueTimeseries=300000";
          perService =
            attr: unit:
            let
              viaOld = evalWith {
                services.victoriaStack.${attr} = {
                  enable = true;
                  extraOptions = [ flag ];
                };
              };
              viaNew = evalWith {
                services.victoriaStack.${attr} = {
                  enable = true;
                  extraFlags = [ flag ];
                };
              };
              execStart = e: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
              warned = lib.any (lib.hasInfix "${attr}.extraOptions") (
                lib.filter (lib.hasInfix "services.victoriaStack") viaOld.config.warnings
              );
            in
            {
              "${attr}: old name warns" = warned;
              "${attr}: same ExecStart as the new name" = execStart viaOld == execStart viaNew;
              "${attr}: flag reaches ExecStart" = lib.hasInfix flag (execStart viaOld);
            };
          checks =
            perService "metrics" "victoriametrics"
            // perService "logs" "victorialogs"
            // perService "traces" "victoriatraces";
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraOptions rename broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # --- snapshots (periodic creation + binary-native pruning) ---
  #
  # The snapshot API genuinely differs per binary (confirmed by probing
  # each one): VictoriaMetrics serves /snapshot/{create,list};
  # VictoriaLogs and VictoriaTraces reject those and serve
  # /internal/partition/snapshot/{create,list} instead. -snapshotsMaxAge
  # exists on all three. The partition-snapshot endpoints are POST-only
  # (VictoriaLogs answers a GET with "Only POST method is allowed").

  snapshots-eval-behaviour-for-all-three-services = pkgs.runCommand "snapshots-eval-behaviour" { } (
    let
      perService =
        attr: unit:
        let
          eval =
            snap:
            evalWith {
              services.victoriaStack.${attr} = {
                enable = true;
                snapshots = snap;
              };
            };
          execStart = e: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
          hasUnits =
            e: e.config.systemd.timers ? "${unit}-snapshot" && e.config.systemd.services ? "${unit}-snapshot";
          off = eval { };
          on = eval { enable = true; };
          noPrune = eval {
            enable = true;
            maxAge = null;
          };
          custom = eval {
            enable = true;
            schedule = "hourly";
            maxAge = "7d";
          };
        in
        {
          "${attr}: disabled by default -> no timer/service" = !(hasUnits off);
          "${attr}: disabled -> no -snapshotsMaxAge" = !(lib.hasInfix "snapshotsMaxAge" (execStart off));
          "${attr}: enabled -> timer and service exist" = hasUnits on;
          "${attr}: enabled -> default maxAge 30d" = lib.hasInfix "-snapshotsMaxAge=30d" (execStart on);
          "${attr}: default schedule is daily" =
            on.config.systemd.timers."${unit}-snapshot".timerConfig.OnCalendar == "daily";
          "${attr}: maxAge = null -> pruning flag absent but creation timer remains" =
            !(lib.hasInfix "snapshotsMaxAge" (execStart noPrune)) && hasUnits noPrune;
          "${attr}: custom maxAge and schedule render" =
            lib.hasInfix "-snapshotsMaxAge=7d" (execStart custom)
            && custom.config.systemd.timers."${unit}-snapshot".timerConfig.OnCalendar == "hourly";
        };
      checks =
        perService "metrics" "victoriametrics"
        // perService "logs" "victorialogs"
        // perService "traces" "victoriatraces";
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "snapshots eval behaviour broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # Real boot per binary: trigger the oneshot, then ask the service's OWN
  # list API (not just an exit code) and require a non-empty result.
  metrics-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)
      import json

      machine.succeed("systemctl start victoriametrics-snapshot.service")
      listed = json.loads(machine.succeed("curl -sf http://127.0.0.1:4201/snapshot/list"))
      assert listed["snapshots"], f"expected a snapshot, got {listed!r}"
    '';
  };

  logs-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)
      # A partition only exists once there is data in it.
      machine.succeed(
          "echo '{\"log\":{\"message\":\"snapshot_test_line\"},\"date\":\"0\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=snapshot_test_line' | grep -q snapshot_test_line"
      )
      import json

      machine.succeed("systemctl start victorialogs-snapshot.service")
      status, listed = machine.execute("curl -sS -X POST http://127.0.0.1:4202/internal/partition/snapshot/list")
      assert status == 0, f"snapshot list failed: {listed!r}"
      assert listed.lstrip().startswith("["), f"snapshot list was not a JSON list: {listed!r}"
      assert json.loads(listed), f"expected at least one snapshot, got {listed!r}"
    '';
  };

  traces-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"snapshot_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000008\","
          "\"spanId\":\"0000000000000008\","
          "\"name\":\"snapshot_test_span\",\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' | grep -q snapshot_test_service"
      )
      import json

      machine.succeed("systemctl start victoriatraces-snapshot.service")
      status, listed = machine.execute("curl -sS -X POST http://127.0.0.1:4203/internal/partition/snapshot/list")
      assert status == 0, f"snapshot list failed: {listed!r}"
      assert listed.lstrip().startswith("["), f"snapshot list was not a JSON list: {listed!r}"
      assert json.loads(listed), f"expected at least one snapshot, got {listed!r}"
    '';
  };

  # --- selfMonitoring: each service pushes its own /metrics page into the
  # local metrics database (docs/decisions/0026). A native flag family
  # (-pushmetrics.*) on all four binaries, so no timer/unit is involved.

  self-monitoring-flags-for-all-four-services = pkgs.runCommand "self-monitoring-flags" { } (
    let
      eval = m: evalWith { services.victoriaStack = m; };
      execStart = e: unit: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
      allBackends = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
      };
      # On by default whenever the metrics database is enabled.
      byDefault = eval allBackends;
      explicitlyOff = eval (
        lib.recursiveUpdate allBackends {
          metrics.selfMonitoring.enable = false;
          logs.selfMonitoring.enable = false;
          traces.selfMonitoring.enable = false;
          vmauth.selfMonitoring.enable = false;
        }
      );
      custom = eval (lib.recursiveUpdate allBackends { logs.selfMonitoring.interval = "1m"; });
      oneOff = eval (lib.recursiveUpdate allBackends { logs.selfMonitoring.enable = false; });
      # No metrics database on this host: nothing to push to, so off.
      noMetricsDb = eval {
        logs.enable = true;
        traces.enable = true;
      };
      url = "-pushmetrics.url=http://127.0.0.1:4201/api/v1/import/prometheus";
      perUnit = unit: job: {
        "${unit}: on by default when the metrics database is enabled" = lib.hasInfix url (
          execStart byDefault unit
        );
        "${unit}: default interval 30s" = lib.hasInfix "-pushmetrics.interval=30s" (
          execStart byDefault unit
        );
        "${unit}: labelled with its own job" = lib.hasInfix "'-pushmetrics.extraLabel=job=\"${job}\"'" (
          execStart byDefault unit
        );
        "${unit}: explicit false turns it off" =
          !(lib.hasInfix "pushmetrics" (execStart explicitlyOff unit));
      };
      checks =
        perUnit "victoriametrics" "victoriametrics"
        // perUnit "victorialogs" "victorialogs"
        // perUnit "victoriatraces" "victoriatraces"
        // perUnit "vmauth" "vmauth"
        // {
          "custom interval renders" = lib.hasInfix "-pushmetrics.interval=1m" (
            execStart custom "victorialogs"
          );
          "turning one service off leaves the others on" =
            !(lib.hasInfix "pushmetrics" (execStart oneOff "victorialogs"))
            && lib.hasInfix url (execStart oneOff "victoriatraces");
          "no metrics database -> off, and no assertion fires" =
            !(lib.hasInfix "pushmetrics" (execStart noMetricsDb "victorialogs"))
            && !(lib.hasInfix "pushmetrics" (execStart noMetricsDb "vmauth"))
            &&
              lib.filter (lib.hasInfix "selfMonitoring") (
                map (a: a.message) (builtins.filter (a: !a.assertion) noMetricsDb.config.assertions)
              ) == [ ];
        };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "selfMonitoring flags broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  self-monitoring-needs-the-metrics-database = pkgs.runCommand "self-monitoring-needs-metrics" { } (
    let
      failedFor =
        m:
        lib.filter (lib.hasInfix "selfMonitoring") (
          map (a: a.message) (
            builtins.filter (a: !a.assertion)
              (evalWith {
                services.victoriaStack = m;
              }).config.assertions
          )
        );
      checks = {
        "logs without metrics fires" =
          failedFor {
            logs = {
              enable = true;
              selfMonitoring.enable = true;
            };
          } != [ ];
        "vmauth without metrics fires" =
          failedFor {
            traces.enable = true;
            vmauth.selfMonitoring.enable = true;
          } != [ ];
        "with metrics enabled it does not fire" =
          failedFor {
            metrics.enable = true;
            logs = {
              enable = true;
              selfMonitoring.enable = true;
            };
          } == [ ];
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "selfMonitoring assertion broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # For real: all four push, and each one's series shows up in the metrics
  # database under its own job label.
  self-monitoring-series-really-arrive = pkgs.testers.nixosTest {
    name = "victoria-stack-self-monitoring";

    # selfMonitoring.enable is deliberately NOT set anywhere: it is on by
    # default because the metrics database is enabled. Only the interval is
    # shortened so the test doesn't wait 30s.
    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        logs = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        traces = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        vmauth.selfMonitoring.interval = "5s";
      };
    };

    testScript = ''
      start_all()
      for unit in ["victoriametrics", "victorialogs", "victoriatraces", "vmauth"]:
          machine.wait_for_unit(f"{unit}.service")
      machine.wait_for_open_port(4201)

      for job in ["victoriametrics", "victorialogs", "victoriatraces", "vmauth"]:
          machine.wait_until_succeeds(
              "curl -sfG 'http://127.0.0.1:4201/api/v1/query' "
              f"--data-urlencode 'query=count({{job=\"{job}\"}})' | grep -q '\"value\"'",
              timeout=120,
          )
    '';
  };

  # selfMonitoring is on by default, so an operator who already pushes
  # metrics with their own -pushmetrics.* flags would silently get both.
  self-monitoring-conflicting-extra-flags-warn-for-every-service =
    pkgs.runCommand "self-monitoring-conflict-warns" { }
      (
        let
          warningsFor =
            m:
            lib.filter (lib.hasInfix "selfMonitoring") (
              (evalWith {
                services.victoriaStack = m;
              }).config.warnings
            );
          flag = [ "-pushmetrics.url=http://example.invalid/push" ];
          warns =
            svc: extra:
            lib.any (lib.hasInfix "services.victoriaStack.${svc}") (
              warningsFor ({ metrics.enable = true; } // extra)
            );
          checks = {
            "metrics.extraFlags" = warns "metrics" {
              metrics = {
                enable = true;
                extraFlags = flag;
              };
            };
            "logs.extraFlags" = warns "logs" {
              logs = {
                enable = true;
                extraFlags = flag;
              };
            };
            "traces.extraFlags" = warns "traces" {
              traces = {
                enable = true;
                extraFlags = flag;
              };
            };
            "vmauth.extraFlags" = warns "vmauth" { vmauth.extraFlags = flag; };
            "the old extraOptions name still counts (it is renamed to extraFlags)" = warns "logs" {
              logs = {
                enable = true;
                extraOptions = flag;
              };
            };
            "no warning when the operator opted that service out" =
              warningsFor {
                metrics.enable = true;
                logs = {
                  enable = true;
                  extraFlags = flag;
                  selfMonitoring.enable = false;
                };
              } == [ ];
            "no warning for unrelated extra flags" =
              warningsFor {
                metrics = {
                  enable = true;
                  extraFlags = [ "-search.maxUniqueTimeseries=300000" ];
                };
              } == [ ];
            "no warning when the service itself is disabled" =
              warningsFor {
                metrics.enable = true;
                logs.extraFlags = flag; # logs.enable left false
              } == [ ];
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "selfMonitoring conflict warning broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );
}
