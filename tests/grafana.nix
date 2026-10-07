{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkWarningFiresCheck mkNoWarningsCheck evalWith;

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
          grafanaConsumerConfig
        ];
        services.victoriaStack = backends // {
          grafana.enable = true;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("grafana.service")
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
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
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
        # nginx fronting everything must not drag the datasource URL
        # through vmauth/nginx either.
        nginx = {
          enable = true;
          domain = "victoria-stack-test.example.com";
        };
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
          "curl -sf -u admin:admin 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
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
        grafanaConsumerConfig
      ];
      services.victoriaStack = {
        # metrics deliberately left disabled.
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("grafana.service")
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

  # Phase 43 fresh-agent review finding: without Grafana's own `prune:
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

  # The grafana side of the effectiveUrl seam (docs/decisions/0019): every
  # datasource URL must derive from the backend's effectiveUrl, not
  # listenAddress. Mirrors mcp.nix's mcp-metrics-entrypoint-uses-effective-url.
  datasource-urls-use-effective-url =
    pkgs.runCommand "grafana-datasource-urls-use-effective-url" { }
      (
        let
          fake = name: "http://${name}.example.invalid:9999";
          evaluated = evalWith {
            services.victoriaStack = {
              metrics = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "m");
              };
              logs = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "l");
              };
              traces = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "t");
              };
              grafana.enable = true;
            };
          };
          urls = map (d: d.url) evaluated.config.services.grafana.provision.datasources.settings.datasources;
          expected = [
            (fake "m")
            (fake "l")
            "${fake "t"}/select/jaeger"
          ];
        in
        if urls == expected then
          "echo OK > $out"
        else
          throw "datasource urls did not track effectiveUrl: expected ${builtins.toJSON expected}, got ${builtins.toJSON urls}"
      );

  # ADR 0020's documented workaround for tweaking one auto-provisioned
  # datasource: mkForce the whole list, reconstructing the 3 built-in
  # entries by hand, plus an extra one. Proves the workaround the README
  # tells operators to use really yields exactly 4 entries.
  mkforce-reconstruct-workaround-yields-the-builtin-three-plus-one =
    pkgs.runCommand "grafana-mkforce-reconstruct-workaround" { }
      (
        let
          builtinThree = [
            {
              name = "VictoriaMetrics";
              type = "victoriametrics-metrics-datasource";
              uid = "victoriametrics-ds";
              url = "http://127.0.0.1:4201";
              isDefault = true;
              access = "proxy";
              editable = false;
            }
            {
              name = "VictoriaLogs";
              type = "victoriametrics-logs-datasource";
              uid = "victorialogs-ds";
              url = "http://127.0.0.1:4202";
              isDefault = false;
              access = "proxy";
              editable = false;
            }
            {
              name = "VictoriaTraces";
              type = "jaeger";
              uid = "victoriatraces-ds";
              url = "http://127.0.0.1:4203/select/jaeger";
              isDefault = false;
              access = "proxy";
              editable = false;
            }
          ];
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
              imports = [ extraModule ];
              services.victoriaStack = {
                metrics.enable = true;
                logs.enable = true;
                traces.enable = true;
                grafana.enable = true;
              };
            }).config.services.grafana.provision.datasources.settings.datasources;
          untouched = datasourcesOf { };
          forced = datasourcesOf {
            services.grafana.provision.datasources.settings.datasources = lib.mkForce (
              builtinThree ++ [ extra ]
            );
          };
          names = map (d: d.name) forced;
        in
        if
          builtins.length untouched == 3
          &&
            names == [
              "VictoriaMetrics"
              "VictoriaLogs"
              "VictoriaTraces"
              "Extra"
            ]
        then
          "echo OK > $out"
        else
          throw "mkForce workaround broken: untouched=${toString (builtins.length untouched)} forced=${builtins.toJSON names}"
      );
}
