{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";

  # Pure eval, no container boot needed -- confirms the rendered nginx
  # config shape directly (docs/decisions/0016's "mirror what it fronts"
  # house rule), rather than only exercising it via curl in a container
  # (the container-boot tests below still confirm it actually works end
  # to end; this is the structural half).
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit (pkgs) system;
    modules = [
      module
      {
        system.stateVersion = lib.trivial.release;
        services.victoriaStack = {
          metrics.enable = true;
          grafana.enable = true;
          nginx.enable = true;
        };
        services.grafana = {
          enable = true;
          settings.security.secret_key = "$__file{${secretKeyFixture}}";
        };
      }
    ];
  };
  vhost = evaluated.config.services.nginx.virtualHosts."victoria-stack";
in
{
  # A real, previously-undetected regression found while implementing
  # the Grafana official-config rewrite: the vhost's `locations` attrset
  # was built via plain `//` across two separately-constructed attrsets
  # that BOTH had a top-level `locations` key -- `//` doesn't deep-merge,
  # so whichever side came last silently clobbered the other's
  # `locations` ENTIRELY. In practice: /victoria/ vanished from the
  # rendered config whenever grafana.enable was also true (the exact
  # combination examples/default.nix itself documents), undetected
  # because the only test exercising both together is container-boot
  # (blocked locally, docs/decisions/0011).
  nginx-victoria-and-grafana-locations-coexist =
    pkgs.runCommand "nginx-victoria-and-grafana-locations-coexist" { }
      (
        let
          locationNames = builtins.attrNames vhost.locations;
          expected = [
            "/victoria/"
            "/grafana/"
            "/grafana/api/live/"
          ];
          missing = builtins.filter (name: !(builtins.elem name locationNames)) expected;
        in
        if missing == [ ] then
          "echo OK > $out"
        else
          throw "expected all of ${builtins.toJSON expected} to coexist, missing: ${builtins.toJSON missing}. Actual locations: ${builtins.toJSON locationNames}"
      );

  nginx-victoria-location-mirrors-vmauth-timeouts-and-body-size =
    pkgs.runCommand "nginx-victoria-location-mirrors-vmauth" { }
      (
        let
          extraConfig = vhost.locations."/victoria/".extraConfig or "";
          idleConnTimeout = evaluated.config.services.victoriaStack.vmauth.idleConnTimeout;
          checks = {
            "proxy_connect_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_connect_timeout ${idleConnTimeout}" extraConfig;
            "proxy_send_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_send_timeout ${idleConnTimeout}" extraConfig;
            "proxy_read_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_read_timeout ${idleConnTimeout}" extraConfig;
            "client_max_body_size is unbounded" = lib.hasInfix "client_max_body_size 0;" extraConfig;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "nginx's /victoria/ location is missing: ${builtins.toJSON (builtins.attrNames failed)}\nextraConfig was: ${extraConfig}"
      );

  nginx-grafana-live-websocket-location-exists =
    pkgs.runCommand "nginx-grafana-live-websocket-location-exists" { }
      (
        let
          liveLocation = vhost.locations."/grafana/api/live/" or null;
          extraConfig = if liveLocation == null then "" else liveLocation.extraConfig or "";
          checks = {
            "location exists at all" = liveLocation != null;
            "proxy_http_version 1.1" = lib.hasInfix "proxy_http_version 1.1" extraConfig;
            "Upgrade header" = lib.hasInfix "proxy_set_header Upgrade" extraConfig;
            "Connection header" = lib.hasInfix "proxy_set_header Connection" extraConfig;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw ''
            Grafana's own official sub-path reverse-proxy docs
            (grafana.com/tutorials/run-grafana-behind-a-proxy/) require a
            dedicated /grafana/api/live/ location for Grafana Live
            (WebSocket) to work at all -- missing: ${builtins.toJSON (builtins.attrNames failed)}
          ''
      );

  nginx-websocket-upgrade-map-directive-present =
    pkgs.runCommand "nginx-websocket-upgrade-map-directive-present" { }
      (
        let
          httpConfig = evaluated.config.services.nginx.appendHttpConfig or "";
        in
        if lib.hasInfix "map $http_upgrade $connection_upgrade" httpConfig then
          "echo OK > $out"
        else
          throw ''
            Grafana's official docs require a map $http_upgrade
            $connection_upgrade {} block at the http{} level for the
            Grafana Live websocket location to resolve $connection_upgrade
            at all -- missing from services.nginx.appendHttpConfig.
          ''
      );

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

  # Previously only 2 of the 4 domain x grafana.enable combinations were
  # covered (default-domain+grafana-off implicitly via other tests, and
  # default-domain+grafana-on via nginx-proxies-victoria-and-grafana-subpaths
  # above). The critical `//`-clobbering bug found during the grill-me
  # review (docs/decisions/0016) specifically manifested only when BOTH
  # a custom option AND grafana.enable were set together -- so the
  # remaining 2 combinations are not redundant with the ones above.
  nginx-custom-domain-with-grafana-enabled = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-custom-domain-with-grafana";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
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

      config_dump = machine.succeed("nginx -T 2>&1")
      assert "victoria-stack-test.example.com" in config_dump, (
          "expected the configured domain to appear in nginx's own rendered config"
      )

      # Both locations must still coexist -- the exact combination that
      # triggered the `//`-clobbering bug (a custom option alongside
      # grafana.enable = true).
      machine.succeed("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")
      machine.succeed(
          "curl -sf -X POST --data-binary 'victoria_stack_nginx_test_metric 1' "
          "'http://127.0.0.1:80/victoria/opentelemetry'"
      )
    '';
  };

  nginx-grafana-disabled-has-no-grafana-location = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-grafana-disabled-no-location";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx.enable = true;
        # grafana.enable left at its default (false).
        vmauth.requireAuthForWrites = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(80)

      # /victoria/ must still work on its own (no grafana.nix location
      # merged in to clobber or interfere with it).
      machine.succeed(
          "curl -sf -X POST --data-binary 'victoria_stack_nginx_test_metric 1' "
          "'http://127.0.0.1:80/victoria/opentelemetry'"
      )

      # /grafana/ must not exist at all when grafana.enable = false --
      # nginx should 404, not proxy to a Grafana that was never started.
      status = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/grafana/login'"
      )
      assert status == "404", f"expected 404 for /grafana/ when grafana.enable = false, got {status!r}"
    '';
  };
}
