{ pkgs, nixosModule }:

let
  module = nixosModule.nixosModules.victoriaStack;

  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";
in
{
  nginx-proxies-victoria-and-grafana-subpaths = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-subpath-routing";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        nginx.enable = true;
        vmauth.requireAuthForWrites = false;
      };
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("grafana.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(80)

      # /grafana/ reaches Grafana through nginx.
      machine.succeed("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")

      # /victoria/ reaches vmauth through nginx, which in turn reaches the
      # metrics backend -- confirmed via the open (auth-disabled) write
      # path, the simplest reachability check that doesn't need a
      # credential.
      machine.succeed(
          "curl -sf -X POST --data-binary 'victoria_stack_nginx_test_metric 1' "
          "'http://127.0.0.1:80/victoria/opentelemetry'"
      )
    '';
  };

  nginx-domain-sets-server-name = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-domain-option";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("nginx.service")
      machine.wait_for_open_port(80)

      config_dump = machine.succeed("nginx -T 2>&1")
      assert "victoria-stack-test.example.com" in config_dump, (
          "expected the configured domain to appear in nginx's own rendered config"
      )
    '';
  };
}
