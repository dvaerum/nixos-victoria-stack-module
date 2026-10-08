{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;
  listen = import ../nixosModule/victoriaStack/listen.nix { inherit lib; };

  adminPasswordFixture = pkgs.writeText "listen-admin-password" "listen-admin-password-value";

  secretKeyFixture = pkgs.writeText "listen-grafana-secret-key" "test-fixture-secret-key-not-real";

  mkTableCheck =
    name: checks:
    pkgs.runCommand name { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${name} wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  urlMapFile =
    prefix: evaluated:
    let
      v =
        lib.findFirst (lib.hasPrefix "${prefix}=") null
          evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
    in
    builtins.fromJSON (builtins.readFile (lib.removePrefix "${prefix}=" v));
in
{
  # The one helper that decides how a configured listen address is DIALLED and when
  # two addresses cannot both be bound. It replaces three copies of the same
  # wildcard logic.
  helper-table = mkTableCheck "listen-helper-table" {
    "empty host is a wildcard" = listen.isWildcard ":4201";
    "0.0.0.0 is a wildcard" = listen.isWildcard "0.0.0.0:4201";
    "[::] is a wildcard" = listen.isWildcard "[::]:4201";
    "loopback is not" = !(listen.isWildcard "127.0.0.1:4201");
    "an IPv6 literal is not" = !(listen.isWildcard "[::1]:4201");
    "connect :4201" = listen.connectAddr ":4201" == "127.0.0.1:4201";
    "connect 0.0.0.0" = listen.connectAddr "0.0.0.0:4201" == "127.0.0.1:4201";
    "connect [::]" = listen.connectAddr "[::]:4201" == "127.0.0.1:4201";
    "connect keeps a specific address" = listen.connectAddr "10.0.0.5:4201" == "10.0.0.5:4201";
    "connect keeps an IPv6 literal" = listen.connectAddr "[::1]:4201" == "[::1]:4201";
    "hostPort v4" = listen.hostPort "10.0.0.1" 80 == "10.0.0.1:80";
    "hostPort brackets a bare IPv6" = listen.hostPort "::1" 8443 == "[::1]:8443";
    "hostPort does not re-bracket" = listen.hostPort "[::1]" 8443 == "[::1]:8443";
    "host connect for an empty http_addr" = listen.connectHost "" == "127.0.0.1";
    "host connect for a bare IPv6" = listen.connectHost "::1" == "[::1]";
    # Grafana spells its IPv6 wildcard `::`, unbracketed.
    "host connect for the bare :: wildcard" = listen.connectHost "::" == "127.0.0.1";
    "overlap: identical" = listen.overlaps "127.0.0.1:4204" "127.0.0.1:4204";
    "overlap: v4 wildcard vs specific v4" = listen.overlaps "0.0.0.0:4204" "127.0.0.1:4204";
    "overlap: bare :port vs anything" =
      listen.overlaps ":4204" "127.0.0.1:4204" && listen.overlaps ":4204" "[::1]:4204";
    "overlap: [::] vs specific v4 (dual stack)" = listen.overlaps "[::]:4204" "127.0.0.1:4204";
    "no overlap: v4 wildcard vs an IPv6 literal" = !(listen.overlaps "0.0.0.0:4204" "[::1]:4204");
    "no overlap: different ports" = !(listen.overlaps "0.0.0.0:4204" "127.0.0.1:4205");
    "no overlap: two different specific addresses" =
      !(listen.overlaps "127.0.0.1:4204" "10.0.0.5:4204");
    "overlap: localhost vs 127.0.0.1" = listen.overlaps "localhost:4204" "127.0.0.1:4204";
    "overlap: 127.0.0.1 vs localhost (symmetric)" = listen.overlaps "127.0.0.1:4204" "localhost:4204";
    "overlap: localhost vs [::1]" = listen.overlaps "localhost:4204" "[::1]:4204";
    "overlap: localhost vs localhost" = listen.overlaps "localhost:4204" "localhost:4204";
    "overlap: localhost vs the v4 wildcard" = listen.overlaps "localhost:4204" "0.0.0.0:4204";
    "no overlap: localhost vs a non-loopback address" =
      !(listen.overlaps "localhost:4204" "10.0.0.5:4204");
    "no overlap: localhost on another port" = !(listen.overlaps "localhost:4299" "127.0.0.1:4204");
    "[::0] is a wildcard (nginx spells its IPv6 default so)" = listen.isWildcard "[::0]:80";
  };

  # Two listeners can share an address and port when their protocols differ
  # (syslog udp next to an HTTP listener, or udp and tcp syslog on port 514).
  protocol-and-loopback-table = mkTableCheck "listen-protocol-and-loopback-table" {
    "same protocol overlaps" = listen.overlapsProto "tcp" "0.0.0.0:514" "tcp" "127.0.0.1:514";
    "different protocols never overlap" =
      !(listen.overlapsProto "udp" "0.0.0.0:514" "tcp" "0.0.0.0:514");
    "same protocol, other ports" = !(listen.overlapsProto "udp" "0.0.0.0:514" "udp" "0.0.0.0:515");
    "127.0.0.1 is loopback" = listen.isLoopbackHost "127.0.0.1";
    "127.0.0.2 is loopback" = listen.isLoopbackHost "127.0.0.2";
    "bare ::1 is loopback" = listen.isLoopbackHost "::1";
    "[::1] is loopback" = listen.isLoopbackHost "[::1]";
    "localhost is loopback" = listen.isLoopbackHost "localhost";
    "the v4 wildcard is not" = !(listen.isLoopbackHost "0.0.0.0");
    "the v6 wildcard is not" = !(listen.isLoopbackHost "::");
    "a documentation address is not" = !(listen.isLoopbackHost "192.0.2.10");
    "a host that merely starts with 127 is not" = !(listen.isLoopbackHost "1270.0.0.1");
  };

  # A wildcard listenAddress used to be mapped to loopback only for the module's own
  # readiness probes; every URL it BUILT kept the raw address (http://:4201/...).
  wildcard-listen-addresses-reach-every-consumer =
    let
      eval =
        m:
        evalWith {
          services.victoriaStack = {
            metrics.enable = true;
            logs.enable = true;
            traces.enable = true;
            metrics.mcp.enable = true;
            nginx.enable = true;
          }
          // m;
        };
      forms = {
        bare = ":4301";
        v4 = "0.0.0.0:4301";
        v6 = "[::]:4301";
      };
      perForm =
        name: addr:
        let
          e = eval {
            metrics = {
              enable = true;
              listenAddress = addr;
              mcp = {
                enable = true;
                listenAddress = lib.replaceStrings [ "4301" ] [ "4302" ] addr;
              };
            };
            vmauth.listenAddress = lib.replaceStrings [ "4301" ] [ "4303" ] addr;
          };
          vhost = e.config.services.nginx.virtualHosts."victoria-stack";
          readLoc =
            vhost.locations.${
              lib.findFirst (lib.hasPrefix "~ ^/victoria/") "MISSING" (builtins.attrNames vhost.locations)
            };
          mcpEntry = lib.findFirst (x: lib.any (lib.hasPrefix "/mcp/metrics") x.src_paths) null (
            urlMapFile "READ_URL_MAP_FILE" e
          );
        in
        {
          "${name}: effectiveUrl" =
            e.config.services.victoriaStack.metrics.effectiveUrl == "http://127.0.0.1:4301";
          "${name}: nginx upstream" = readLoc.proxyPass == "http://127.0.0.1:4303";
          "${name}: vmauth route to the MCP server" =
            mcpEntry != null && mcpEntry.url_prefix == "http://127.0.0.1:4302/mcp";
          "${name}: mcp entrypoint is the effective URL" =
            e.config.systemd.services.mcp-victoriametrics.environment.VM_INSTANCE_ENTRYPOINT
            == "http://127.0.0.1:4301";
          "${name}: self-monitoring pushes to loopback" =
            lib.hasInfix "-pushmetrics.url=http://127.0.0.1:4301/api/v1/import/prometheus" e.config.systemd.services.victorialogs.serviceConfig.ExecStart;
        };
    in
    mkTableCheck "wildcard-listen-addresses-reach-every-consumer" (
      lib.foldl' (a: b: a // b) { } (lib.mapAttrsToList perForm forms)
    );

  # Grafana's own http_addr: empty means "all interfaces" and used to render
  # `http://:3000` (nginx: "no host in upstream").
  grafana-wildcard-http-addr-behind-nginx =
    let
      proxyPassFor =
        addr:
        let
          e = evalWith {
            services.grafana = {
              enable = true;
              settings = {
                security.secret_key = "$__file{${secretKeyFixture}}";
                server.http_addr = addr;
              };
            };
            services.victoriaStack = {
              metrics.enable = true;
              grafana.enable = true;
              nginx.enable = true;
            };
          };
        in
        e.config.services.nginx.virtualHosts."victoria-stack".locations."/grafana/".proxyPass;
    in
    mkTableCheck "grafana-wildcard-http-addr-behind-nginx" {
      "empty" = proxyPassFor "" == "http://127.0.0.1:3000";
      "0.0.0.0" = proxyPassFor "0.0.0.0" == "http://127.0.0.1:3000";
      "IPv6 literal is bracketed" = proxyPassFor "::1" == "http://[::1]:3000";
      "specific address untouched" = proxyPassFor "10.0.0.7" == "http://10.0.0.7:3000";
    };

  # The collision assertion compared raw strings, so `0.0.0.0:4204` next to
  # vmauth's `127.0.0.1:4204` passed although they cannot both bind.
  listener-collision-considers-wildcards =
    let
      fires =
        m:
        lib.any (lib.hasInfix "same listenAddress") (
          lib.filter (lib.hasInfix "services.victoriaStack") (
            map (a: a.message) (
              builtins.filter (a: !a.assertion)
                (evalWith {
                  services.victoriaStack = lib.recursiveUpdate { metrics.enable = true; } m;
                }).config.assertions
            )
          )
        );
      certs = {
        certFile = "/run/secrets/c.pem";
        keyFile = "/run/secrets/k.pem";
      };
    in
    mkTableCheck "listener-collision-considers-wildcards" {
      "v4 wildcard vs vmauth's loopback" = fires { metrics.listenAddress = "0.0.0.0:4204"; };
      "bare :port" = fires { metrics.listenAddress = ":4204"; };
      "[::]" = fires { metrics.listenAddress = "[::]:4204"; };
      "identical addresses still fire" = fires { metrics.listenAddress = "127.0.0.1:4204"; };
      "an http door on the internal port" = fires {
        vmauth.http = {
          enable = true;
          ipAddress = "127.0.0.1";
          port = 4204;
        };
      };
      "an https door on the wildcard of the internal port" = fires {
        vmauth.https = {
          enable = true;
          port = 4204;
        }
        // certs;
      };
      "v4 wildcard vs an IPv6 literal does NOT fire" =
        !(fires {
          metrics.listenAddress = "0.0.0.0:4204";
          vmauth.listenAddress = "[::1]:4204";
        });
      "distinct ports do not fire" = !(fires { metrics.listenAddress = "0.0.0.0:4299"; });
    };

  # Hostnames (localhost) and the listeners of nginx and Grafana are part of the
  # same collision check, and the message names both parties.
  listener-collision-localhost-nginx-grafana =
    let
      messages =
        extra: m:
        lib.filter (lib.hasInfix "same listenAddress") (
          lib.filter (lib.hasInfix "services.victoriaStack") (
            map (a: a.message) (
              builtins.filter (a: !a.assertion)
                (evalWith {
                  imports = [
                    { services.victoriaStack = lib.recursiveUpdate { metrics.enable = true; } m; }
                    extra
                  ];
                }).config.assertions
            )
          )
        );
      fires = m: messages { } m != [ ];
      firesWith = extra: m: messages extra m != [ ];
      names = m: needles: lib.all (n: lib.any (lib.hasInfix n) (messages { } m)) needles;
      grafana = {
        services.victoriaStack.grafana.enable = true;
        services.grafana.settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    in
    mkTableCheck "listener-collision-localhost-nginx-grafana" {
      "localhost vs vmauth's 127.0.0.1" = fires { metrics.listenAddress = "localhost:4204"; };
      "localhost on another port does not fire" = !(fires { metrics.listenAddress = "localhost:4299"; });
      "the message names both parties" = names { metrics.listenAddress = "localhost:4204"; } [
        "services.victoriaStack.metrics.listenAddress"
        "services.victoriaStack.vmauth.listenAddress"
        "localhost:4204"
        "127.0.0.1:4204"
      ];
      "a service on Grafana's default port" = firesWith grafana {
        metrics.listenAddress = "127.0.0.1:3000";
      };
      "Grafana named in the message" = lib.any (lib.hasInfix "services.grafana.settings.server") (
        messages grafana { metrics.listenAddress = "127.0.0.1:3000"; }
      );
      "Grafana's configured port is used, not 3000" = firesWith (lib.recursiveUpdate grafana {
        services.grafana.settings.server.http_port = 3100;
      }) { metrics.listenAddress = "127.0.0.1:3100"; };
      "a moved Grafana frees 3000" =
        !(firesWith (lib.recursiveUpdate grafana { services.grafana.settings.server.http_port = 3100; }) {
          metrics.listenAddress = "127.0.0.1:3000";
        });
      "Grafana not enabled by the module: 3000 is free" =
        !(fires { metrics.listenAddress = "127.0.0.1:3000"; });
      "nginx's default port 80" = fires {
        nginx.enable = true;
        metrics.listenAddress = "127.0.0.1:80";
      };
      "nginx named in the message" =
        names
          {
            nginx.enable = true;
            metrics.listenAddress = "127.0.0.1:80";
          }
          [
            "services.victoriaStack.nginx"
            "services.victoriaStack.metrics.listenAddress"
          ];
      "nginx's configured listen port" =
        firesWith
          {
            services.nginx.virtualHosts."victoria-stack".listen = [
              {
                addr = "127.0.0.1";
                port = 8081;
              }
            ];
          }
          {
            nginx.enable = true;
            metrics.listenAddress = "127.0.0.1:8081";
          };
      "nginx's 443 only when the vhost serves TLS" =
        !(fires {
          nginx.enable = true;
          metrics.listenAddress = "127.0.0.1:443";
        })
        && firesWith { services.nginx.virtualHosts."victoria-stack".forceSSL = true; } {
          nginx.enable = true;
          metrics.listenAddress = "127.0.0.1:443";
        };
      "nginx off: port 80 is free" = !(fires { metrics.listenAddress = "127.0.0.1:80"; });
    };

  # For real, with wildcard listen addresses on the database, its MCP server and
  # vmauth: every module-built URL must dial loopback (the self-monitoring push
  # used to be http://:4201/..., nginx's upstream http://:4204).
  wildcard-listen-address-works-end-to-end = pkgs.testers.nixosTest {
    name = "victoria-stack-wildcard-listen-end-to-end";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          listenAddress = ":4201";
          mcp = {
            enable = true;
            listenAddress = ":4210";
          };
          selfMonitoring.interval = "5s";
        };
        vmauth = {
          listenAddress = ":4204";
          adminPasswordFile = "${adminPasswordFixture}";
        };
        nginx.enable = true;
      };
    };

    testScript = ''
      start_all()
      for unit in ["victoriametrics", "mcp-victoriametrics", "vmauth", "nginx"]:
          machine.wait_for_unit(f"{unit}.service")
      machine.wait_for_open_port(4201)
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(80)

      auth = "-u admin:listen-admin-password-value"  # gitleaks:allow
      machine.succeed(f"curl -sf {auth} 'http://127.0.0.1:4204/metrics/api/v1/labels'")
      machine.succeed(f"curl -sf {auth} 'http://127.0.0.1:80/victoria/metrics/api/v1/labels'")
      # vmauth -> the MCP server, whose address is also a wildcard.
      code = machine.succeed(
          f"curl -s -o /dev/null -w '%{{http_code}}' {auth} -X POST 'http://127.0.0.1:4204/mcp/metrics' "
          "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "
          "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
          "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
          "\"clientInfo\":{\"name\":\"listen-test\",\"version\":\"1\"}}}'"
      ).strip()
      assert code == "200", code
      # Self-monitoring reaches the database through the wildcard-derived URL.
      machine.wait_until_succeeds(
          "curl -sfG 'http://127.0.0.1:4201/api/v1/query' "
          "--data-urlencode 'query=vm_app_version{job=\"victoriametrics\"}' | grep -q '\"value\"'",
          timeout=120,
      )
    '';
  };
}
