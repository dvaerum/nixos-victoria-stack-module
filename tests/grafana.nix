{ pkgs, nixosModule }:

let
  module = nixosModule.nixosModules.victoriaStack;

  # services.grafana.* itself is entirely the consumer's own
  # responsibility (docs/decisions/0010) -- this module only adds
  # datasource provisioning on top of whatever Grafana config already
  # exists. This stands in for "the consumer's own config": nixpkgs'
  # grafana module now requires a real secret_key file-provider (no
  # silent default -- confirmed via a real assertion hit while writing
  # this test, not assumed), so a throwaway one is provided here, same as
  # any real deployment would via its own secrets mechanism.
  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";

  grafanaConsumerConfig = {
    services.grafana = {
      enable = true;
      settings.security.secret_key = "$__file{${secretKeyFixture}}";
    };
  };
in
{
  datasources-provisioned-for-enabled-backends = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-datasources-provisioned";

    containers.machine = {
      imports = [
        module
        grafanaConsumerConfig
      ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("grafana.service")
      machine.wait_for_open_port(3000)

      # Default Grafana admin credentials (admin/admin) since this test
      # doesn't override security.admin_password -- fine for a throwaway
      # container, never done this way for a real deployment (this
      # module's own adminPasswordFile-style options are for vmauth, not
      # Grafana -- see docs/decisions/0010, Grafana keeps its own auth).
      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources
    '';
  };

  datasources-direct-loopback-not-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-datasources-direct-loopback";

    containers.machine = {
      imports = [
        module
        grafanaConsumerConfig
      ];
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        # vmauth ends up auto-enabled (any backend on) but Grafana's own
        # datasource URL must NOT route through it -- confirmed by
        # checking the provisioned datasource's own url field points at
        # the backend's loopback address directly, not vmauth's.
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("grafana.service")
      machine.wait_for_open_port(3000)

      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "127.0.0.1:4201" in datasources, (
          f"expected the metrics datasource URL to point directly at "
          f"victoriametrics' own loopback address, not vmauth: {datasources!r}"
      )
    '';
  };

  only-enabled-backends-get-datasources = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-only-enabled-backends";

    containers.machine = {
      imports = [
        module
        grafanaConsumerConfig
      ];
      services.victoriaStack = {
        metrics.enable = true;
        # logs/traces deliberately left disabled.
        grafana.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("grafana.service")
      machine.wait_for_open_port(3000)

      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" not in datasources
      assert "jaeger" not in datasources
    '';
  };
}
