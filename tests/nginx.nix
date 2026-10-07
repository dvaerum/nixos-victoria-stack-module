{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) otlpMetricGenerator evalWith;
  otlpMetric = "${otlpMetricGenerator}/bin/gen-otlp-metric";

  # Throwaway self-signed cert, mirroring victoriaCollector/config.nix's
  # own dummyClientCert pattern -- generated at build time, not a secret.
  # Unlike that pattern (a client cert vmauth never validates), this is
  # a SERVER cert curl's own --cacert verification checks hostname
  # against -- needs a real SAN for 127.0.0.1, not just a CN, confirmed
  # directly: without it curl fails closed with exit 60 (cert verify
  # failed) even though the cert chain itself is otherwise valid.
  selfSignedCert =
    pkgs.runCommand "victoria-stack-nginx-test-self-signed-cert"
      { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
          -subj "/CN=victoria-stack-nginx-test" \
          -addext "subjectAltName=IP:127.0.0.1" \
          -keyout $out/key.pem -out $out/cert.pem
      '';

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

  # The check above reads the default (1m) back out of the same eval, so a
  # hardcoded "1m" in nginx.nix would pass it. A non-default value proves
  # the timeouts genuinely track vmauth.idleConnTimeout (ADR 0016).
  nginx-victoria-location-tracks-a-non-default-idle-conn-timeout =
    pkgs.runCommand "nginx-victoria-location-tracks-non-default-timeout" { }
      (
        let
          custom = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              nginx.enable = true;
              vmauth.idleConnTimeout = "45s";
            };
          };
          extraConfig =
            custom.config.services.nginx.virtualHosts."victoria-stack".locations."/victoria/".extraConfig;
          checks = lib.genAttrs [ "connect" "send" "read" ] (
            kind: lib.hasInfix "proxy_${kind}_timeout 45s;" extraConfig
          );
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "nginx timeouts did not follow vmauth.idleConnTimeout = 45s for: ${builtins.toJSON (builtins.attrNames failed)}\n${extraConfig}"
      );

  # Without these, vmauth (and anything logging behind nginx) only ever
  # sees nginx's own loopback address as the client.
  nginx-forwards-the-real-client-ip-on-every-proxied-location =
    pkgs.runCommand "nginx-forwards-real-client-ip" { }
      (
        let
          locs = [
            "/victoria/"
            "/grafana/"
            "/grafana/api/live/"
          ];
          has = loc: header: lib.hasInfix header (vhost.locations.${loc}.extraConfig or "");
          checks = lib.listToAttrs (
            lib.concatMap (loc: [
              (lib.nameValuePair "${loc} X-Real-IP" (has loc "proxy_set_header X-Real-IP $remote_addr;"))
              (lib.nameValuePair "${loc} X-Forwarded-For" (
                has loc "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
              ))
            ]) locs
          );
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "missing client-IP forwarding headers: ${builtins.toJSON (builtins.attrNames failed)}"
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
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      # grafana.service being "active" doesn't mean Grafana's own HTTP
      # server is listening yet -- confirmed directly: without this,
      # the /grafana/ curl below raced Grafana's startup and got a 502
      # from nginx often enough to fail the check.
      machine.wait_for_open_port(3000)
      # Same race for vmauth's own backend -- caught by the sibling test
      # with grafana disabled (nothing else gave it enough of a head
      # start), but latent here too without this.
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      # /grafana/ reaches Grafana through nginx. wait_until_succeeds, not
      # succeed: Grafana's HTTP port opens before its own startup
      # migrations finish, so a one-shot request can still race it.
      machine.wait_until_succeeds("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")

      # /victoria/ reaches vmauth through nginx, which in turn reaches the
      # metrics backend -- confirmed via the open (auth-disabled) write
      # path, the simplest reachability check that doesn't need a
      # credential. Real OTLP protobuf, not plaintext: VictoriaMetrics'
      # actual /opentelemetry/v1/metrics handler rejects both a bare
      # "/opentelemetry" path and non-protobuf bodies (confirmed directly
      # against a real instance -- see otlpMetricGenerator's own comment
      # in tests/lib.nix).
      machine.succeed(
          "${otlpMetric} victoria_stack_nginx_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' "
          "--data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
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

      # "-T" with no "-c" silently dumps the nginx *binary's own
      # compiled-in default config* (its stock example server block,
      # server_name "localhost"), not the actual NixOS-rendered config
      # the running service uses -- confirmed directly: without "-c",
      # this assertion failed even though the domain genuinely was
      # applied. NixOS's nginx module exposes the real config at
      # /etc/nginx/nginx.conf (nixos/modules/services/web-servers/nginx).
      config_dump = machine.succeed("${pkgs.nginx}/bin/nginx -T -c /etc/nginx/nginx.conf 2>&1")
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
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      # grafana.service being "active" doesn't mean Grafana's own HTTP
      # server is listening yet -- see nginx-proxies-victoria-and-grafana-
      # subpaths' own comment above (the same race, found here too).
      machine.wait_for_open_port(3000)
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      config_dump = machine.succeed("${pkgs.nginx}/bin/nginx -T -c /etc/nginx/nginx.conf 2>&1")
      assert "victoria-stack-test.example.com" in config_dump, (
          "expected the configured domain to appear in nginx's own rendered config"
      )

      # Both locations must still coexist -- the exact combination that
      # triggered the `//`-clobbering bug (a custom option alongside
      # grafana.enable = true). Setting `domain` makes the virtualHost
      # name-based (nginx.nix only sets serverName when cfg.domain !=
      # null) -- a request's Host header must match for nginx to route
      # to it at all, confirmed directly: omitting -H "Host: ..." here
      # failed with no error, just curl/grep finding nothing.
      # wait_until_succeeds, not succeed: Grafana's HTTP port opens
      # before its own startup migrations finish.
      machine.wait_until_succeeds(
          "curl -sf -H 'Host: victoria-stack-test.example.com' "
          "'http://127.0.0.1:80/grafana/login' | grep -qi grafana"
      )
      machine.succeed(
          "${otlpMetric} victoria_stack_nginx_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Host: victoria-stack-test.example.com' "
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
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
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      # vmauth.service being "active" doesn't mean it's actually
      # listening yet -- unlike the 3 storage services, vmauth has no
      # postStart readiness probe of its own (nixosModule/victoriaStack/
      # vmauth.nix), so systemd marks it active the instant the process
      # forks, not once it's bound its HTTP port. Confirmed directly:
      # without wait_for_open_port(4204), nginx's proxy_pass raced it
      # and got "502 Bad Gateway" (connection refused upstream) often
      # enough to fail this check -- the one test in this file with no
      # Grafana migration delay to incidentally cover for it.
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      # /victoria/ must still work on its own (no grafana.nix location
      # merged in to clobber or interfere with it).
      machine.succeed(
          "${otlpMetric} victoria_stack_nginx_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' "
          "--data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
      )

      # /grafana/ must not exist at all when grafana.enable = false --
      # nginx should 404, not proxy to a Grafana that was never started.
      status = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:80/grafana/login'"
      )
      assert status == "404", f"expected 404 for /grafana/ when grafana.enable = false, got {status!r}"
    '';
  };

  # The 4th and last domain x grafana.enable combination (see the comment
  # on nginx-custom-domain-with-grafana-enabled above): a custom domain
  # with grafana.enable left off, confirmed via a real live request (not
  # just a config-dump assertion like nginx-domain-sets-server-name) --
  # setting `domain` makes the virtualHost name-based, so a request must
  # carry the matching Host header to route at all, same as the
  # grafana-enabled combination above.
  nginx-custom-domain-with-grafana-disabled = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-custom-domain-grafana-disabled";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
        # grafana.enable left at its default (false).
        vmauth.requireAuthForWrites = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      machine.succeed(
          "${otlpMetric} victoria_stack_nginx_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Host: victoria-stack-test.example.com' "
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
      )

      # The default (no Host header / wrong Host) must NOT reach this
      # virtualHost -- it's name-based now, not the catch-all default.
      machine.fail(
          "curl -sf -X POST --data-binary 'x 1' "
          "'http://127.0.0.1:80/victoria/opentelemetry'"
      )

      # /grafana/ must not exist at all here either.
      status = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "-H 'Host: victoria-stack-test.example.com' "
          "'http://127.0.0.1:80/grafana/login'"
      )
      assert status == "404", f"expected 404 for /grafana/ when grafana.enable = false, got {status!r}"
    '';
  };

  # docs/decisions/0022: "victoria-stack" is now a stable, documented
  # extension point, not an incidental implementation detail -- pins the
  # literal attribute name so a future accidental rename is caught
  # immediately, the same protection every other stable-name contract in
  # this project already gets (e.g. the systemd unit names documented in
  # README.md's escape-hatches section).
  virtual-host-name-is-the-stable-victoria-stack-key =
    pkgs.runCommand "nginx-virtual-host-name-is-stable" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              nginx.enable = true;
            };
          };
          hasStableName = evaluated.config.services.nginx.virtualHosts ? "victoria-stack";
        in
        if hasStableName then
          "echo OK > $out"
        else
          throw ''
            Expected services.nginx.virtualHosts."victoria-stack" to exist --
            docs/decisions/0022 documents this exact name as a stable,
            public extension point for operator-added TLS config.
          ''
      );

  # The one real container-boot test for ADR 0022's whole point: an
  # operator adding real nginx TLS config directly onto the stable
  # virtualHost name, exactly as the README/ADR's own worked example
  # shows -- confirming the composition genuinely works end to end, both
  # protocols against the same backend, not just that it evaluates.
  http-and-https-coexist-on-the-stable-name = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-http-and-https-coexist";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx.enable = true;
        vmauth.requireAuthForWrites = false;
      };
      # Operator-added TLS config, directly on the stable virtualHost
      # name -- not anything this module itself configures.
      services.nginx.virtualHosts."victoria-stack" = {
        addSSL = true; # keep plain HTTP working too, not forceSSL
        sslCertificate = "${selfSignedCert}/cert.pem";
        sslCertificateKey = "${selfSignedCert}/key.pem";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      machine.wait_for_open_port(443)
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)

      machine.succeed(
          "${otlpMetric} victoria_stack_nginx_tls_test_metric 1 > /tmp/otlp.bin"
      )

      # Plain HTTP still works, unaffected by the added TLS config.
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' "
          "--data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
      )

      # HTTPS reaches the exact same backend through the same
      # virtualHost/location configuration this module defines.
      machine.succeed(
          "curl -sf --cacert ${selfSignedCert}/cert.pem -X POST "
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'https://127.0.0.1:443/victoria/opentelemetry/v1/metrics'"
      )
    '';
  };

  # Phase 43 fresh-agent review finding: nginx had no systemd ordering
  # on vmauth.service or grafana.service at all -- confirmed directly
  # via `systemctl show nginx.service -p After` on a real running
  # container, neither unit appeared anywhere in it, only generic boot
  # targets. tests/nginx.nix's own existing comments already document
  # hitting the resulting race live ("nginx's proxy_pass raced it and
  # got 502 Bad Gateway"), previously worked around only in test
  # scripts (wait_for_open_port), never fixed at the unit level.
  nginx-after-includes-vmauth-and-grafana-when-enabled =
    pkgs.runCommand "nginx-after-includes-vmauth-and-grafana" { }
      (
        let
          withoutGrafana = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              nginx.enable = true;
            };
          };
          withGrafana = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              nginx.enable = true;
              grafana.enable = true;
            };
            services.grafana.enable = true;
          };
          afterWithout = withoutGrafana.config.systemd.services.nginx.after;
          afterWith = withGrafana.config.systemd.services.nginx.after;
          checks = {
            "vmauth in after (grafana off)" = lib.elem "vmauth.service" afterWithout;
            "grafana NOT forced into after when disabled" = !(lib.elem "grafana.service" afterWithout);
            "vmauth in after (grafana on)" = lib.elem "vmauth.service" afterWith;
            "grafana in after (grafana on)" = lib.elem "grafana.service" afterWith;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "nginx.service's after is missing expected ordering: ${builtins.toJSON (builtins.attrNames failed)}"
      );
}
