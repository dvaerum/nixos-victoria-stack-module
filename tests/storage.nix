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
}
