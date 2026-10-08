{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkWarningFiresCheck mkNoWarningsCheck evalWith;

  # Option types vs the real binaries' grammars. retentionPeriod and
  # retentionMaxDiskSpaceUsageBytes were plain strings, so "30days" evaluated
  # cleanly and the binary died at start (`cannot parse duration "ays"`). The
  # lists below feed BOTH the type check and the real-binary check, so the two
  # cannot drift apart. The types are deliberately narrower than the binaries
  # (which also take 30D, 1e2, +1, .5, 5., lower-case sizes): only the
  # documented forms are accepted.
  retentionAccepted = [
    "12"
    "1"
    "1.5"
    "30d"
    "4w"
    "1M"
    "1y"
    "1.5y"
    "36h"
    "1d12h"
  ];
  # Dies in the binary's flag parsing.
  retentionRejected = [
    "30days"
    "12m"
    "-1"
    "abc"
    "1 "
  ];
  # Refused by the type only (the binary fails later, or differently).
  retentionTypeOnlyRejected = [
    ""
    "d"
  ];
  sizeAccepted = [
    "500"
    "10GB"
    "10GiB"
    "1.5GB"
    "5TiB"
    "1KB"
    "2MiB"
  ];
  sizeRejected = [
    "10G"
    "10 GB"
    "10GiBB"
    "1B"
    "abc"
  ];
  sizeTypeOnlyRejected = [
    "-5"
    ""
  ];

  # Shared across the hardening/readiness/manageTmpfiles checks below --
  # one evalModules pass per service is enough to introspect all of it.
  mkHardeningCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      enableModule,
      expectLimitNOFILE, # true for metrics/traces, false for logs -- matches nixpkgs' own asymmetry
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith enableModule;
        sc = evaluated.config.systemd.services.${serviceName}.serviceConfig;
        postStart = evaluated.config.systemd.services.${serviceName}.postStart or "";
        hardeningChecks = {
          "full hardening profile (differs in: ${builtins.toJSON (testLib.hardeningDiff sc)})" =
            testLib.hardeningDiff sc == [ ];
          "LimitNOFILE" = (sc.LimitNOFILE or null) == (if expectLimitNOFILE then 1048576 else null);
          "wait4x readiness (not a hand-rolled curl loop)" = lib.hasInfix "wait4x" postStart;
          # Orders the unit after the dataDir's own mount (e.g. a ZFS
          # dataset) -- a no-op for the default path under /.
          "RequiresMountsFor dataDir" =
            (evaluated.config.systemd.services.${serviceName}.unitConfig.RequiresMountsFor or null) == toString
              evaluated.config.services.victoriaStack.${lib.removePrefix "victoria" serviceName}.dataDir;
        };
        failed = lib.filterAttrs (_: ok: !ok) hardeningChecks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw ''
          ${serviceName}'s serviceConfig is missing expected hardening/readiness:
          ${builtins.toJSON (builtins.attrNames failed)}
        ''
    );

  # Covers the wildcard forms 0.0.0.0, [::] and a bare ":<port>" (no host);
  # the readiness probe must substitute loopback for each (isWildcard in
  # nixosModule/victoriaStack/listen.nix). A bare ":<port>" probed as-is was
  # a non-deterministic flake: wait4x succeeded 5/5 in one run, then timed
  # out 20/20 in the next (IPv6-vs-IPv4 getaddrinfo() ordering).
  mkWildcardReadinessCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      serviceAttr, # "metrics" | "logs" | "traces"
    }:
    pkgs.runCommand name { } (
      let
        ipv4 = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = "0.0.0.0:19998";
          };
        };
        ipv6 = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = "[::]:19998";
          };
        };
        bare = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            listenAddress = ":19998";
          };
        };
        postStart = evaluated: evaluated.config.systemd.services.${serviceName}.postStart;
        checks = {
          "IPv4 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart ipv4);
          "IPv6 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart ipv6);
          "bare :port substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (postStart bare);
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s wildcard-listenAddress readiness substitution broken: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraFlags, and a listenAddress override all reaching ExecStart /
  # effectiveUrl correctly. One shared check applied per service rather
  # than 3x near-identical hand-written tests.
  mkExecStartOptionsCheck =
    {
      name,
      serviceName, # "victoriametrics" | "victorialogs" | "victoriatraces"
      serviceAttr, # "metrics" | "logs" | "traces"
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            retentionPeriod = "30d";
            extraFlags = [ "-search.maxUniqueTimeseries=300000" ];
            listenAddress = "127.0.0.1:19999";
          };
        };
        execStart = evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStart;
        effectiveUrl = evaluated.config.services.victoriaStack.${serviceAttr}.effectiveUrl;
        checks = {
          "retentionPeriod flag present" = lib.hasInfix "-retentionPeriod=30d" execStart;
          "extraFlags flag present" = lib.hasInfix "-search.maxUniqueTimeseries=300000" execStart;
          "listenAddress override reaches ExecStart" =
            lib.hasInfix "-httpListenAddr=127.0.0.1:19999" execStart;
          "listenAddress override reaches effectiveUrl" = effectiveUrl == "http://127.0.0.1:19999";
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s ExecStart is missing: ${builtins.toJSON (builtins.attrNames failed)}\n${execStart}"
    );

  # Shared across all 3 storage services -- previously only metrics had
  # this coverage, even though manageTmpfiles/the tmpfiles-rule code path
  # is identical (copy-pasted) across metrics.nix/logs.nix/traces.nix.
  mkManageTmpfilesCheck =
    {
      name,
      serviceAttr, # "metrics" | "logs" | "traces"
      dataDir ? null, # null: leave dataDir at its default
      expectRule, # true: default (manageTmpfiles unset) should render a rule;
      # false: manageTmpfiles = false should suppress it entirely
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            dynamicUser = false;
          }
          // lib.optionalAttrs (dataDir != null) { inherit dataDir; }
          // lib.optionalAttrs (!expectRule) { manageTmpfiles = false; };
        };
        rules = evaluated.config.systemd.tmpfiles.rules;
        effectiveDir = toString evaluated.config.services.victoriaStack.${serviceAttr}.dataDir;
        hasRule = lib.any (lib.hasInfix effectiveDir) rules;
      in
      if hasRule == expectRule then
        "echo OK > $out"
      else if expectRule then
        throw "manageTmpfiles defaults to true -- expected a tmpfiles rule for ${effectiveDir}"
      else
        throw "manageTmpfiles = false must suppress the every-boot tmpfiles ownership rule entirely for ${effectiveDir}"
    );
  mkRetentionDocCheck =
    {
      name,
      serviceAttr,
      binary,
      docClaim, # the default as the option description words it
      helpDefault, # the same default as the binary's -help prints it
    }:
    let
      description =
        (evalWith { }).options.services.victoriaStack.${serviceAttr}.retentionPeriod.description;
    in
    if
      lib.hasInfix docClaim description
      && !lib.hasInfix "effectively unbounded for this binary" description
    then
      pkgs.runCommand name { } ''
        ${binary} -help 2>&1 | grep -F -- "(default ${helpDefault})" > /dev/null || {
          echo "${binary} -help does not name the default ${helpDefault} for -retentionPeriod" >&2
          exit 1
        }
        echo OK > $out
      ''
    else
      throw ''
        ${serviceAttr}.retentionPeriod's description must state the real
        upstream default (${docClaim}), not claim it's unbounded. Actual
        description: ${description}
      '';

in
{
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

  # Permanent regression guard for docs/decisions/0017's sequential
  # renumbering -- catches an accidental revert/drift back to any
  # individual binary's own upstream default, or vmauth/mcp's old
  # project-chosen numbers.
  port-defaults-match-the-sequential-scheme =
    pkgs.runCommand "port-defaults-match-sequential-scheme" { }
      (
        let
          evaluated = evalWith { };
          c = evaluated.config.services.victoriaStack;
          expected = {
            "metrics.listenAddress" = c.metrics.listenAddress == "127.0.0.1:4201";
            "logs.listenAddress" = c.logs.listenAddress == "127.0.0.1:4202";
            "traces.listenAddress" = c.traces.listenAddress == "127.0.0.1:4203";
            "vmauth.listenAddress" = c.vmauth.listenAddress == "127.0.0.1:4204";
            "metrics.mcp.listenAddress" = c.metrics.mcp.listenAddress == "127.0.0.1:4205";
            "logs.mcp.listenAddress" = c.logs.mcp.listenAddress == "127.0.0.1:4206";
            "traces.mcp.listenAddress" = c.traces.mcp.listenAddress == "127.0.0.1:4207";
          };
          failed = lib.filterAttrs (_: ok: !ok) expected;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "port defaults drifted from docs/decisions/0017's sequential scheme: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # docs/decisions/0019's structural seam: consumers (vmauth, Grafana)
  # must read effectiveUrl, never listenAddress directly -- this is the
  # one place a future remoteUrl feature would need to override.
  effective-url-is-internal-and-derived-from-listen-address =
    pkgs.runCommand "effective-url-is-internal-and-derived" { }
      (
        let
          evaluated = evalWith { services.victoriaStack.metrics.enable = true; };
          opt = evaluated.options.services.victoriaStack.metrics.effectiveUrl;
          checks = {
            "marked internal (excluded from generated docs)" = opt.internal or false;
            "derived from listenAddress by default" =
              evaluated.config.services.victoriaStack.metrics.effectiveUrl == "http://127.0.0.1:4201";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "effectiveUrl structural seam broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  metrics-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "metrics-wildcard-readiness-substitutes-loopback";
    serviceName = "victoriametrics";
    serviceAttr = "metrics";
  };

  logs-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "logs-wildcard-readiness-substitutes-loopback";
    serviceName = "victorialogs";
    serviceAttr = "logs";
  };

  traces-wildcard-readiness-substitutes-loopback = mkWildcardReadinessCheck {
    name = "traces-wildcard-readiness-substitutes-loopback";
    serviceName = "victoriatraces";
    serviceAttr = "traces";
  };

  # Previously untested for all 3 storage services: retentionPeriod,
  # extraFlags, and a listenAddress override all reaching ExecStart /
  # effectiveUrl correctly. One shared check applied per service rather
  # than 3x near-identical hand-written tests.
  metrics-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "metrics-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victoriametrics";
    serviceAttr = "metrics";
  };

  logs-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "logs-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victorialogs";
    serviceAttr = "logs";
  };

  traces-retention-extraoptions-listenaddress-reach-execstart = mkExecStartOptionsCheck {
    name = "traces-retention-extraoptions-listenaddress-reach-execstart";
    serviceName = "victoriatraces";
    serviceAttr = "traces";
  };

  metrics-hardening-profile-and-readiness = mkHardeningCheck {
    name = "metrics-hardening-profile-and-readiness";
    serviceName = "victoriametrics";
    enableModule = {
      services.victoriaStack.metrics.enable = true;
    };
    expectLimitNOFILE = true; # same as nixpkgs' own victoriametrics module
  };

  metrics-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "metrics";
    dataDir = "/data/victoria/metrics";
    expectRule = true;
  };

  metrics-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-false-rule-absent";
    serviceAttr = "metrics";
    dataDir = "/data/victoria/metrics";
    expectRule = false;
  };

  logs-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "logs";
    dataDir = "/data/victoria/logs";
    expectRule = true;
  };

  logs-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-false-rule-absent";
    serviceAttr = "logs";
    dataDir = "/data/victoria/logs";
    expectRule = false;
  };

  traces-manage-tmpfiles-default-true-rule-present = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-default-true-rule-present";
    serviceAttr = "traces";
    dataDir = "/data/victoria/traces";
    expectRule = true;
  };

  traces-manage-tmpfiles-false-rule-absent = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-false-rule-absent";
    serviceAttr = "traces";
    dataDir = "/data/victoria/traces";
    expectRule = false;
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
      machine.wait_for_open_port(4201)

      # Prometheus exposition-format ingest -- the simplest real write path
      # VictoriaMetrics' own HTTP API supports natively, no extra tooling
      # needed beyond curl.
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_test_metric{label=\"roundtrip\"} 42' "
          "'http://127.0.0.1:4201/api/v1/import/prometheus'"
      )

      # VictoriaMetrics ingestion is not synchronous-to-query -- give it a
      # moment before asserting the value is queryable.
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_test_metric' "
          "| grep -q '\"value\":\\[.*,\"42\"\\]'"
      )

      # The data directory systemd creates for a DynamicUser must not be
      # readable by other local users (StateDirectoryMode); -L follows the
      # /var/lib/<name> symlink into /var/lib/private.
      mode = machine.succeed("stat -L -c %a /var/lib/victoriametrics").strip()
      assert mode == "700", f"expected the state directory to be 0700, got {mode!r}"
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
      machine.wait_for_open_port(4201)

      # Confirm it's genuinely running as the static user, not DynamicUser,
      # and that the custom dataDir is real and owned correctly -- the
      # whole point of this option combination (docs/decisions/0001).
      user = machine.succeed(
          "systemctl show victoriametrics.service --property=User --value"
      ).strip()
      assert user == "victoriametrics", f"expected static User=victoriametrics, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/metrics").strip()
      assert owner == "victoriametrics", f"expected /data/victoria/metrics owned by victoriametrics, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/metrics").strip()
      assert group == "victoriametrics", f"expected /data/victoria/metrics group-owned by victoriametrics, got {group!r}"
      # The tmpfiles rule keeps the data readable by the owner and its group only.
      mode = machine.succeed("stat -c %a /data/victoria/metrics").strip()
      assert mode == "750", f"expected /data/victoria/metrics to be 0750, got {mode!r}"

      # User+ownership alone doesn't prove the service can actually write
      # to and read from that directory -- a real ingest/query roundtrip
      # against the static-user + custom-dataDir combination specifically
      # (the default-dynamicUser combination already has its own
      # roundtrip test above; this confirms the same path isn't broken
      # by the static-user/custom-dataDir option combination).
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_static_user_test_metric{label=\"roundtrip\"} 7' "
          "'http://127.0.0.1:4201/api/v1/import/prometheus'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_static_user_test_metric' "
          "| grep -q victoria_stack_static_user_test_metric"
      )
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

  # --- logs (same pattern as metrics above) ---

  logs-dynamic-user-warning-fires-on-custom-data-dir = mkWarningFiresCheck {
    name = "logs-dynamic-user-warning-fires-on-custom-data-dir";
    expectMessageSubstring = "dynamicUser";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
      };
    };
  };

  logs-dynamic-user-warning-suppressible = mkNoWarningsCheck {
    name = "logs-dynamic-user-warning-suppressible";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        suppressDynamicUserWarning = true;
      };
    };
  };

  logs-default-data-dir-no-warning = mkNoWarningsCheck {
    name = "logs-default-data-dir-no-warning";
    module = {
      services.victoriaStack.logs.enable = true;
    };
  };

  logs-static-user-custom-data-dir-no-warning = mkNoWarningsCheck {
    name = "logs-static-user-custom-data-dir-no-warning";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        dynamicUser = false;
      };
    };
  };

  logs-hardening-profile-and-readiness = mkHardeningCheck {
    name = "logs-hardening-profile-and-readiness";
    serviceName = "victorialogs";
    enableModule = {
      services.victoriaStack.logs.enable = true;
    };
    expectLimitNOFILE = false; # matches nixpkgs' own victorialogs module (no LimitNOFILE set)
  };

  logs-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)

      # JSON stream (ndjson) ingest -- VictoriaLogs' own HTTP API
      # (/insert/jsonline), confirmed from its real data-ingestion docs
      # rather than assumed to mirror VictoriaMetrics' API shape.
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_test_log_roundtrip\"}" 
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=victoria_stack_test_log_roundtrip' "
          "| grep -q victoria_stack_test_log_roundtrip"
      )
    '';
  };

  logs-static-user-custom-data-dir = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-static-user-custom-data-dir";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)

      user = machine.succeed(
          "systemctl show victorialogs.service --property=User --value"
      ).strip()
      assert user == "victorialogs", f"expected static User=victorialogs, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/logs").strip()
      assert owner == "victorialogs", f"expected /data/victoria/logs owned by victorialogs, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/logs").strip()
      assert group == "victorialogs", f"expected /data/victoria/logs group-owned by victorialogs, got {group!r}"

      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_static_user_test_log\"}" 
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=victoria_stack_static_user_test_log' "
          "| grep -q victoria_stack_static_user_test_log"
      )
    '';
  };

  logs-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victorialogs-override-marker";
        paths = [ pkgs.victorialogs ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-logs-package-override-takes-effect";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack.logs = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("victorialogs.service")
        exec_start = machine.succeed(
            "systemctl show victorialogs.service --property=ExecStart --value"
        )
        assert "${overridePackage}" in exec_start, (
            f"expected ExecStart to resolve through the overridden package "
            f"(${overridePackage}), got: {exec_start!r}"
        )
      '';
    };

  # --- traces (same pattern again) ---

  traces-dynamic-user-warning-fires-on-custom-data-dir = mkWarningFiresCheck {
    name = "traces-dynamic-user-warning-fires-on-custom-data-dir";
    expectMessageSubstring = "dynamicUser";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
      };
    };
  };

  traces-dynamic-user-warning-suppressible = mkNoWarningsCheck {
    name = "traces-dynamic-user-warning-suppressible";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        suppressDynamicUserWarning = true;
      };
    };
  };

  traces-default-data-dir-no-warning = mkNoWarningsCheck {
    name = "traces-default-data-dir-no-warning";
    module = {
      services.victoriaStack.traces.enable = true;
    };
  };

  traces-static-user-custom-data-dir-no-warning = mkNoWarningsCheck {
    name = "traces-static-user-custom-data-dir-no-warning";
    module = {
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        dynamicUser = false;
      };
    };
  };

  traces-hardening-profile-and-readiness = mkHardeningCheck {
    name = "traces-hardening-profile-and-readiness";
    serviceName = "victoriatraces";
    enableModule = {
      services.victoriaStack.traces.enable = true;
    };
    expectLimitNOFILE = true; # same as nixpkgs' own victoriatraces module
  };

  # The option description states the binary's real default retention (the
  # claim "effectively unbounded" was once wrong for all three). The claim is
  # checked against the binary itself: its own -help must name the same default,
  # so a package bump that changes it fails here instead of leaving the
  # description quietly stale.
  traces-retention-period-doc-states-real-7-day-default = mkRetentionDocCheck {
    name = "traces-retention-period-doc-states-real-7-day-default";
    serviceAttr = "traces";
    binary = "${pkgs.victoriatraces}/bin/victoria-traces";
    docClaim = "7 day";
    helpDefault = "7d";
  };

  metrics-retention-period-doc-states-real-1-month-default = mkRetentionDocCheck {
    name = "metrics-retention-period-doc-states-real-1-month-default";
    serviceAttr = "metrics";
    binary = "${pkgs.victoriametrics}/bin/victoria-metrics";
    docClaim = "1 month";
    helpDefault = "1M";
  };

  logs-retention-period-doc-states-real-7-day-default = mkRetentionDocCheck {
    name = "logs-retention-period-doc-states-real-7-day-default";
    serviceAttr = "logs";
    binary = "${pkgs.victorialogs}/bin/victoria-logs";
    docClaim = "7 day";
    helpDefault = "7d";
  };

  traces-ingest-query-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-ingest-query-roundtrip";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces.enable = true;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)

      # Minimal valid OTLP/HTTP JSON ExportTraceServiceRequest -- confirmed
      # from VictoriaTraces' own docs: it accepts OTLP natively and exposes
      # Jaeger Query Service JSON APIs for querying (it's built on top of
      # VictoriaLogs internally, but the ingest/query surface is OTLP in,
      # Jaeger API out, not VictoriaLogs' own LogsQL).
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000001\","
          "\"spanId\":\"0000000000000001\","
          "\"name\":\"victoria_stack_test_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_test_service"
      )
    '';
  };

  traces-static-user-custom-data-dir = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-static-user-custom-data-dir";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)

      user = machine.succeed(
          "systemctl show victoriatraces.service --property=User --value"
      ).strip()
      assert user == "victoriatraces", f"expected static User=victoriatraces, got {user!r}"

      owner = machine.succeed("stat -c %U /data/victoria/traces").strip()
      assert owner == "victoriatraces", f"expected /data/victoria/traces owned by victoriatraces, got {owner!r}"
      group = machine.succeed("stat -c %G /data/victoria/traces").strip()
      assert group == "victoriatraces", f"expected /data/victoria/traces group-owned by victoriatraces, got {group!r}"

      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_static_user_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000002\","
          "\"spanId\":\"0000000000000002\","
          "\"name\":\"victoria_stack_static_user_test_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_static_user_test_service"
      )
    '';
  };

  traces-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victoriatraces-override-marker";
        paths = [ pkgs.victoriatraces ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-traces-package-override-takes-effect";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack.traces = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("victoriatraces.service")
        exec_start = machine.succeed(
            "systemctl show victoriatraces.service --property=ExecStart --value"
        )
        assert "${overridePackage}" in exec_start, (
            f"expected ExecStart to resolve through the overridden package "
            f"(${overridePackage}), got: {exec_start!r}"
        )
      '';
    };

  # Disk-usage retention is logs/traces only -- victoria-metrics has no
  # such flag (its own `-help`).
  disk-usage-retention-reaches-execstart-for-logs-and-traces =
    pkgs.runCommand "disk-usage-retention" { }
      (
        let
          execStart =
            svc: unit: extra:
            (evalWith {
              services.victoriaStack.${svc} = {
                enable = true;
              }
              // extra;
            }).config.systemd.services.${unit}.serviceConfig.ExecStart;
          perService =
            svc: unit:
            let
              unset = execStart svc unit { };
              bytes = execStart svc unit { retentionMaxDiskSpaceUsageBytes = "500GB"; };
              percent = execStart svc unit { retentionMaxDiskUsagePercent = 80; };
            in
            {
              "${svc}: absent by default" = !(lib.hasInfix "retention.maxDisk" unset);
              "${svc}: bytes flag" = lib.hasInfix "-retention.maxDiskSpaceUsageBytes=500GB" bytes;
              "${svc}: percent flag" = lib.hasInfix "-retention.maxDiskUsagePercent=80" percent;
            };
          checks =
            perService "logs" "victorialogs"
            // perService "traces" "victoriatraces"
            // {
              "not offered on metrics" =
                !((evalWith { }).options.services.victoriaStack.metrics ? retentionMaxDiskSpaceUsageBytes);
            };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "disk-usage retention wiring broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  disk-usage-retention-bytes-and-percent-are-mutually-exclusive =
    pkgs.runCommand "disk-usage-retention-mutually-exclusive" { }
      (
        let
          firesWith =
            svc: limits:
            lib.any
              (
                m: lib.hasInfix "retentionMaxDiskSpaceUsageBytes" m && lib.hasInfix "retentionMaxDiskUsagePercent" m
              )
              (
                map (a: a.message) (
                  builtins.filter (a: !a.assertion)
                    (evalWith {
                      services.victoriaStack.${svc} = {
                        enable = true;
                      }
                      // limits;
                    }).config.assertions
                )
              );
          both = {
            retentionMaxDiskSpaceUsageBytes = "500GB";
            retentionMaxDiskUsagePercent = 80;
          };
          fires = svc: firesWith svc both;
          # Either limit on its own is the normal use and must stay quiet.
          quietAlone =
            svc:
            !(firesWith svc { retentionMaxDiskSpaceUsageBytes = "500GB"; })
            && !(firesWith svc { retentionMaxDiskUsagePercent = 80; })
            && !(firesWith svc { });
        in
        if fires "logs" && fires "traces" && quietAlone "logs" && quietAlone "traces" then
          "echo OK > $out"
        else
          throw "mutual-exclusion assertion wrong (fires on both: logs=${builtins.toJSON (fires "logs")} traces=${builtins.toJSON (fires "traces")}; quiet with one: logs=${builtins.toJSON (quietAlone "logs")} traces=${builtins.toJSON (quietAlone "traces")})"
      );

  metrics-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "metrics-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "metrics";
    expectRule = false;
  };

  logs-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "logs-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "logs";
    expectRule = false;
  };

  traces-manage-tmpfiles-false-rule-absent-at-default-data-dir = mkManageTmpfilesCheck {
    name = "traces-manage-tmpfiles-false-rule-absent-at-default-data-dir";
    serviceAttr = "traces";
    expectRule = false;
  };

  # extraOptions was renamed to extraFlags (docs/decisions/0024): the old
  # name must keep working, produce the standard rename warning, and
  # render the identical ExecStart as the new name.
  extra-options-old-name-still-works-and-warns =
    pkgs.runCommand "extra-options-old-name-still-works-and-warns" { }
      (
        let
          flag = "-search.maxUniqueTimeseries=300000";
          perService =
            attr: unit:
            let
              viaOld = evalWith {
                services.victoriaStack.${attr} = {
                  enable = true;
                  extraOptions = [ flag ];
                };
              };
              viaNew = evalWith {
                services.victoriaStack.${attr} = {
                  enable = true;
                  extraFlags = [ flag ];
                };
              };
              execStart = e: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
              warned = lib.any (lib.hasInfix "${attr}.extraOptions") (
                lib.filter (lib.hasInfix "services.victoriaStack") viaOld.config.warnings
              );
            in
            {
              "${attr}: old name warns" = warned;
              "${attr}: same ExecStart as the new name" = execStart viaOld == execStart viaNew;
              "${attr}: flag reaches ExecStart" = lib.hasInfix flag (execStart viaOld);
            };
          checks =
            perService "metrics" "victoriametrics"
            // perService "logs" "victorialogs"
            // perService "traces" "victoriatraces";
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraOptions rename broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # --- snapshots (periodic creation + binary-native pruning) ---
  #
  # The snapshot API genuinely differs per binary (confirmed by probing
  # each one): VictoriaMetrics serves /snapshot/{create,list};
  # VictoriaLogs and VictoriaTraces reject those and serve
  # /internal/partition/snapshot/{create,list} instead. -snapshotsMaxAge
  # exists on all three. The partition-snapshot endpoints are POST-only
  # (VictoriaLogs answers a GET with "Only POST method is allowed").

  snapshots-eval-behaviour-for-all-three-services = pkgs.runCommand "snapshots-eval-behaviour" { } (
    let
      perService =
        attr: unit:
        let
          eval =
            snap:
            evalWith {
              services.victoriaStack.${attr} = {
                enable = true;
                snapshots = snap;
              };
            };
          execStart = e: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
          hasUnits =
            e: e.config.systemd.timers ? "${unit}-snapshot" && e.config.systemd.services ? "${unit}-snapshot";
          off = eval { };
          on = eval { enable = true; };
          noPrune = eval {
            enable = true;
            maxAge = null;
          };
          custom = eval {
            enable = true;
            schedule = "hourly";
            maxAge = "7d";
          };
          snapSvc = on.config.systemd.services."${unit}-snapshot";
          snapExec = snapSvc.serviceConfig.ExecStart;
        in
        {
          "${attr}: disabled by default -> no timer/service" = !(hasUnits off);
          "${attr}: disabled -> no -snapshotsMaxAge" = !(lib.hasInfix "snapshotsMaxAge" (execStart off));
          "${attr}: enabled -> timer and service exist" = hasUnits on;
          "${attr}: enabled -> default maxAge 30d" = lib.hasInfix "-snapshotsMaxAge=30d" (execStart on);
          "${attr}: default schedule is daily" =
            on.config.systemd.timers."${unit}-snapshot".timerConfig.OnCalendar == "daily";
          # null must DISABLE pruning: omitting the flag would leave the binaries'
          # own 3d default in force (confirmed from each binary's -help), so a
          # snapshot an operator meant to keep would be deleted.
          "${attr}: maxAge = null -> -snapshotsMaxAge=0 and the creation timer remains" =
            lib.hasInfix "-snapshotsMaxAge=0" (execStart noPrune) && hasUnits noPrune;
          "${attr}: custom maxAge and schedule render" =
            lib.hasInfix "-snapshotsMaxAge=7d" (execStart custom)
            && custom.config.systemd.timers."${unit}-snapshot".timerConfig.OnCalendar == "hourly";
          # The timer is only armed at boot because timers.target pulls it in.
          "${attr}: timer is wanted by timers.target" =
            on.config.systemd.timers."${unit}-snapshot".wantedBy == [ "timers.target" ];
          # A missed run (machine off at the scheduled time) is caught up.
          "${attr}: timer is Persistent" =
            on.config.systemd.timers."${unit}-snapshot".timerConfig.Persistent == true;
          # Not started alone: a stopped backend must pull in (and order after) the real one.
          "${attr}: oneshot requires and follows the backend" =
            snapSvc.requires == [ "${unit}.service" ] && snapSvc.after == [ "${unit}.service" ];
          "${attr}: oneshot is a oneshot that fails on HTTP errors" =
            snapSvc.serviceConfig.Type == "oneshot" && lib.hasInfix " --fail " snapExec;
          # Network families only: the call is an HTTP POST over loopback, so
          # AF_UNIX and AF_NETLINK stay closed.
          "${attr}: oneshot may only open INET sockets" =
            snapSvc.serviceConfig.RestrictAddressFamilies == [
              "AF_INET"
              "AF_INET6"
            ];
        };
      checks =
        perService "metrics" "victoriametrics"
        // perService "logs" "victorialogs"
        // perService "traces" "victoriatraces";
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "snapshots eval behaviour broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # Real boot per binary: trigger the oneshot, then ask the service's OWN
  # list API (not just an exit code) and require a non-empty result.
  metrics-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        snapshots.enable = true;
      };
      environment.systemPackages = [ pkgs.python3 ];
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_open_port(4201)
      import json

      machine.succeed("systemctl start victoriametrics-snapshot.service")
      listed = json.loads(machine.succeed("curl -sf http://127.0.0.1:4201/snapshot/list"))
      assert listed["snapshots"], f"expected a snapshot, got {listed!r}"

      # The schedule is really armed: enabled at boot and counting down.
      machine.succeed("systemctl is-enabled victoriametrics-snapshot.timer")
      machine.succeed("systemctl is-active victoriametrics-snapshot.timer")
      timers = machine.succeed("systemctl list-timers --no-pager")
      assert "victoriametrics-snapshot.timer" in timers, timers

      # An HTTP error from the backend must fail the unit, not just a refused
      # connection: swap the backend for a server that answers every POST
      # with 501 (and skip the Requires= that would restart the real one).
      machine.succeed("systemctl stop victoriametrics.service")
      machine.succeed(
          "systemd-run --unit=fake-backend "
          "${pkgs.python3}/bin/python3 -m http.server 4201 --bind 127.0.0.1 --directory /tmp"
      )
      machine.wait_for_open_port(4201)
      machine.fail("systemctl start --job-mode=ignore-dependencies victoriametrics-snapshot.service")
      machine.succeed("systemctl is-failed victoriametrics-snapshot.service")
      journal = machine.succeed("journalctl -u victoriametrics-snapshot.service --no-pager")
      assert "501" in journal, journal
    '';
  };

  logs-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_open_port(4202)
      # A partition only exists once there is data in it.
      machine.succeed(
          "echo '{\"log\":{\"message\":\"snapshot_test_line\"},\"date\":\"0\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' -d 'query=snapshot_test_line' | grep -q snapshot_test_line"
      )
      import json

      machine.succeed("systemctl start victorialogs-snapshot.service")
      status, listed = machine.execute("curl -sS -X POST http://127.0.0.1:4202/internal/partition/snapshot/list")
      assert status == 0, f"snapshot list failed: {listed!r}"
      assert listed.lstrip().startswith("["), f"snapshot list was not a JSON list: {listed!r}"
      assert json.loads(listed), f"expected at least one snapshot, got {listed!r}"
    '';
  };

  traces-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-traces-snapshot";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.traces = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4203)
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"snapshot_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000008\","
          "\"spanId\":\"0000000000000008\","
          "\"name\":\"snapshot_test_span\",\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4203/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' | grep -q snapshot_test_service"
      )
      import json

      machine.succeed("systemctl start victoriatraces-snapshot.service")
      status, listed = machine.execute("curl -sS -X POST http://127.0.0.1:4203/internal/partition/snapshot/list")
      assert status == 0, f"snapshot list failed: {listed!r}"
      assert listed.lstrip().startswith("["), f"snapshot list was not a JSON list: {listed!r}"
      assert json.loads(listed), f"expected at least one snapshot, got {listed!r}"
    '';
  };

  # --- selfMonitoring: each service pushes its own /metrics page into the
  # local metrics database (docs/decisions/0026). A native flag family
  # (-pushmetrics.*) on all four binaries, so no timer/unit is involved.

  self-monitoring-flags-for-all-four-services = pkgs.runCommand "self-monitoring-flags" { } (
    let
      eval = m: evalWith { services.victoriaStack = m; };
      execStart = e: unit: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
      allBackends = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
      };
      # On by default whenever the metrics database is enabled.
      byDefault = eval allBackends;
      explicitlyOff = eval (
        lib.recursiveUpdate allBackends {
          metrics.selfMonitoring.enable = false;
          logs.selfMonitoring.enable = false;
          traces.selfMonitoring.enable = false;
          vmauth.selfMonitoring.enable = false;
        }
      );
      custom = eval (lib.recursiveUpdate allBackends { logs.selfMonitoring.interval = "1m"; });
      oneOff = eval (lib.recursiveUpdate allBackends { logs.selfMonitoring.enable = false; });
      # No metrics database on this host: nothing to push to, so off.
      noMetricsDb = eval {
        logs.enable = true;
        traces.enable = true;
      };
      url = "-pushmetrics.url=http://127.0.0.1:4201/api/v1/import/prometheus";
      perUnit = unit: job: {
        "${unit}: on by default when the metrics database is enabled" = lib.hasInfix url (
          execStart byDefault unit
        );
        "${unit}: default interval 30s" = lib.hasInfix "-pushmetrics.interval=30s" (
          execStart byDefault unit
        );
        "${unit}: labelled with its own job" = lib.hasInfix "'-pushmetrics.extraLabel=job=\"${job}\"'" (
          execStart byDefault unit
        );
        "${unit}: explicit false turns it off" =
          !(lib.hasInfix "pushmetrics" (execStart explicitlyOff unit));
      };
      checks =
        perUnit "victoriametrics" "victoriametrics"
        // perUnit "victorialogs" "victorialogs"
        // perUnit "victoriatraces" "victoriatraces"
        // perUnit "vmauth" "vmauth"
        // {
          "custom interval renders" = lib.hasInfix "-pushmetrics.interval=1m" (
            execStart custom "victorialogs"
          );
          "turning one service off leaves the others on" =
            !(lib.hasInfix "pushmetrics" (execStart oneOff "victorialogs"))
            && lib.hasInfix url (execStart oneOff "victoriatraces");
          "no metrics database -> off, and no assertion fires" =
            !(lib.hasInfix "pushmetrics" (execStart noMetricsDb "victorialogs"))
            && !(lib.hasInfix "pushmetrics" (execStart noMetricsDb "vmauth"))
            &&
              lib.filter (lib.hasInfix "selfMonitoring") (
                map (a: a.message) (builtins.filter (a: !a.assertion) noMetricsDb.config.assertions)
              ) == [ ];
        };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "selfMonitoring flags broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  self-monitoring-needs-the-metrics-database = pkgs.runCommand "self-monitoring-needs-metrics" { } (
    let
      failedFor =
        m:
        lib.filter (lib.hasInfix "selfMonitoring") (
          map (a: a.message) (
            builtins.filter (a: !a.assertion)
              (evalWith {
                services.victoriaStack = m;
              }).config.assertions
          )
        );
      checks = {
        "logs without metrics fires" =
          failedFor {
            logs = {
              enable = true;
              selfMonitoring.enable = true;
            };
          } != [ ];
        "vmauth without metrics fires" =
          failedFor {
            traces.enable = true;
            vmauth.selfMonitoring.enable = true;
          } != [ ];
        "with metrics enabled it does not fire" =
          failedFor {
            metrics.enable = true;
            logs = {
              enable = true;
              selfMonitoring.enable = true;
            };
          } == [ ];
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "selfMonitoring assertion broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # For real: all four push, and each one's series shows up in the metrics
  # database under its own job label.
  self-monitoring-series-really-arrive = pkgs.testers.nixosTest {
    name = "victoria-stack-self-monitoring";

    # selfMonitoring.enable is deliberately NOT set anywhere: it is on by
    # default because the metrics database is enabled. Only the interval is
    # shortened so the test doesn't wait 30s.
    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        logs = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        traces = {
          enable = true;
          selfMonitoring.interval = "5s";
        };
        vmauth.selfMonitoring.interval = "5s";
      };
    };

    testScript = ''
      start_all()
      for unit in ["victoriametrics", "victorialogs", "victoriatraces", "vmauth"]:
          machine.wait_for_unit(f"{unit}.service")
      machine.wait_for_open_port(4201)

      for job in ["victoriametrics", "victorialogs", "victoriatraces", "vmauth"]:
          machine.wait_until_succeeds(
              "curl -sfG 'http://127.0.0.1:4201/api/v1/query' "
              f"--data-urlencode 'query=count({{job=\"{job}\"}})' | grep -q '\"value\"'",
              timeout=120,
          )
    '';
  };

  # selfMonitoring is on by default, so an operator who already pushes
  # metrics with their own -pushmetrics.* flags would silently get both.
  self-monitoring-conflicting-extra-flags-warn-for-every-service =
    pkgs.runCommand "self-monitoring-conflict-warns" { }
      (
        let
          warningsFor =
            m:
            lib.filter (lib.hasInfix "selfMonitoring") (
              (evalWith {
                services.victoriaStack = m;
              }).config.warnings
            );
          flag = [ "-pushmetrics.url=http://example.invalid/push" ];
          warns =
            svc: extra:
            lib.any (lib.hasInfix "services.victoriaStack.${svc}") (
              warningsFor ({ metrics.enable = true; } // extra)
            );
          checks = {
            "metrics.extraFlags" = warns "metrics" {
              metrics = {
                enable = true;
                extraFlags = flag;
              };
            };
            "logs.extraFlags" = warns "logs" {
              logs = {
                enable = true;
                extraFlags = flag;
              };
            };
            "traces.extraFlags" = warns "traces" {
              traces = {
                enable = true;
                extraFlags = flag;
              };
            };
            "vmauth.extraFlags" = warns "vmauth" { vmauth.extraFlags = flag; };
            # The whole -pushmetrics.* family doubles the push, not only the URL.
            "-pushmetrics.interval alone counts" = warns "logs" {
              logs = {
                enable = true;
                extraFlags = [ "-pushmetrics.interval=10s" ];
              };
            };
            "-pushmetrics.extraLabel alone counts" = warns "traces" {
              traces = {
                enable = true;
                extraFlags = [ "-pushmetrics.extraLabel=a=\"b\"" ];
              };
            };
            "the old extraOptions name still counts (it is renamed to extraFlags)" = warns "logs" {
              logs = {
                enable = true;
                extraOptions = flag;
              };
            };
            "no warning when the operator opted that service out" =
              warningsFor {
                metrics.enable = true;
                logs = {
                  enable = true;
                  extraFlags = flag;
                  selfMonitoring.enable = false;
                };
              } == [ ];
            "no warning for unrelated extra flags" =
              warningsFor {
                metrics = {
                  enable = true;
                  extraFlags = [ "-search.maxUniqueTimeseries=300000" ];
                };
              } == [ ];
            "no warning when the service itself is disabled" =
              warningsFor {
                metrics.enable = true;
                logs.extraFlags = flag; # logs.enable left false
              } == [ ];
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "selfMonitoring conflict warning broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # --- option validation ---

  data-dir-given-as-a-string-equal-to-the-default-does-not-warn =
    let
      warns =
        attr: dir:
        lib.any (lib.hasInfix "changed away from the default") (
          (evalWith {
            services.victoriaStack.${attr} = {
              enable = true;
              dataDir = dir;
            };
          }).config.warnings
        );
    in
    pkgs.runCommand "data-dir-string-default" { } (
      let
        checks = {
          "metrics, the default as a string" = !(warns "metrics" "/var/lib/victoriametrics");
          "logs, the default as a string" = !(warns "logs" "/var/lib/victorialogs");
          "traces, the default as a string" = !(warns "traces" "/var/lib/victoriatraces");
          "a real custom dir still warns" = warns "metrics" "/srv/vm";
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "dataDir warning wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  retention-max-disk-usage-percent-is-bounded =
    let
      opt = attr: (evalWith { }).options.services.victoriaStack.${attr}.retentionMaxDiskUsagePercent.type;
      accepts = attr: v: (opt attr).check v;
    in
    pkgs.runCommand "retention-percent-bounds" { } (
      let
        checks = lib.listToAttrs (
          lib.concatMap
            (attr: [
              (lib.nameValuePair "${attr}: 1 accepted" (accepts attr 1))
              (lib.nameValuePair "${attr}: 100 accepted" (accepts attr 100))
              (lib.nameValuePair "${attr}: 0 rejected" (!(accepts attr 0)))
              (lib.nameValuePair "${attr}: 101 rejected (VictoriaLogs dies at start with it)" (
                !(accepts attr 101)
              ))
              (lib.nameValuePair "${attr}: null still means off" (accepts attr null))
            ])
            [
              "logs"
              "traces"
            ]
        );
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "retention percent bounds wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # A slow open of a large data directory must not be killed: the readiness probe
  # used to wait exactly as long as systemd's default start timeout (90s), so the
  # two expired together and Restart=on-failure looped.
  storage-start-timeouts-leave-room-for-a-slow-open = pkgs.runCommand "storage-start-timeouts" { } (
    let
      perUnit =
        attr: unit:
        let
          sc = (evalWith { services.victoriaStack.${attr}.enable = true; }).config.systemd.services.${unit};
        in
        {
          "${unit}: readiness waits up to 5 minutes" = lib.hasInfix "--timeout 5m" sc.postStart;
          "${unit}: TimeoutStartSec is 6 minutes, above the probe" =
            sc.serviceConfig.TimeoutStartSec == "6min";
        };
      checks =
        perUnit "metrics" "victoriametrics"
        // perUnit "logs" "victorialogs"
        // perUnit "traces" "victoriatraces";
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "storage start timeouts wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # Effective ProtectSystem and capabilities (CapBnd, from the kernel) are read
  # from the running unit, not the rendered text: measured, DynamicUser units were strict even with an explicit "full";
  # only static users ran with "full".
  hardening-is-effective-on-running-units = pkgs.testers.nixosTest {
    name = "victoria-stack-hardening-effective";

    containers.dyn = {
      imports = [ module ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
          snapshots.enable = true;
        };
        logs = {
          enable = true;
          mcp.enable = true;
        };
        traces = {
          enable = true;
          mcp.enable = true;
        };
        vmauth.adminPasswordFile = "${pkgs.writeText "hardening-admin-password" "hardening-admin-password-value"}";
      };
    };

    # A static user has no implied sandbox and no StateDirectory: its data
    # directory must be explicitly writable under ProtectSystem=strict.
    containers.static = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        dynamicUser = false;
        dataDir = "/srv/vm-data";
      };
    };

    testScript = ''
      start_all()
      services = [
          "victoriametrics", "victorialogs", "victoriatraces", "vmauth",
          "mcp-victoriametrics", "mcp-victorialogs", "mcp-victoriatraces",
      ]
      for unit in services:
          dyn.wait_for_unit(f"{unit}.service")
      static.wait_for_unit("victoriametrics.service")

      problems = []

      def check_running(machine, unit):
          prop = lambda p: machine.succeed(f"systemctl show -p {p} --value {unit}.service").strip()
          if prop("ProtectSystem") != "strict":
              problems.append(f"{unit}: ProtectSystem={prop('ProtectSystem')}")
          pid = prop("MainPID")
          capbnd = machine.succeed(f"grep ^CapBnd /proc/{pid}/status").split()[1]
          if int(capbnd, 16) != 0:
              problems.append(f"{unit}: CapBnd={capbnd}")

      for unit in services:
          check_running(dyn, unit)
      check_running(static, "victoriametrics")

      # Oneshots are not running now; their loaded properties are authoritative.
      for unit in ["victoriametrics-snapshot", "vmauth-secret-restart"]:
          cap = dyn.succeed(f"systemctl show -p CapabilityBoundingSet --value {unit}.service").strip()
          if cap != "":
              problems.append(f"{unit}: CapabilityBoundingSet={cap}")

      assert not problems, "; ".join(problems)

      # The static user really writes its data under strict.
      static.succeed("test -n \"$(find /srv/vm-data -mindepth 1 -user victoriametrics | head -n1)\"")
    '';
  };

  # systemd expands specifiers (%h) and ${VAR} even inside quotes, so
  # user-supplied flag text and dataDir must reach ExecStart as %% / $$.
  # Boot proof of the same rule: execstart-specifiers-reach-process-literally.
  execstart-escapes-systemd-specifiers =
    let
      flag = "-envflag.prefix=p%h-\${HOME}";
      escaped = "-envflag.prefix=p%%h-$${HOME}";
    in
    pkgs.runCommand "execstart-escapes-systemd-specifiers" { } (
      let
        units = {
          metrics = "victoriametrics";
          logs = "victorialogs";
          traces = "victoriatraces";
        };
        results = lib.mapAttrsToList (
          attr: unit:
          let
            e = evalWith {
              services.victoriaStack.${attr} = {
                enable = true;
                extraFlags = [ flag ];
                dataDir = "/data/100%/\${x}";
              };
            };
            execStart = e.config.systemd.services.${unit}.serviceConfig.ExecStart;
            snapshotStart =
              (evalWith {
                services.victoriaStack.${attr} = {
                  enable = true;
                  snapshots.enable = true;
                  listenAddress = "127.0.0.1:1%h";
                };
              }).config.systemd.services."${unit}-snapshot".serviceConfig.ExecStart;
          in
          {
            "${attr}: extraFlags escaped" = lib.hasInfix escaped execStart;
            "${attr}: no raw %h left" = !(lib.hasInfix "p%h" execStart);
            "${attr}: dataDir escaped" = lib.hasInfix "/data/100%%/$${x}" execStart;
            "${attr}: snapshot URL escaped" = lib.hasInfix ":1%%h" snapshotStart;
          }
        ) units;
        failed = lib.filterAttrs (_: ok: !ok) (lib.foldl' lib.mergeAttrs { } results);
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "ExecStart does not escape systemd specifiers: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  execstart-specifiers-reach-process-literally = pkgs.testers.nixosTest {
    name = "victoria-stack-execstart-specifiers-literal";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        extraFlags = [ "-envflag.prefix=p%h-\${HOME}" ];
      };
      services.victoriaStack.vmauth.extraFlags = [ "-envflag.prefix=p%h-\${HOME}" ];
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_unit("vmauth.service")
      for unit in ["victoriametrics", "vmauth"]:
          pid = machine.succeed(f"systemctl show -p MainPID --value {unit}.service").strip()
          cmdline = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/cmdline")
          assert "-envflag.prefix=p%h-''${HOME}" in cmdline.splitlines(), f"{unit}: flag was expanded: {cmdline!r}"
    '';
  };

  retention-and-size-option-types =
    let
      opts = svc: (evalWith { }).options.services.victoriaStack.${svc};
      table =
        svc: opt: accepted: rejected:
        let
          t = (opts svc).${opt}.type;
        in
        map (v: {
          name = "${svc}.${opt} accepts '${v}'";
          ok = t.check v;
        }) accepted
        ++ map (v: {
          name = "${svc}.${opt} rejects '${v}'";
          ok = !(t.check v);
        }) rejected
        ++ [
          {
            name = "${svc}.${opt} still accepts null";
            ok = t.check null;
          }
        ];
      failed = lib.filter (c: !c.ok) (
        lib.concatMap
          (
            svc: table svc "retentionPeriod" retentionAccepted (retentionRejected ++ retentionTypeOnlyRejected)
          )
          [
            "metrics"
            "logs"
            "traces"
          ]
        ++
          lib.concatMap
            (
              svc: table svc "retentionMaxDiskSpaceUsageBytes" sizeAccepted (sizeRejected ++ sizeTypeOnlyRejected)
            )
            [
              "logs"
              "traces"
            ]
      );
    in
    pkgs.runCommand "retention-and-size-option-types" { } (
      if failed == [ ] then
        "echo OK > $out"
      else
        throw "option types wrong for: ${builtins.toJSON (map (c: c.name) failed)}"
    );

  # The binaries themselves: every value the type accepts must start, every
  # syntactically bad one must die in flag parsing.
  retention-and-size-grammar-matches-the-real-binaries =
    let
      probe =
        {
          svc,
          bin,
          flag,
          accepted,
          rejected,
        }:
        let
          pkg =
            (evalWith { services.victoriaStack.${svc}.enable = true; })
            .config.services.victoriaStack.${svc}.package;
        in
        ''
          probe ${pkg}/bin/${bin} ${flag} accept ${lib.escapeShellArgs accepted}
          probe ${pkg}/bin/${bin} ${flag} reject ${lib.escapeShellArgs rejected}
        '';
    in
    pkgs.runCommand "retention-and-size-grammar-matches-the-real-binaries" { } ''
      # One background job per value: an accepted value has to be seen
      # surviving a few seconds, which in series would take minutes.
      mkdir failures
      probe() {
        bin=$1 flag=$2 want=$3
        shift 3
        for v in "$@"; do
          (
            d=$(mktemp -d)
            rc=0
            out=$(timeout 3 "$bin" -storageDataPath="$d" -httpListenAddr=127.0.0.1:0 "-$flag=$v" 2>&1) || rc=$?
            # 124 = still running when the timeout hit, i.e. the flag parsed.
            if [ "$want" = accept ] && [ "$rc" -ne 124 ]; then
              echo "FAIL: $bin did not start with -$flag=$v (rc=$rc): $out" > "failures/$(mktemp -u XXXXXX)"
            elif [ "$want" = reject ] && ! echo "$out" | grep -q "invalid value"; then
              echo "FAIL: $bin parsed -$flag=$v (rc=$rc): $out" > "failures/$(mktemp -u XXXXXX)"
            fi
            rm -rf "$d"
          ) &
        done
      }
      ${lib.concatMapStrings probe [
        {
          svc = "metrics";
          bin = "victoria-metrics";
          flag = "retentionPeriod";
          accepted = retentionAccepted;
          rejected = retentionRejected;
        }
        {
          svc = "logs";
          bin = "victoria-logs";
          flag = "retentionPeriod";
          accepted = retentionAccepted;
          rejected = retentionRejected;
        }
        {
          svc = "traces";
          bin = "victoria-traces";
          flag = "retentionPeriod";
          accepted = retentionAccepted;
          rejected = retentionRejected;
        }
        {
          svc = "logs";
          bin = "victoria-logs";
          flag = "retention.maxDiskSpaceUsageBytes";
          accepted = sizeAccepted;
          rejected = sizeRejected;
        }
        {
          svc = "traces";
          bin = "victoria-traces";
          flag = "retention.maxDiskSpaceUsageBytes";
          accepted = sizeAccepted;
          rejected = sizeRejected;
        }
      ]}
      wait
      if [ -n "$(ls failures)" ]; then
        cat failures/* >&2
        exit 1
      fi
      echo OK > $out
    '';

  # snapshots.schedule stays a plain string: systemd's calendar grammar is too
  # large for a regex that would not also reject valid expressions, and an
  # eval-time type cannot call systemd-analyze. This proves what the module
  # ships (its default and a few common shapes) is valid, and that it is
  # systemd, not the type, that rejects a bad one.
  snapshots-schedule-values-are-valid-oncalendar =
    pkgs.runCommand "snapshots-schedule-values-are-valid-oncalendar"
      {
        nativeBuildInputs = [ pkgs.systemd ];
      }
      ''
        for ok in ${
          lib.escapeShellArgs [
            (evalWith { }).options.services.victoriaStack.metrics.snapshots.schedule.default
            "hourly"
            "*-*-* 03:00:00"
            "Mon *-*-* 02:30"
            "weekly"
          ]
        }; do
          systemd-analyze calendar "$ok" > /dev/null || { echo "systemd rejects '$ok'" >&2; exit 1; }
        done
        if systemd-analyze calendar "every day" > /dev/null 2>&1; then
          echo "expected systemd to reject 'every day'" >&2
          exit 1
        fi
        echo OK > $out
      '';
}
