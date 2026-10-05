{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkWarningFiresCheck mkNoWarningsCheck;

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
      machine.wait_for_open_port(8428)

      # Prometheus exposition-format ingest -- the simplest real write path
      # VictoriaMetrics' own HTTP API supports natively, no extra tooling
      # needed beyond curl.
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_test_metric{label=\"roundtrip\"} 42' "
          "'http://127.0.0.1:8428/api/v1/import/prometheus'"
      )

      # VictoriaMetrics ingestion is not synchronous-to-query -- give it a
      # moment before asserting the value is queryable.
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:8428/api/v1/query?query=victoria_stack_test_metric' "
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
      machine.wait_for_open_port(8428)

      # Confirm it's genuinely running as the static user, not DynamicUser,
      # and that the custom dataDir is real and owned correctly -- the
      # whole point of this option combination (docs/decisions/0001).
      user = machine.succeed(
          "systemctl show victoriametrics.service --property=User --value"
      ).strip()
      assert user == "victoriametrics", f"expected static User=victoriametrics, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/metrics").strip()
      assert owner == "victoriametrics", f"expected /data/victoria/metrics owned by victoriametrics, got {owner!r}"
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

  logs-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(9428)

      # JSON stream (ndjson) ingest -- VictoriaLogs' own HTTP API
      # (/insert/jsonline), confirmed from its real data-ingestion docs
      # rather than assumed to mirror VictoriaMetrics' API shape.
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_test_log_roundtrip\"}" 
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:9428/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:9428/select/logsql/query' -d 'query=victoria_stack_test_log_roundtrip' "
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
      machine.wait_for_open_port(9428)

      user = machine.succeed(
          "systemctl show victorialogs.service --property=User --value"
      ).strip()
      assert user == "victorialogs", f"expected static User=victorialogs, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/logs").strip()
      assert owner == "victorialogs", f"expected /data/victoria/logs owned by victorialogs, got {owner!r}"
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

  traces-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(10428)

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
          "'http://127.0.0.1:10428/insert/opentelemetry/v1/traces'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:10428/select/jaeger/api/services' "
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
      machine.wait_for_open_port(10428)

      user = machine.succeed(
          "systemctl show victoriatraces.service --property=User --value"
      ).strip()
      assert user == "victoriatraces", f"expected static User=victoriatraces, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/traces").strip()
      assert owner == "victoriatraces", f"expected /data/victoria/traces owned by victoriatraces, got {owner!r}"
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
