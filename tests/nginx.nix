{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    otlpMetricGenerator
    evalWith
    grafanaReadTokenFile
    vmauthReadTokensWithGrafana
    ;
  otlpMetric = "${otlpMetricGenerator}/bin/gen-otlp-metric";

  # Throwaway self-signed server cert, generated at build time (not a
  # secret). Needs a SAN for 127.0.0.1, not just a CN: without it curl
  # --cacert fails with exit 60 (cert verify failed).
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
  adminPasswordFixture = pkgs.writeText "nginx-test-admin-password" "nginx-admin-password";
  writeTokensFixture = pkgs.writeText "nginx-test-write-tokens.yaml" ''
    tokens:
      - token: nginx-write-token
  '';

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

  # /victoria/ is reads-only: the proxying lives on one regex location
  # allow-listing the read prefixes; the plain "/victoria/" location is the
  # 404 catch-all for everything else (docs/decisions/0025).
  readLocationOf =
    e:
    let
      locs = e.config.services.nginx.virtualHosts."victoria-stack".locations;
    in
    locs.${lib.findFirst (lib.hasPrefix "~ ^/victoria/") "MISSING" (builtins.attrNames locs)};
  victoriaReadLocation = readLocationOf evaluated;
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
          extraConfig = victoriaReadLocation.extraConfig or "";
          idleConnTimeout = evaluated.config.services.victoriaStack.vmauth.idleConnTimeout;
          checks = {
            "proxy_connect_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_connect_timeout ${idleConnTimeout}" extraConfig;
            "proxy_send_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_send_timeout ${idleConnTimeout}" extraConfig;
            "proxy_read_timeout mirrors vmauth.idleConnTimeout" =
              lib.hasInfix "proxy_read_timeout ${idleConnTimeout}" extraConfig;
            "client_max_body_size is the 8m default" = lib.hasInfix "client_max_body_size 8m;" extraConfig;
            "request buffering is off (vmauth checks the token first)" =
              lib.hasInfix "proxy_request_buffering off;" extraConfig;
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
          extraConfig = (readLocationOf custom).extraConfig;
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
          readLocationName = lib.findFirst (lib.hasPrefix "~ ^/victoria/") "MISSING" (
            builtins.attrNames vhost.locations
          );
          locs = [
            readLocationName
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
            # The variable from the http-level map, not a fixed "upgrade": a fixed
            # value would put every request on this location into upgrade mode.
            "Connection header" = lib.hasInfix "proxy_set_header Connection $connection_upgrade;" extraConfig;
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
          # Whole block: "default upgrade" with an empty-Upgrade request mapped
          # to "close" is what keeps ordinary requests off a websocket connection.
          body = map lib.trim (lib.filter (l: lib.trim l != "") (lib.splitString "\n" httpConfig));
        in
        if
          body == [
            "map $http_upgrade $connection_upgrade {"
            "default upgrade;"
            "'' close;"
            "}"
          ]
        then
          "echo OK > $out"
        else
          throw ''
            Grafana's official docs require a map $http_upgrade
            $connection_upgrade {} block at the http{} level for the
            Grafana Live websocket location to resolve $connection_upgrade
            at all -- missing from services.nginx.appendHttpConfig.
          ''
      );

  # nginx must be ordered after, and pull in, the upstreams it proxies to
  # (otherwise it can start first and answer 502). Grafana only when enabled.
  nginx-wants-and-follows-its-upstreams =
    pkgs.runCommand "nginx-wants-and-follows-its-upstreams" { }
      (
        let
          unitsOf =
            grafana:
            (evalWith {
              services.victoriaStack = {
                metrics.enable = true;
                nginx.enable = true;
                grafana.enable = grafana;
              };
              services.grafana = lib.mkIf grafana {
                enable = true;
                settings.security.secret_key = "$__file{${secretKeyFixture}}";
              };
            }).config.systemd.services.nginx;
          withGrafana = unitsOf true;
          without = unitsOf false;
          checks = {
            # elem, not equality: nixpkgs' own nginx module adds its network targets.
            "grafana: wants vmauth and grafana" = lib.all (u: lib.elem u withGrafana.wants) [
              "vmauth.service"
              "grafana.service"
            ];
            "grafana: after vmauth and grafana" = lib.all (u: lib.elem u withGrafana.after) [
              "vmauth.service"
              "grafana.service"
            ];
            "no grafana: vmauth only, no grafana unit pulled in" =
              lib.elem "vmauth.service" without.wants
              && lib.elem "vmauth.service" without.after
              && !(lib.elem "grafana.service" without.wants)
              && !(lib.elem "grafana.service" without.after);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "nginx unit ordering wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  nginx-proxies-victoria-and-grafana-subpaths = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-subpath-routing";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "${grafanaReadTokenFile}";
        };
        nginx.enable = true;
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
        vmauth.readTokensFile = "${vmauthReadTokensWithGrafana}";
      };
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "grafana.service")
      wait_active(machine, "vmauth.service")
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
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      # /grafana/ reaches Grafana through nginx. wait_until_succeeds, not
      # succeed: Grafana's HTTP port opens before its own startup
      # migrations finish, so a one-shot request can still race it.
      machine.wait_until_succeeds("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")

      # Grafana must know it lives under /grafana/: nginx strips the prefix, so
      # without root_url its redirects (Location: /login) and its <base href="/">
      # point outside /grafana/, which nginx does not proxy -- the page loads but
      # the browser then asks for /login and /public/... and gets nothing.
      headers = machine.succeed("curl -sI 'http://127.0.0.1:80/grafana/'")
      assert "/grafana/login" in headers, headers
      login = machine.succeed("curl -s 'http://127.0.0.1:80/grafana/login'")
      assert '<base href="/grafana/"' in login, login[:500]
      import re
      # A script asset, however the page spells the path (relative to the
      # <base href>, or already absolute under /grafana/).
      asset = re.search(r'(?:src|href)="((?:/grafana/)?public/[^"]+\.js)"', login)
      scripts = re.findall(r"<script[^>]*>", login)
      assert asset, f"no public/*.js asset in the login page; script tags: {scripts[:5]}"
      path = asset.group(1)
      path = path if path.startswith("/") else "/grafana/" + path
      machine.succeed(f"curl -sf -o /dev/null 'http://127.0.0.1:80{path}'")

      # /victoria/ reaches vmauth through nginx, which in turn reaches the
      # metrics backend -- a credentialed read, since /victoria/ is
      # reads-only (docs/decisions/0025; writes go to vmauth's own doors).
      machine.succeed(
          "curl -sf -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
      )

      # Grafana Live: a real WebSocket handshake through /grafana/api/live/.
      # 101 needs the Upgrade header forwarded AND `Connection: upgrade`, which
      # the http-level map only yields when its default is "upgrade".
      # (curl waits for frames after the 101, so --max-time ends it and the
      # headers it already received are read from the dump file.)
      machine.execute(
          "curl -s -o /dev/null -D /tmp/ws.headers --max-time 3 -u admin:admin "  # gitleaks:allow
          "-H 'Connection: Upgrade' -H 'Upgrade: websocket' "
          "-H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "  # RFC 6455's sample key, gitleaks:allow
          "'http://127.0.0.1:80/grafana/api/live/ws'"
      )
      handshake = machine.succeed("cat /tmp/ws.headers")
      assert handshake.startswith("HTTP/1.1 101"), f"expected a 101 websocket upgrade through nginx, got {handshake!r}"
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
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
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
        grafana = {
          enable = true;
          readTokenFile = "${grafanaReadTokenFile}";
        };
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
        vmauth.readTokensFile = "${vmauthReadTokensWithGrafana}";
      };
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "grafana.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      # grafana.service being "active" doesn't mean Grafana's own HTTP
      # server is listening yet -- see nginx-proxies-victoria-and-grafana-
      # subpaths' own comment above (the same race, found here too).
      machine.wait_for_open_port(3000)
      wait_active(machine, "victoriametrics.service")
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
          "curl -sf -H 'Host: victoria-stack-test.example.com' -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
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
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      # Before nginx was ordered after vmauth (whose postStart now waits for
      # its port), proxy_pass raced it and got "502 Bad Gateway" often enough
      # to fail this check; the explicit port waits are kept as a guard.
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      # /victoria/ must still work on its own (no grafana.nix location
      # merged in to clobber or interfere with it).
      machine.succeed(
          "curl -sf -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
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
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      machine.succeed(
          "curl -sf -H 'Host: victoria-stack-test.example.com' -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
      )

      # NOT asserted: that a request with a different Host is refused. It
      # isn't -- with a single virtualHost nginx serves unmatched Hosts from
      # it as the default server, so `domain` sets server_name (checked by
      # nginx-domain-sets-server-name) but is no access control. An earlier
      # version of this test claimed otherwise and only passed because its
      # probe carried no credentials and got a 401 anyway.

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
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
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
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)
      machine.wait_for_open_port(443)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)


      # Plain HTTP still works, unaffected by the added TLS config.
      machine.succeed(
          "curl -sf -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
      )

      # HTTPS reaches the exact same backend through the same
      # virtualHost/location configuration this module defines.
      machine.succeed(
          "curl -sf --cacert ${selfSignedCert}/cert.pem -u admin:nginx-admin-password "  # gitleaks:allow
          "'https://127.0.0.1:443/victoria/metrics/api/v1/labels'"
      )
    '';
  };

  # nginx needs systemd ordering on vmauth.service and grafana.service:
  # `systemctl show nginx.service -p After` on a real container listed
  # neither, and the resulting race gave "502 Bad Gateway" from
  # nginx's proxy_pass.
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

  # vmauth.listenAddress moved off its default: nginx must follow it
  # (nginx reads vmauth.listenAddress rather than hardcoding the port).
  nginx-follows-a-non-default-vmauth-listen-address = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-follows-vmauth-listen-address";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          listenAddress = "127.0.0.1:19999";
          adminPasswordFile = "${adminPasswordFixture}";
        };
        nginx.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(19999)
      machine.wait_for_open_port(80)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      rc, _ = machine.execute("curl -s --max-time 3 'http://127.0.0.1:4204/'")
      assert rc == 7, f"vmauth must no longer listen on 4204 (curl 7, connection refused), got {rc}"
      machine.succeed(
          "curl -sf -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
      )
    '';
  };

  # A credentialed vmauth tier behind the name-based virtualHost: nginx
  # must pass the Authorization header through untouched.
  nginx-custom-domain-passes-credentials-through = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-custom-domain-credentials";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(80)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      url = "http://127.0.0.1:80/victoria/metrics/api/v1/labels"
      host = "-H 'Host: victoria-stack-test.example.com'"
      machine.succeed(f"curl -sf {host} -u admin:nginx-admin-password '{url}'")  # gitleaks:allow
      anon = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {host} '{url}'")
      assert anon == "401", f"expected 401 without credentials via the named vhost, got {anon}"
      wrong = machine.succeed(
          f"curl -s -o /dev/null -w '%{{http_code}}' {host} -u admin:wrong-password '{url}'"  # gitleaks:allow
      )
      assert wrong == "401", f"expected 401 with a wrong password via the named vhost, got {wrong}"
    '';
  };

  # --- /victoria/ is reads-only ---

  nginx-victoria-allows-only-read-prefixes-and-404s-the-rest =
    pkgs.runCommand "nginx-victoria-reads-only" { }
      (
        let
          read = victoriaReadLocation;
          catchAll = vhost.locations."/victoria/";
          custom = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              nginx = {
                enable = true;
                extraReadPaths = [ "custom-route" ];
              };
            };
          };
          customRegexName = lib.findFirst (lib.hasPrefix "~ ^/victoria/") "" (
            builtins.attrNames custom.config.services.nginx.virtualHosts."victoria-stack".locations
          );
          checks = {
            "read location proxies to vmauth" =
              lib.hasInfix "proxy_pass" (read.extraConfig or "") || (read ? proxyPass);
            "read location strips the /victoria prefix" = lib.hasInfix "rewrite ^/victoria/(.*) /$1 break;" (
              read.extraConfig or ""
            );
            "catch-all /victoria/ answers 404 and never proxies" =
              (catchAll.return or null) == "404" && (catchAll.proxyPass or null) == null;
            "extraReadPaths widens the allow-list" = lib.hasInfix "custom-route" customRegexName;
          };
          names = lib.findFirst (lib.hasPrefix "~ ^/victoria/") "" (builtins.attrNames vhost.locations);
          allowList = {
            "metrics" = lib.hasInfix "metrics" names;
            "logs" = lib.hasInfix "logs" names;
            "traces" = lib.hasInfix "traces" names;
            "mcp" = lib.hasInfix "mcp" names;
            "no write prefixes" = !(lib.hasInfix "opentelemetry" names) && !(lib.hasInfix "insert" names);
          };
          failed = lib.filterAttrs (_: ok: !ok) (checks // allowList);
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "nginx /victoria/ is not reads-only: ${builtins.toJSON (builtins.attrNames failed)} (regex location: ${names})"
      );

  # For real: a read through /victoria/ works, a WRITE through it is 404 --
  # even with a valid write token -- while the same write succeeds on
  # vmauth's own internal port.
  nginx-victoria-serves-reads-and-refuses-writes = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-reads-only";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          writeTokensFile = "${writeTokensFixture}";
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(80)
      machine.wait_for_open_port(4204)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      machine.succeed(
          "curl -sf -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/metrics/api/v1/labels'"
      )

      machine.succeed("${otlpMetric} victoria_stack_nginx_reads_only_metric 1 > /tmp/otlp.bin")
      write = (
          "-X POST -H 'Authorization: Bearer nginx-write-token' "  # gitleaks:allow
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
      )
      code = machine.succeed(
          f"curl -s -o /dev/null -w '%{{http_code}}' {write} "
          "'http://127.0.0.1:80/victoria/opentelemetry/v1/metrics'"
      )
      assert code == "404", f"a write through nginx /victoria/ must be 404, got {code}"
      # The read prefixes end at a boundary: a longer name that merely STARTS
      # with one (/victoria/metricsX) is not a read route and must be nginx's own
      # 404, not vmauth's 400 "missing route" (which is what happens if the
      # (/|$) boundary is dropped from the location regex).
      for path in ["/victoria/metricsX/api/v1/labels", "/victoria/logsX", "/victoria/mcpfoo"]:
          code = machine.succeed(
              "curl -s -o /dev/null -w '%{http_code}' -u admin:nginx-admin-password "  # gitleaks:allow
              f"'http://127.0.0.1:80{path}'"
          )
          assert code == "404", f"{path} must be nginx's 404, got {code}"
      # Any other non-read path under /victoria/ is refused the same way.
      code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' -u admin:nginx-admin-password "  # gitleaks:allow
          "'http://127.0.0.1:80/victoria/something-else'"
      )
      assert code == "404", f"unknown /victoria/ path must be 404, got {code}"

      # The same write works on vmauth's own port -- the door writes belong on.
      machine.succeed(f"curl -sf {write} 'http://127.0.0.1:4204/opentelemetry/v1/metrics'")
    '';
  };

  # extraReadPaths widens the allow-list for a route added through
  # vmauth.extraReadUrlMap -- through a real request, not just rendered text.
  nginx-extra-read-paths-are-reachable-through-a-real-request = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-extra-read-paths";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx = {
          enable = true;
          extraReadPaths = [ "custom.route" ];
        };
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          extraReadUrlMap = [
            {
              src_paths = [ "/custom\\.route/api/v1/labels" ];
              drop_src_path_prefix_parts = 1;
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(80)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      auth = "-u admin:nginx-admin-password"  # gitleaks:allow

      def status(path):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' {auth} 'http://127.0.0.1:80{path}'"
          )

      assert status("/victoria/custom.route/api/v1/labels") == "200"
      # Not in extraReadPaths, so nginx refuses it before vmauth is asked.
      assert status("/victoria/other-route/api/v1/labels") == "404"
      # The "." in the entry is a literal dot: with it left as a regex wildcard
      # this near miss would pass nginx and get vmauth's own 400 instead.
      assert status("/victoria/customXroute/api/v1/labels") == "404"
    '';
  };

  # --- Grafana root_url default ---

  grafana-root-url-default-behind-nginx = pkgs.runCommand "grafana-root-url-default" { } (
    let
      rootUrl =
        m:
        (evalWith (
          {
            services.grafana = {
              enable = true;
              settings.security.secret_key = "$__file{${secretKeyFixture}}";
            };
          }
          // m
        )).config.services.grafana.settings.server.root_url or null;
      stackOn = {
        metrics.enable = true;
        grafana.enable = true;
        nginx.enable = true;
      };
      checks = {
        "set under /grafana/ when grafana and nginx are both on" = lib.hasSuffix "/grafana/" (rootUrl {
          services.victoriaStack = stackOn;
        });
        "not forced under /grafana/ when nginx is off" =
          !(lib.hasSuffix "/grafana/" (rootUrl {
            services.victoriaStack = stackOn // {
              nginx.enable = false;
            };
          }));
        "an operator value wins" =
          rootUrl {
            services = {
              victoriaStack = stackOn;
              grafana.settings.server.root_url = "https://example.invalid/grafana/";
            };
          } == "https://example.invalid/grafana/";
      };
      serveFromSubPath =
        (evalWith {
          services.grafana = {
            enable = true;
            settings.security.secret_key = "$__file{${secretKeyFixture}}";
          };
          services.victoriaStack = stackOn;
        }).config.services.grafana.settings.server.serve_from_sub_path or false;
      failed = lib.filterAttrs (_: ok: !ok) (
        checks
        // {
          "serve_from_sub_path stays off (the proxy strips the prefix)" = serveFromSubPath != true;
        }
      );
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "grafana root_url default broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # --- request bodies on /victoria/ ---

  nginx-body-limit-option-renders-and-validates = pkgs.runCommand "nginx-body-limit-option" { } (
    let
      configFor =
        m:
        (evalWith {
          services.victoriaStack = {
            metrics.enable = true;
            nginx = {
              enable = true;
            }
            // m;
          };
        }).config.services.nginx.virtualHosts."victoria-stack";
      readLoc =
        v:
        v.locations.${
          lib.findFirst (lib.hasPrefix "~ ^/victoria/") "MISSING" (builtins.attrNames v.locations)
        };
      extra = m: (readLoc (configFor m)).extraConfig;
      optType = (evalWith { }).options.services.victoriaStack.nginx.maxRequestBodySize.type;
      checks = {
        "default is 8m" = lib.hasInfix "client_max_body_size 8m;" (extra { });
        "custom value renders" = lib.hasInfix "client_max_body_size 2m;" (extra {
          maxRequestBodySize = "2m";
        });
        "0 renders as unlimited" = lib.hasInfix "client_max_body_size 0;" (extra {
          maxRequestBodySize = "0";
        });
        "request buffering is off for every setting" =
          lib.hasInfix "proxy_request_buffering off;" (extra { })
          && lib.hasInfix "proxy_request_buffering off;" (extra {
            maxRequestBodySize = "0";
          });
        "accepts nginx size forms" = lib.all optType.check [
          "512k"
          "8m"
          "1g"
          "100"
          "0"
        ];
        "rejects things nginx would not parse" =
          !(lib.any optType.check [
            "abc"
            "8mb"
            "-1"
            "1.5m"
            ""
          ]);
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "nginx body limit broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # For real: an oversized body is refused by nginx at once (413, judged from
  # Content-Length before any body is read), and a body under the cap with a valid
  # token still reaches vmauth.
  nginx-oversized-bodies-are-refused-and-normal-reads-pass = pkgs.testers.nixosTest {
    name = "victoria-stack-nginx-body-limit";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        nginx = {
          enable = true;
          maxRequestBodySize = "1m";
        };
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "nginx.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(80)
      wait_active(machine, "victoriametrics.service")
      machine.wait_for_open_port(4201)

      machine.succeed("head -c 3000000 /dev/zero > /tmp/big.bin")
      machine.succeed("head -c 100000 /dev/zero | tr '\\0' 'a' > /tmp/ok.bin")
      url = "http://127.0.0.1:80/victoria/metrics/api/v1/labels"
      auth = "-u admin:nginx-admin-password"  # gitleaks:allow

      def post(path_to_body, extra=""):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' {extra} -X POST "
              f"-H 'Content-Type: application/octet-stream' --data-binary @{path_to_body} '{url}'"
          ).strip()

      # Oversized: refused by nginx whoever sends it, with or without a token.
      assert post("/tmp/big.bin") == "413"
      assert post("/tmp/big.bin", auth) == "413"
      # Under the cap with a valid token: it reaches vmauth (and gets through to
      # the backend, whose own answer is not a 401/413).
      code = post("/tmp/ok.bin", auth)
      assert code not in ("401", "413"), code
      # Under the cap without a token: vmauth's own 401, not nginx's.
      assert post("/tmp/ok.bin") == "401"
    '';
  };
}
