{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    mkWarningFiresCheck
    mkNoWarningsCheck
    evalWith
    grafanaReadTokenFile
    vmauthReadTokensWithGrafana
    ;

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

  # grafana.enable needs a read token Grafana sends and the same token in
  # vmauth's read tier (docs/decisions/0029).
  grafanaTokenWiring = {
    services.victoriaStack = {
      grafana.readTokenFile = "${grafanaReadTokenFile}";
      vmauth.readTokensFile = "${vmauthReadTokensWithGrafana}";
    };
  };

  # The remaining 4 of the 2^3 - 1 = 7 non-empty backend combinations
  # (all-3, metrics-only, and logs+traces-without-metrics below already
  # cover 3) -- each is a genuinely different datasourceSpecs permutation
  # that could independently hit the same class of bug the isDefault
  # auto-promotion check below was written for (a real Grafana >=12.2
  # provisioning crash-loop, confirmed live, is also combination-specific
  # by nature: deleteDatasources/declarativePlugins both build their
  # contents from the exact same enabled-backend set).
  mkDatasourceComboTest =
    {
      name,
      backends,
      expectPresent,
      expectAbsent,
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-grafana-${name}";

      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
          grafanaConsumerConfig
          grafanaTokenWiring
        ];
        services.victoriaStack = backends // {
          grafana.enable = true;
        };
      };

      testScript = ''
        ${testLib.waitActivePython}
        start_all()
        wait_active(machine, "grafana.service")
        machine.wait_for_open_port(3000)

        datasources = machine.succeed(
            "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
        )
        for marker in ${builtins.toJSON expectPresent}:
            assert marker in datasources, f"expected {marker!r} present: {datasources!r}"
        for marker in ${builtins.toJSON expectAbsent}:
            assert marker not in datasources, f"expected {marker!r} absent: {datasources!r}"
      '';
    };
in
{
  datasources-provisioned-for-enabled-backends = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-datasources-provisioned";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
        grafanaTokenWiring
      ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)

      # Default Grafana admin credentials (admin/admin) since this test
      # doesn't override security.admin_password -- fine for a throwaway
      # container, never done this way for a real deployment (this
      # module's own adminPasswordFile-style options are for vmauth, not
      # Grafana -- see docs/decisions/0010, Grafana keeps its own auth).
      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources
    '';
  };

  # The datasources must point at vmauth's read tier, not at a backend:
  # Grafana's datasource proxy forwards any method and path for any Viewer, so
  # a raw backend URL lets a Viewer write and delete (docs/decisions/0029).
  datasources-through-vmauth-read-tier = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-datasources-through-vmauth";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
        grafanaTokenWiring
      ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      import json

      start_all()
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)

      datasources = json.loads(machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
      ))
      urls = {d["uid"]: d["url"] for d in datasources}
      assert urls == {
          "victoriametrics-ds": "http://127.0.0.1:4204/metrics",
          "victorialogs-ds": "http://127.0.0.1:4204/logs",
          "victoriatraces-ds": "http://127.0.0.1:4204/traces/select/jaeger",
      }, f"datasources must go through vmauth's read tier, not a backend: {urls!r}"
    '';
  };

  # The security property of docs/decisions/0029, end to end with the real
  # plugins: a Grafana Viewer reads through the datasource proxy, and every
  # write/delete/snapshot/flags request is rejected by vmauth's read tier
  # (docs/decisions/0021) -- and really changes nothing in the backend.
  viewer-reads-but-cannot-write-through-datasource-proxy = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-viewer-read-only";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
        grafanaTokenWiring
      ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      import json

      start_all()
      wait_active(machine, "grafana.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(3000)
      machine.wait_for_open_port(4204)

      admin = "-u admin:admin"  # gitleaks:allow
      viewer = "-u viewer:viewer-fixture-password"  # gitleaks:allow
      grafana = "http://127.0.0.1:3000"

      machine.wait_until_succeeds(f"curl -sf {admin} {grafana}/api/health")
      machine.succeed(
          f"curl -sf {admin} -X POST {grafana}/api/admin/users "
          "-H 'Content-Type: application/json' "
          "-d '{\"name\":\"viewer\",\"login\":\"viewer\",\"password\":\"viewer-fixture-password\"}'"  # gitleaks:allow
      )
      role = json.loads(machine.succeed(f"curl -sf {viewer} {grafana}/api/user/orgs"))[0]["role"]
      assert role == "Viewer", f"the probe user must be a plain Viewer, got {role!r}"

      # The ingest formats are line based and drop an unterminated last line,
      # so every body is sent with a trailing newline.
      def curl_with_body(data, curl_args):
          return f"printf '%s\\n' '{data}' | curl -H 'Content-Type: application/stream+json' --data-binary @- {curl_args}"

      def proxy(ds, method, path, data=None):
          args = f"-s -w '\\n%{{http_code}}' {viewer} -X {method} '{grafana}/api/datasources/proxy/uid/{ds}{path}'"
          out = machine.succeed(curl_with_body(data, args) if data else f"curl {args}")
          text, code = out.rsplit("\n", 1)
          return int(code), text

      # Data the operator writes straight to the backends.
      machine.succeed(
          curl_with_body(
              "grafana_probe_metric 42",
              "-sf -X POST http://127.0.0.1:4201/api/v1/import/prometheus",
          )
      )
      machine.succeed("curl -sf http://127.0.0.1:4201/internal/force_flush")
      machine.succeed(
          curl_with_body(
              '{"_msg":"operator-line","date":"0"}',
              "-sf -X POST 'http://127.0.0.1:4202/insert/jsonline?_time_field=date'",
          )
      )
      machine.wait_until_succeeds(
          "out=$(curl -sf http://127.0.0.1:4202/select/logsql/query -d 'query=operator-line') && [[ $out == *operator-line* ]]"
      )

      # Reads work through the proxy.
      def read_ok(ds, path, needle):
          code, text = proxy(ds, "GET", path)
          assert code == 200 and needle in text, (ds, path, code, text[:300])

      machine.wait_until_succeeds(
          "out=$(curl -sf http://127.0.0.1:4201/api/v1/series -d 'match[]=grafana_probe_metric') "
          "&& [[ $out == *grafana_probe_metric* ]]"
      )
      read_ok("victoriametrics-ds", "/api/v1/series?match[]=grafana_probe_metric", "grafana_probe_metric")
      read_ok("victoriametrics-ds", "/api/v1/labels", "__name__")
      read_ok("victorialogs-ds", "/select/logsql/query?query=operator-line", "operator-line")

      # Everything that changes or leaks state is refused by vmauth itself.
      def refused(ds, method, path, data=None):
          code, text = proxy(ds, method, path, data)
          assert code == 400 and "missing route" in text, (ds, method, path, code, text[:300])

      refused("victoriametrics-ds", "POST", "/api/v1/import/prometheus", "viewer_written_metric 1")
      refused("victoriametrics-ds", "POST", "/api/v1/admin/tsdb/delete_series?match[]=grafana_probe_metric")
      refused("victoriametrics-ds", "GET", "/snapshot/create")
      refused("victoriametrics-ds", "GET", "/flags")
      refused(
          "victorialogs-ds", "POST", "/insert/jsonline?_time_field=date",
          '{"_msg":"viewer-written-line","date":"0"}',
      )
      refused("victorialogs-ds", "GET", "/flags")

      # ...and nothing happened in the backends.
      machine.succeed("curl -sf http://127.0.0.1:4201/internal/force_flush")
      series = machine.succeed(
          "curl -sf http://127.0.0.1:4201/api/v1/series --data-urlencode 'match[]={__name__=~\".+\"}'"
      )
      assert "grafana_probe_metric" in series, f"delete_series must not have run: {series!r}"
      assert "viewer_written_metric" not in series, f"import must not have run: {series!r}"
      logs = machine.succeed("curl -sf http://127.0.0.1:4202/select/logsql/query -d 'query=*'")
      assert "viewer-written-line" not in logs, f"insert must not have run: {logs!r}"
    '';
  };

  only-enabled-backends-get-datasources = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-only-enabled-backends";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
        grafanaTokenWiring
      ];
      services.victoriaStack = {
        metrics.enable = true;
        # logs/traces deliberately left disabled.
        grafana.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)

      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" not in datasources
      assert "jaeger" not in datasources
    '';
  };

  # Reverse of the above: metrics disabled, logs+traces enabled. isDefault
  # is hardcoded true only on the metrics datasource spec
  # (nixosModule/victoriaStack/grafana.nix) -- when metrics is absent, no
  # datasource is marked default at all. Previously untested whether that
  # combination still provisions correctly (declarativePlugins only pulls
  # in the metrics/logs plugins conditionally; this confirms Grafana
  # starts cleanly and both remaining datasources are present without the
  # metrics plugin/datasource in the mix).
  logs-and-traces-datasources-without-metrics = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-logs-and-traces-without-metrics";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
        grafanaTokenWiring
      ];
      services.victoriaStack = {
        # metrics deliberately left disabled.
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)

      datasources = machine.succeed(
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
      )
      assert "victoriametrics-metrics-datasource" not in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources

      # Confirmed directly (this assertion was wrong until corrected):
      # Grafana's own provisioning auto-promotes the first-listed
      # datasource to isDefault=true when none of the provisioned entries
      # claims it -- isDefault being hardcoded false on both the logs and
      # traces specs doesn't mean "no default at all", it means "let
      # Grafana decide", and Grafana always picks one. The real invariant
      # worth checking is that exactly one is default (not zero, not
      # both), and that it isn't the disabled metrics datasource (which
      # isn't provisioned at all in this combination, so that's already
      # covered by the "not in datasources" assertion above).
      assert datasources.count('"isDefault":true') == 1, (
          "expected exactly one datasource marked default when metrics "
          "is disabled (Grafana auto-promotes one when none is explicit)"
      )
    '';
  };

  logs-only-datasource = mkDatasourceComboTest {
    name = "logs-only";
    backends = {
      logs.enable = true;
    };
    expectPresent = [ "victoriametrics-logs-datasource" ];
    expectAbsent = [
      "victoriametrics-metrics-datasource"
      "jaeger"
    ];
  };

  traces-only-datasource = mkDatasourceComboTest {
    name = "traces-only";
    backends = {
      traces.enable = true;
    };
    expectPresent = [ "jaeger" ];
    expectAbsent = [
      "victoriametrics-metrics-datasource"
      "victoriametrics-logs-datasource"
    ];
  };

  metrics-and-logs-datasources = mkDatasourceComboTest {
    name = "metrics-and-logs";
    backends = {
      metrics.enable = true;
      logs.enable = true;
    };
    expectPresent = [
      "victoriametrics-metrics-datasource"
      "victoriametrics-logs-datasource"
    ];
    expectAbsent = [ "jaeger" ];
  };

  metrics-and-traces-datasources = mkDatasourceComboTest {
    name = "metrics-and-traces";
    backends = {
      metrics.enable = true;
      traces.enable = true;
    };
    expectPresent = [
      "victoriametrics-metrics-datasource"
      "jaeger"
    ];
    expectAbsent = [ "victoriametrics-logs-datasource" ];
  };

  grafana-enabled-with-zero-backends-warns = mkWarningFiresCheck {
    name = "grafana-enabled-with-zero-backends-warns";
    expectMessageSubstring = "datasourceSpecs empty";
    module = {
      services.victoriaStack.grafana.enable = true;
      services.grafana.enable = true;
      # metrics/logs/traces all deliberately left disabled.
    };
  };

  # Control: any one backend enabled alongside grafana.enable -- no
  # warning should fire.
  grafana-enabled-with-a-backend-does-not-warn = mkNoWarningsCheck {
    name = "grafana-enabled-with-a-backend-does-not-warn";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
      };
      services.grafana.enable = true;
    };
  };

  # Without Grafana's own `prune:
  # true` top-level provisioning key, a datasource removed from the
  # file entirely (a backend disabled after having been enabled) is
  # never actually deleted -- deleteDatasources (built from the SAME
  # datasourceSpecs as `datasources`) is also missing that entry on the
  # next run, so nothing ever revisits it. This only tests the Nix-level
  # setting itself (deterministic, under this module's own control) --
  # NOT the live Grafana behavior it's supposed to trigger. Confirmed
  # live, repeatedly, via a real switch-to-configuration test: on the
  # currently pinned Grafana version (13.1.6), `prune: true` does NOT
  # actually prune anything -- a real, previously filed upstream bug
  # (github.com/grafana/grafana/issues/94645), only very recently fixed
  # upstream (grafana/grafana#83034), likely not yet in this pin. See
  # grafana.nix's own comment. Asserting the live behavior here would
  # mean asserting something currently, verifiably false upstream --
  # the correct scope for THIS project's test suite is "did we configure
  # the documented, correct setting", not "does Grafana's own
  # third-party bug happen to be fixed in whatever version nixpkgs
  # currently pins".
  prune-is-configured-for-datasource-provisioning =
    pkgs.runCommand "grafana-prune-is-configured" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              grafana.enable = true;
            };
          };
          prune = evaluated.config.services.grafana.provision.datasources.settings.prune or null;
        in
        if prune == true then
          "echo OK > $out"
        else
          throw "expected services.grafana.provision.datasources.settings.prune = true, got ${builtins.toJSON prune}"
      );

  # Datasource URLs are vmauth's internal data listener (dialled on loopback
  # for a wildcard address) plus the backend's read prefix. They no longer
  # derive from the backends' effectiveUrl (docs/decisions/0019): vmauth does
  # that hop, so the seam stays in one place.
  datasource-urls-go-through-vmauth-listener =
    pkgs.runCommand "grafana-datasource-urls-go-through-vmauth-listener" { }
      (
        let
          evaluated = evalWith {
            imports = [ grafanaTokenWiring ];
            services.victoriaStack = {
              metrics = {
                enable = true;
                effectiveUrl = lib.mkForce "http://m.example.invalid:9999";
              };
              logs.enable = true;
              traces.enable = true;
              grafana.enable = true;
              vmauth.listenAddress = "0.0.0.0:4999";
            };
          };
          urls = map (d: d.url) evaluated.config.services.grafana.provision.datasources.settings.datasources;
          expected = [
            "http://127.0.0.1:4999/metrics"
            "http://127.0.0.1:4999/logs"
            "http://127.0.0.1:4999/traces/select/jaeger"
          ];
        in
        if urls == expected then
          "echo OK > $out"
        else
          throw "datasource urls must be vmauth's connect address plus the read prefix: expected ${builtins.toJSON expected}, got ${builtins.toJSON urls}"
      );

  # Every datasource sends the read token as an Authorization header read from
  # the unit's credentials directory; the token itself never reaches the store.
  datasources-send-the-read-token-from-a-credential =
    pkgs.runCommand "grafana-datasources-send-the-read-token-from-a-credential" { }
      (
        let
          evaluated = evalWith {
            imports = [ grafanaTokenWiring ];
            services.grafana.enable = true;
            services.victoriaStack = {
              metrics.enable = true;
              logs.enable = true;
              traces.enable = true;
              grafana.enable = true;
            };
          };
          settings = evaluated.config.services.grafana.provision.datasources.settings;
          headerFile = "/run/grafana/vmauth-authorization";
          checks = {
            "header name on every datasource" = lib.all (
              d: d.jsonData.httpHeaderName1 == "Authorization"
            ) settings.datasources;
            "header value is one $__file{} on every datasource" = lib.all (
              d: d.secureJsonData.httpHeaderValue1 == "$__file{${headerFile}}"
            ) settings.datasources;
            # nixpkgs warns about any secureJsonData value that is not a whole
            # $__file{}/$__env{} reference, a prefix such as "Bearer " included.
            "no secureJsonData leak warning from nixpkgs" =
              !(lib.any (lib.hasInfix "secureJsonData") evaluated.config.warnings);
            "header file is built from the credential before Grafana starts" =
              lib.any (lib.hasInfix "grafana-vmauth-auth-header") (
                map toString evaluated.config.systemd.services.grafana.serviceConfig.ExecStartPre
              );
            "credential loaded into the grafana unit" = lib.elem "grafana-read-token:${grafanaReadTokenFile}" (
              evaluated.config.systemd.services.grafana.serviceConfig.LoadCredential
            );
            "token value absent from the provisioning settings" =
              !(lib.hasInfix testLib.grafanaReadToken (builtins.toJSON settings));
          };
          failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
        in
        if failed == [ ] then
          "echo OK > $out"
        else
          throw "datasource credential wiring broken: ${builtins.toJSON failed}"
      );

  # Like vmauth's own secret files: a plain string (a Nix path literal would
  # copy the secret into the store at evaluation), and a replaced file restarts
  # the unit that only reads it at start.
  grafana-read-token-file-is-a-plain-string-and-watched =
    pkgs.runCommand "grafana-read-token-file-is-a-plain-string-and-watched" { }
      (
        let
          evaluated = evalWith {
            imports = [ grafanaTokenWiring ];
            services.victoriaStack = {
              metrics.enable = true;
              grafana.enable = true;
            };
          };
          watch = evaluated.config.systemd.paths."grafana-read-token-watch" or null;
          checks = {
            "option type is str" =
              evaluated.options.services.victoriaStack.grafana.readTokenFile.type.nestedTypes.elemType.name
              == "str";
            "a path watches the file" =
              watch != null && watch.pathConfig.PathChanged == "${grafanaReadTokenFile}";
            "a change try-restarts grafana" =
              lib.hasInfix "try-restart grafana.service" evaluated.config.systemd.services.grafana-secret-restart.serviceConfig.ExecStart;
          };
          failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
        in
        if failed == [ ] then
          "echo OK > $out"
        else
          throw "grafana.readTokenFile handling broken: ${builtins.toJSON failed}"
      );

  # The whole provisioning document the module hands to Grafana, spelled out: a
  # datasource's type, uid, URL, default flag, access mode, editability and the
  # delete-then-recreate list are all things Grafana only reveals at runtime, so
  # a changed value is otherwise invisible until a deployment misbehaves.
  datasource-provisioning-document-is-exactly-this =
    pkgs.runCommand "grafana-datasource-provisioning-document" { }
      (
        let
          evaluated = evalWith {
            imports = [ grafanaTokenWiring ];
            services.grafana.enable = true;
            services.victoriaStack = {
              metrics.enable = true;
              logs.enable = true;
              traces.enable = true;
              grafana.enable = true;
            };
          };
          authorized = {
            access = "proxy";
            editable = false;
            jsonData.httpHeaderName1 = "Authorization";
            secureJsonData.httpHeaderValue1 = "$__file{/run/grafana/vmauth-authorization}";
          };
          expected = {
            apiVersion = 1;
            prune = true;
            datasources = [
              (
                {
                  name = "VictoriaMetrics";
                  type = "victoriametrics-metrics-datasource";
                  uid = "victoriametrics-ds";
                  url = "http://127.0.0.1:4204/metrics";
                  isDefault = true;
                }
                // authorized
              )
              (
                {
                  name = "VictoriaLogs";
                  type = "victoriametrics-logs-datasource";
                  uid = "victorialogs-ds";
                  url = "http://127.0.0.1:4204/logs";
                  isDefault = false;
                }
                // authorized
              )
              (
                {
                  name = "VictoriaTraces";
                  type = "jaeger";
                  uid = "victoriatraces-ds";
                  url = "http://127.0.0.1:4204/traces/select/jaeger";
                  isDefault = false;
                }
                // authorized
              )
            ];
            deleteDatasources = [
              {
                name = "VictoriaMetrics";
                orgId = 1;
              }
              {
                name = "VictoriaLogs";
                orgId = 1;
              }
              {
                name = "VictoriaTraces";
                orgId = 1;
              }
            ];
          };
          got = evaluated.config.services.grafana.provision.datasources.settings;
        in
        if got == expected then
          "echo OK > $out"
        else
          throw "the provisioning document changed.\nexpected: ${builtins.toJSON expected}\ngot:      ${builtins.toJSON got}"
      );

  # The datasource plugins come in with the backends that need them (traces use
  # Grafana's built-in jaeger type, so none): a missing plugin makes Grafana
  # reject its own provisioning file at start.
  datasource-plugins-follow-the-enabled-backends =
    pkgs.runCommand "grafana-datasource-plugins-follow-the-enabled-backends" { }
      (
        let
          pluginsFor =
            backends:
            map (p: p.pname or p.name) (
              lib.defaultTo [ ] (
                (evalWith {
                  imports = [ grafanaTokenWiring ];
                  services.grafana.enable = true;
                  services.victoriaStack = backends // {
                    grafana.enable = true;
                  };
                }).config.services.grafana.declarativePlugins
              )
            );
          checks = {
            "metrics: the metrics plugin only" =
              pluginsFor { metrics.enable = true; } == [ "victoriametrics-metrics-datasource" ];
            "logs: the logs plugin only" =
              pluginsFor { logs.enable = true; } == [ "victoriametrics-logs-datasource" ];
            "traces: none" = pluginsFor { traces.enable = true; } == [ ];
            "all: metrics then logs" =
              pluginsFor {
                metrics.enable = true;
                logs.enable = true;
                traces.enable = true;
              } == [
                "victoriametrics-metrics-datasource"
                "victoriametrics-logs-datasource"
              ];
          };
          failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
        in
        if failed == [ ] then
          "echo OK > $out"
        else
          throw "datasource plugins wrong for: ${builtins.toJSON failed}; metrics=${
            builtins.toJSON (pluginsFor {
              metrics.enable = true;
            })
          } logs=${
            builtins.toJSON (pluginsFor {
              logs.enable = true;
            })
          }"
      );

  # ADR 0020's documented workaround for tweaking one auto-provisioned
  # datasource: mkForce the whole list, rebuilt from what the module itself
  # provisions (copy its output, change one entry, add one). The module's own
  # list is the reference, so a hand-copied literal cannot drift from it.
  mkforce-reconstruct-workaround-yields-the-builtin-three-plus-one =
    pkgs.runCommand "grafana-mkforce-reconstruct-workaround" { }
      (
        let
          extra = {
            name = "Extra";
            type = "prometheus";
            uid = "extra-ds";
            url = "http://127.0.0.1:9090";
            isDefault = false;
            access = "proxy";
            editable = false;
          };
          datasourcesOf =
            extraModule:
            (evalWith {
              imports = [
                grafanaTokenWiring
                extraModule
              ];
              services.grafana.enable = true;
              services.victoriaStack = {
                metrics.enable = true;
                logs.enable = true;
                traces.enable = true;
                grafana.enable = true;
              };
            }).config.services.grafana.provision.datasources.settings.datasources;
          untouched = datasourcesOf { };
          # The operator's tweak: repoint the logs datasource, keep the rest.
          tweak =
            d: if d.uid == "victorialogs-ds" then d // { url = "http://logs.example.invalid:9428"; } else d;
          forced = datasourcesOf {
            services.grafana.provision.datasources.settings.datasources = lib.mkForce (
              map tweak untouched ++ [ extra ]
            );
          };
          expected = map tweak untouched ++ [ extra ];
          present = map (lib.filterAttrs (_: v: v != null));
        in
        # nixpkgs adds null jsonData/secureJsonData to entries that lack them.
        if
          builtins.length untouched == 3
          && present forced == present expected
          && present forced != present (untouched ++ [ extra ])
        then
          "echo OK > $out"
        else
          throw "mkForce workaround broken: untouched=${toString (builtins.length untouched)} forced=${builtins.toJSON forced}"
      );
}
