{ pkgs, nixosModule }:

let
  module = nixosModule.nixosModules.default;
  example = import ../examples { };

  # Same throwaway-fixture pattern as every other test group -- these
  # override the example's placeholder /run/secrets/... paths, nothing
  # else about the example's own shape changes.
  adminPasswordFixture = pkgs.writeText "full-admin-password" "full-test-admin-password";
  readTokensFixture = pkgs.writeText "full-read-tokens.yaml" ''
    tokens:
      - full-test-read-token
  '';
  writeTokensFixture = pkgs.writeText "full-write-tokens.yaml" ''
    tokens:
      - full-test-write-token
  '';
  grafanaSecretKeyFixture = pkgs.writeText "full-grafana-secret-key" "full-test-grafana-secret-key";
  grafanaAdminPasswordFixture = pkgs.writeText "full-grafana-admin-password" "full-test-grafana-admin-password";
  collectorWriteTokenFixture = pkgs.writeText "full-collector-write-token" "full-test-write-token";
in
{
  full-stack-enable-and-go = pkgs.testers.nixosTest {
    name = "victoria-stack-full";

    containers.machine =
      { lib, ... }:
      {
        imports = [
          module
          example
        ];

        services.victoriaStack.vmauth = {
          adminPasswordFile = lib.mkForce "${adminPasswordFixture}";
          readTokensFile = lib.mkForce "${readTokensFixture}";
          writeTokensFile = lib.mkForce "${writeTokensFixture}";
        };
        services.grafana.settings.security = {
          secret_key = lib.mkForce "$__file{${grafanaSecretKeyFixture}}";
          admin_password = lib.mkForce "$__file{${grafanaAdminPasswordFixture}}";
        };
        services.victoriaCollector.writeTokenFile = lib.mkForce "${collectorWriteTokenFixture}";
      };

    testScript = ''
      start_all()

      # Every real unit this configuration stands up.
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_unit("grafana.service")
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("mcp-victoriametrics.service")
      machine.wait_for_unit("mcp-victorialogs.service")
      machine.wait_for_unit("mcp-victoriatraces.service")
      machine.wait_for_unit("alloy.service")
      machine.wait_for_unit("systemd-journal-upload.service")

      machine.wait_for_open_port(80)
      machine.wait_for_open_port(3000)
      machine.wait_for_open_port(4204)

      # End-to-end: write through vmauth with the write-tier token,
      # query back through vmauth with the read-tier token.
      machine.succeed(
          "curl -sf -X POST -H 'Authorization: Bearer full-test-write-token' "
          "--data-binary 'victoria_stack_full_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=victoria_stack_full_test_metric' "
          "| grep -q '\"value\"'"
      )

      # Grafana reachable through nginx, datasources provisioned.
      machine.succeed("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")
      datasources = machine.succeed(
          "curl -sf -u admin:full-test-grafana-admin-password 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources
    '';
  };
}
