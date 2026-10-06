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

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraOptions, and a listenAddress override all reaching ExecStart /
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
            extraOptions = [ "-search.maxUniqueTimeseries=300000" ];
            listenAddress = "127.0.0.1:19999";
          };
        };
        execStart = evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStart;
        effectiveUrl = evaluated.config.services.victoriaStack.${serviceAttr}.effectiveUrl;
        checks = {
          "retentionPeriod flag present" = lib.hasInfix "-retentionPeriod=30d" execStart;
          "extraOptions flag present" = lib.hasInfix "-search.maxUniqueTimeseries=300000" execStart;
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

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraOptions, and a listenAddress override all reaching ExecStart /
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

  metrics-manage-tmpfiles-default-true-rule-present =
    pkgs.runCommand "metrics-manage-tmpfiles-default-true-rule-present" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              dataDir = "/data/victoria/metrics";
              dynamicUser = false;
            };
          };
          rules = evaluated.config.systemd.tmpfiles.rules;
        in
        if lib.any (lib.hasInfix "/data/victoria/metrics") rules then
          "echo OK > $out"
        else
          throw "manageTmpfiles defaults to true -- expected a tmpfiles rule for the custom dataDir"
      );

  metrics-manage-tmpfiles-false-rule-absent =
    pkgs.runCommand "metrics-manage-tmpfiles-false-rule-absent" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              dataDir = "/data/victoria/metrics";
              dynamicUser = false;
              manageTmpfiles = false;
            };
          };
          rules = evaluated.config.systemd.tmpfiles.rules;
        in
        if !(lib.any (lib.hasInfix "/data/victoria/metrics") rules) then
          "echo OK > $out"
        else
          throw "manageTmpfiles = false must suppress the every-boot tmpfiles ownership rule entirely"
      );

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
            upstream default (7 days), not "effectively unbounded" --
            that claim is only true for metrics/logs. Actual description:
            ${description}
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
}
