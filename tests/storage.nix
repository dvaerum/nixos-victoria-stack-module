{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkWarningFiresCheck mkNoWarningsCheck evalWith;

  # The metrics database's package (docs/decisions/0033).
  clusterPackage = pkgs.callPackage ../packages/victoriametrics-cluster/package.nix { };

  # Option types vs the real binaries' grammars. retentionPeriod and
  # retentionMaxDiskSpaceUsageBytes must not be plain strings: "30days" would
  # evaluate cleanly and the binary die at start (`cannot parse duration "ays"`). The
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
  # snapshots.maxAge takes the same grammar, and additionally "0" (disables
  # pruning); the binaries also accept "1h", "10s" and "1ms" there.
  snapshotMaxAgeAccepted = retentionAccepted ++ [
    "0"
    "1h"
    "10s"
  ];
  snapshotMaxAgeRejected = retentionRejected ++ [
    "1 week"
    "5m"
    "1h30m"
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
        execStartPost = sc.ExecStartPost or "";
        hardeningChecks = {
          "full hardening profile (differs in: ${builtins.toJSON (testLib.hardeningDiff sc)})" =
            testLib.hardeningDiff sc == [ ];
          "LimitNOFILE" = (sc.LimitNOFILE or null) == (if expectLimitNOFILE then 1048576 else null);
          "readiness probe (not a hand-rolled curl loop)" =
            lib.hasInfix "victoria-stack-readiness" execStartPost;
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
        execStartPost =
          evaluated: evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStartPost;
        checks = {
          "IPv4 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (execStartPost ipv4);
          "IPv6 wildcard substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (execStartPost ipv6);
          "bare :port substitutes to loopback" = lib.hasInfix "127.0.0.1:19998" (execStartPost bare);
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s wildcard-listenAddress readiness substitution broken: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Shared check for all 3 storage services: retentionPeriod, extraFlags, and a
  # listenAddress override all reaching ExecStart / effectiveUrl correctly.
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

  # Shared across all 3 storage services: the manageTmpfiles/tmpfiles-rule
  # code path is identical (copy-pasted) across metrics.nix/logs.nix/traces.nix.
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

  # Real minimum of -retentionPeriod, measured on all three binaries: one day
  # (86400s). A bare number and `M` are months of ~31 days, `y` is ~365 days
  # (0.032 refused / 0.033 starts; 0.00273y refused / 0.00274y starts).
  retentionBelowMinimum = [
    "0"
    "0h"
    "1h"
    "23h"
    "86399s"
    "1h1s"
    "0.5d"
    "0.032"
    "0.032M"
    "0.00273y"
    "0.14w"
  ];
  retentionAtOrAboveMinimum = [
    "24h"
    "1d"
    "86400s"
    "1d1s"
    "30d"
    "1w"
    "12"
    "1"
    "1M"
    "0.033"
    "0.033M"
    "0.00274y"
    "0.15w"
  ];

  # Real maximum of -retentionPeriod, measured on all three binaries: the value
  # in months of 31 days (a bare number and `M` as written, 1200.5 refused;
  # every other unit as the whole months it spans, 37230d starts / 37231d is
  # "approx 1201 months") must not exceed 1200.
  retentionAboveMaximum = [
    "1201"
    "1200.5"
    "1201M"
    "1200.9M"
    "103y"
    "37231d"
    "5319w"
    "893544h"
    "3216758400s"
    "37230d1d"
    "9999999999"
    "9999999999y"
  ];
  retentionAtOrBelowMaximum = [
    "1200"
    "1200.0"
    "1200M"
    "102y"
    "37230d"
    "5318w"
    "893543h"
    "3216758399s"
    "30d"
    "1y"
    "12"
  ];

  mkShortRetentionWarningCheck =
    svc:
    pkgs.runCommand "${svc}-short-retention-warning" { } (
      let
        optionName = "services.victoriaStack.${svc}.retentionPeriod";
        warningsFor =
          retentionPeriod:
          lib.filter (lib.hasInfix optionName) (
            (evalWith {
              services.victoriaStack.${svc} = {
                enable = true;
              }
              // lib.optionalAttrs (retentionPeriod != null) { inherit retentionPeriod; };
            }).config.warnings
          );
        problems =
          lib.concatMap (
            v:
            let
              w = warningsFor v;
            in
            lib.optional
              (
                !(
                  builtins.length w == 1
                  && lib.hasInfix ''"${v}"'' (builtins.head w)
                  && lib.hasInfix "minimum" (builtins.head w)
                  && lib.hasInfix "1 day" (builtins.head w)
                )
              )
              "${v}: expected one warning naming ${optionName}, the value and the 1 day minimum, got ${builtins.toJSON w}"
          ) retentionBelowMinimum
          ++ lib.concatMap (
            v: lib.optional (warningsFor v != [ ]) "${v}: must not warn, got ${builtins.toJSON (warningsFor v)}"
          ) (retentionAtOrAboveMinimum ++ [ null ])
          ++ lib.optional (
            !lib.hasInfix "1 day" (
              (evalWith { }).options.services.victoriaStack.${svc}.retentionPeriod.description
            )
          ) "option description does not state the 1 day minimum";
      in
      if problems == [ ] then "echo OK > $out" else throw (lib.concatStringsSep "\n" problems)
    );

  mkLongRetentionWarningCheck =
    svc:
    pkgs.runCommand "${svc}-long-retention-warning" { } (
      let
        optionName = "services.victoriaStack.${svc}.retentionPeriod";
        warningsFor =
          retentionPeriod:
          lib.filter (lib.hasInfix optionName) (
            (evalWith {
              services.victoriaStack.${svc} = {
                enable = true;
                inherit retentionPeriod;
              };
            }).config.warnings
          );
        problems =
          lib.concatMap (
            v:
            let
              w = warningsFor v;
            in
            lib.optional
              (
                !(
                  builtins.length w == 1
                  && lib.hasInfix ''"${v}"'' (builtins.head w)
                  && lib.hasInfix "1200 months" (builtins.head w)
                )
              )
              "${v}: expected one warning naming ${optionName}, the value and the 1200 months limit, got ${builtins.toJSON w}"
          ) retentionAboveMaximum
          ++ lib.concatMap (
            v: lib.optional (warningsFor v != [ ]) "${v}: must not warn, got ${builtins.toJSON (warningsFor v)}"
          ) retentionAtOrBelowMaximum
          ++ lib.optional (
            !lib.hasInfix "1200 months" (
              (evalWith { }).options.services.victoriaStack.${svc}.retentionPeriod.description
            )
          ) "option description does not state the 1200 months limit";
      in
      if problems == [ ] then "echo OK > $out" else throw (lib.concatStringsSep "\n" problems)
    );

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
  # individual binary's own upstream default, or vmauth/mcp's
  # pre-0017 numbers.
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

  # docs/decisions/0019's structural seam: consumers (vmauth's routes and the
  # self-monitoring push) must read effectiveUrl, never listenAddress directly -- this is the
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
    serviceName = "vmselect";
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

  # Previously untested for logs/traces: retentionPeriod, extraFlags, and a
  # listenAddress override all reaching ExecStart / effectiveUrl correctly.
  # Metrics' equivalent is the exec-start table in metrics-cluster-units.nix.
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics.enable = true;
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4201)

      # Prometheus exposition-format ingest -- the simplest real write path
      # the HTTP API supports natively, no extra tooling needed beyond curl.
      # Written to vminsert, read from vmselect (tenant 0).
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_test_metric{label=\"roundtrip\"} 42' "
          "'http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus'"
      )

      # Ingestion is not synchronous-to-query -- give it a moment before
      # asserting the value is queryable.
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/select/0/prometheus/api/v1/query?query=victoria_stack_test_metric' "
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        dataDir = "/data/victoria/metrics";
        dynamicUser = false;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4201)

      # Confirm vmstorage is genuinely running as the static user, not DynamicUser,
      # and that the custom dataDir is real and owned correctly -- the
      # whole point of this option combination (docs/decisions/0001).
      user = machine.succeed(
          "systemctl show vmstorage.service --property=User --value"
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
          "'http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/select/0/prometheus/api/v1/query?query=victoria_stack_static_user_test_metric' "
          "| grep -q victoria_stack_static_user_test_metric"
      )
    '';
  };

  # docs/runbooks/dynamicuser-migration.md: the two-way switch, run through
  # switch-to-configuration (a VM, because specialisations need a full boot).
  storage-dynamicuser-switch-needs-manual-migration = pkgs.testers.nixosTest {
    name = "victoria-stack-storage-dynamicuser-switch-needs-manual-migration";

    nodes.machine =
      { lib, ... }:
      {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack.metrics.enable = true;
        specialisation.static.configuration = {
          services.victoriaStack.metrics.dynamicUser = lib.mkForce false;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      machine.start()
      for unit in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:4210/health")
      machine.wait_until_succeeds(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_migration_probe{label=\"kept\"} 42' "
          "'http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus'"
      )
      query = (
          "curl -sf 'http://127.0.0.1:4201/select/0/prometheus/api/v1/query?query=victoria_stack_migration_probe' "
          "| grep -q '\"value\":\\[.*,\"42\"\\]'"
      )
      machine.wait_until_succeeds(query)
      # Stopping flushes the in-memory samples to disk, so they survive the flip.
      machine.succeed("systemctl stop vmstorage.service")
      assert machine.succeed("test -L /var/lib/victoriametrics && readlink -f /var/lib/victoriametrics").strip() == "/var/lib/private/victoriametrics"

      # Flip dynamicUser to false and switch, without migrating.
      machine.execute(
          "/run/current-system/specialisation/static/bin/switch-to-configuration test 2>&1"
      )
      # The unit auto-restarts, so it is never steadily "failed"; wait for the
      # binary's own error instead.
      machine.wait_until_succeeds(
          "journalctl -u vmstorage.service --no-pager | grep -i 'permission denied'"
      )
      machine.fail("systemctl is-active vmstorage.service")
      # The tmpfiles rule leaves the symlink to the root-only private dir alone.
      assert machine.succeed("test -L /var/lib/victoriametrics && readlink -f /var/lib/victoriametrics").strip() == "/var/lib/private/victoriametrics"
      print(machine.succeed("journalctl -u vmstorage.service --no-pager | tail -n 15"))

      # The runbook, step for step.
      machine.succeed("systemctl stop vmstorage.service")
      machine.succeed("rm /var/lib/victoriametrics")
      machine.succeed("mv /var/lib/private/victoriametrics /var/lib/victoriametrics")
      machine.succeed("chown -R victoriametrics:victoriametrics /var/lib/victoriametrics")
      machine.succeed("systemctl reset-failed vmstorage.service")
      machine.succeed("systemctl start vmstorage.service")
      wait_active(machine, "vmstorage.service")
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:4210/health")
      user = machine.succeed("systemctl show -p User --value vmstorage.service").strip()
      assert user == "victoriametrics", f"expected the static user, got {user!r}"
      machine.wait_until_succeeds(query)

      # Rollback direction: probe what systemd does with a real directory.
      machine.succeed("systemctl stop vmstorage.service")
      machine.succeed("/run/booted-system/bin/switch-to-configuration test 2>&1")
      wait_active(machine, "vmstorage.service")
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:4210/health")
      print(machine.succeed("ls -ld /var/lib/victoriametrics /var/lib/private/victoriametrics"))
      assert machine.succeed("test -L /var/lib/victoriametrics && readlink -f /var/lib/victoriametrics").strip() == "/var/lib/private/victoriametrics"
      machine.wait_until_succeeds(query)
    '';
  };

  metrics-package-override-takes-effect =
    let
      overridePackage = pkgs.symlinkJoin {
        name = "victoriametrics-override-marker";
        paths = [ clusterPackage ];
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-metrics-package-override-takes-effect";

      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack.metrics = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        ${testLib.waitActivePython}
        start_all()
        for unit in ["vmstorage", "vminsert", "vmselect"]:
            wait_active(machine, f"{unit}.service")
            exec_start = machine.succeed(
                f"systemctl show {unit}.service --property=ExecStart --value"
            )
            assert "${overridePackage}" in exec_start, (
                f"expected {unit}'s ExecStart to resolve through the overridden package "
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.logs.enable = true;
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victorialogs.service")
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.logs = {
        enable = true;
        dataDir = "/data/victoria/logs";
        dynamicUser = false;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victorialogs.service")
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
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack.logs = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        ${testLib.waitActivePython}
        start_all()
        wait_active(machine, "victorialogs.service")
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

  # The option description states the binary's real default retention. The claim is
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
    binary = "${clusterPackage}/bin/vmstorage";
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.traces.enable = true;
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victoriatraces.service")
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.traces = {
        enable = true;
        dataDir = "/data/victoria/traces";
        dynamicUser = false;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victoriatraces.service")
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
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack.traces = {
          enable = true;
          package = overridePackage;
        };
      };

      testScript = ''
        ${testLib.waitActivePython}
        start_all()
        wait_active(machine, "victoriatraces.service")
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
            # extraFlags are the read API's (vmselect).
            perService "metrics" "vmselect"
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
  # The snapshot API genuinely differs per binary (probed on
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
          # A deliberately stopped backend (restore/copy of dataDir) must stay
          # stopped: no Requires=, ordering only, and a skip condition.
          "${attr}: oneshot follows the backend without requiring it" =
            snapSvc.requires == [ ] && snapSvc.after == [ "${unit}.service" ];
          "${attr}: oneshot skips unless the backend is active" = lib.hasInfix "is-active" (
            toString snapSvc.serviceConfig.ExecCondition
          );
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
        # The snapshot API is vmstorage's.
        perService "metrics" "vmstorage"
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        snapshots.enable = true;
      };
      environment.systemPackages = [ pkgs.python3 ];
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4210)
      import json

      machine.succeed("systemctl start vmstorage-snapshot.service")
      listed = json.loads(machine.succeed("curl -sf http://127.0.0.1:4210/snapshot/list"))
      assert listed["snapshots"], f"expected a snapshot, got {listed!r}"

      # The schedule is really armed: enabled at boot and counting down.
      machine.succeed("systemctl is-enabled vmstorage-snapshot.timer")
      machine.succeed("systemctl is-active vmstorage-snapshot.timer")
      timers = machine.succeed("systemctl list-timers --no-pager")
      assert "vmstorage-snapshot.timer" in timers, timers

      # A deliberately stopped backend stays stopped: the oneshot is skipped
      # (not failed) and does not start it.
      machine.succeed("systemctl stop vmstorage.service")
      machine.succeed("systemctl start vmstorage-snapshot.service")
      assert machine.succeed("systemctl is-active vmstorage.service || true").strip() == "inactive"
      assert machine.succeed("systemctl is-failed vmstorage-snapshot.service || true").strip() != "failed"
      assert machine.succeed("systemctl show -p Result --value vmstorage-snapshot.service").strip() == "exec-condition"

      # An HTTP error from the backend must fail the unit, not just a refused
      # connection: swap the backend for a server that answers every POST
      # with 501 (the skip condition is dropped so the oneshot reaches curl).
      machine.succeed("mkdir -p /run/systemd/system/vmstorage-snapshot.service.d")
      machine.succeed("printf '[Service]\\nExecCondition=\\n' > /run/systemd/system/vmstorage-snapshot.service.d/no-condition.conf")
      machine.succeed("systemctl daemon-reload")
      machine.succeed(
          "systemd-run --unit=fake-backend "
          "${pkgs.python3}/bin/python3 -m http.server 4210 --bind 127.0.0.1 --directory /tmp"
      )
      machine.wait_for_open_port(4210)
      machine.fail("systemctl start --job-mode=ignore-dependencies vmstorage-snapshot.service")
      machine.succeed("systemctl is-failed vmstorage-snapshot.service")
      journal = machine.succeed("journalctl -u vmstorage-snapshot.service --no-pager")
      assert "501" in journal, journal
    '';
  };

  logs-snapshot-is-really-created = pkgs.testers.nixosTest {
    name = "victoria-stack-logs-snapshot";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.logs = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victorialogs.service")
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.traces = {
        enable = true;
        snapshots.enable = true;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "victoriatraces.service")
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
      # Every process pushes to vminsert's tenant-0 import endpoint.
      url = "-pushmetrics.url=http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus";
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
        perUnit "vmstorage" "vmstorage"
        // perUnit "vminsert" "vminsert"
        // perUnit "vmselect" "vmselect"
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
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
      ${testLib.waitActivePython}
      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "victorialogs", "victoriatraces", "vmauth"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(4201)

      for job in ["vmstorage", "vminsert", "vmselect", "victorialogs", "victoriatraces", "vmauth"]:
          machine.wait_until_succeeds(
              "curl -sfG 'http://127.0.0.1:4201/select/0/prometheus/api/v1/query' "
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
            # Go's flag package takes one dash or two.
            "double-dash --pushmetrics.url counts" = warns "metrics" {
              metrics = {
                enable = true;
                extraFlags = [ "--pushmetrics.url=http://example.invalid/push" ];
              };
            };
            "double-dash --pushmetrics.interval counts" = warns "traces" {
              traces = {
                enable = true;
                extraFlags = [ "--pushmetrics.interval=10s" ];
              };
            };
            "double-dash on vmauth counts" = warns "vmauth" {
              vmauth.extraFlags = [ "--pushmetrics.url=http://example.invalid/push" ];
            };
            "a flag that only starts like it does not count" =
              warningsFor {
                metrics = {
                  enable = true;
                  extraFlags = [
                    "--pushmetricsX=1"
                    "-search.pushmetrics.x=1"
                  ];
                };
              } == [ ];
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

  # A slow open of a large data directory must not be killed: a readiness probe
  # waiting exactly as long as systemd's default start timeout (90s) would expire
  # together with it and Restart=on-failure would loop.
  storage-start-timeouts-leave-room-for-a-slow-open = pkgs.runCommand "storage-start-timeouts" { } (
    let
      perUnit =
        attr: unit:
        let
          sc = (evalWith { services.victoriaStack.${attr}.enable = true; }).config.systemd.services.${unit};
        in
        {
          "${unit}: readiness waits up to 5 minutes (300s)" = (testLib.probeAndStartSeconds sc).probe == 300;
          "${unit}: TimeoutStartSec is 6 minutes, above the probe" =
            sc.serviceConfig.TimeoutStartSec == "6min";
        };
      checks =
        perUnit "metrics" "vmstorage" // perUnit "logs" "victorialogs" // perUnit "traces" "victoriatraces";
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "storage start timeouts wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # startupTimeout is the one value behind both the probe deadline and
  # TimeoutStartSec, which stays a minute above it so systemd never kills a
  # unit before its own probe has given up.
  storage-startup-timeout-drives-probe-and-unit-timeout =
    pkgs.runCommand "storage-startup-timeout" { }
      (
        let
          perUnit =
            attr: unit: timeout: expectedStart: expectedDeadline:
            let
              sc =
                (evalWith {
                  services.victoriaStack.${attr} = {
                    enable = true;
                    startupTimeout = timeout;
                  };
                }).config.systemd.services.${unit};
            in
            {
              "${unit} ${timeout}: probe deadline ${expectedDeadline}s" =
                (testLib.readinessProbe sc).deadline == expectedDeadline;
              "${unit} ${timeout}: TimeoutStartSec ${expectedStart}" =
                sc.serviceConfig.TimeoutStartSec == expectedStart;
            };
          forEveryService =
            timeout: expectedStart: expectedDeadline:
            perUnit "metrics" "vmstorage" timeout expectedStart expectedDeadline
            // perUnit "logs" "victorialogs" timeout expectedStart expectedDeadline
            // perUnit "traces" "victoriatraces" timeout expectedStart expectedDeadline;
          checks =
            forEveryService "90s" "150s" "90"
            // forEveryService "20m" "21min" "1200"
            // forEveryService "1h30m" "91min" "5400"
            // forEveryService "1m30s" "150s" "90"
            // forEveryService "1s" "61s" "1";
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "startupTimeout does not reach the unit for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Every unit that waits for readiness renders the one shared probe as an
  # ExecStartPost (not a postStart script, whose text is a shell script and would
  # take the exec escaping wrongly), with the deadline behind TimeoutStartSec's
  # margin: the 90s constant for vmauth and the MCP servers, startupTimeout for
  # the storage services.
  readiness-probe-is-one-shared-exec-start-post-for-every-unit =
    pkgs.runCommand "readiness-probe-for-every-unit" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics = {
                enable = true;
                mcp.enable = true;
              };
              logs = {
                enable = true;
                mcp.enable = true;
              };
              traces = {
                enable = true;
                mcp.enable = true;
              };
            };
          };
          expected = {
            vmstorage = {
              kind = "http";
              target = "http://127.0.0.1:4210/health";
              deadline = "300";
              start = "6min";
            };
            vminsert = {
              kind = "http";
              target = "http://127.0.0.1:4209/health";
              deadline = "300";
              start = "6min";
            };
            vmselect = {
              kind = "http";
              target = "http://127.0.0.1:4201/health";
              deadline = "300";
              start = "6min";
            };
            victorialogs = {
              kind = "http";
              target = "http://127.0.0.1:4202/ping";
              deadline = "300";
              start = "6min";
            };
            victoriatraces = {
              kind = "http";
              target = "http://127.0.0.1:4203/ping";
              deadline = "300";
              start = "6min";
            };
            vmauth = {
              kind = "tcp";
              target = "127.0.0.1:4204";
              deadline = "90";
              start = "150s";
            };
            mcp-victoriametrics = {
              kind = "http";
              target = "http://127.0.0.1:4205/health/readiness";
              deadline = "90";
              start = "150s";
            };
            mcp-victorialogs = {
              kind = "http";
              target = "http://127.0.0.1:4206/health/readiness";
              deadline = "90";
              start = "150s";
            };
            mcp-victoriatraces = {
              kind = "http";
              target = "http://127.0.0.1:4207/health/readiness";
              deadline = "90";
              start = "150s";
            };
          };
          perUnit =
            unit: want:
            let
              svc = evaluated.config.systemd.services.${unit};
              probe = testLib.readinessProbe svc;
            in
            {
              "${unit}: a probe is rendered" = probe != null;
              "${unit}: executable is the shared script" =
                probe != null && lib.hasSuffix "/bin/victoria-stack-readiness" probe.exe;
              "${unit}: arguments" =
                probe != null
                &&
                  builtins.removeAttrs probe [ "exe" ] == {
                    unit = "${unit}.service";
                    inherit (want) kind target deadline;
                  };
              "${unit}: TimeoutStartSec margin" = svc.serviceConfig.TimeoutStartSec == want.start;
              "${unit}: no postStart script left over" = (svc.postStart or "") == "";
            };
          checks = lib.concatMapAttrs perUnit expected;
          failed = lib.filterAttrs (_: ok: !ok) checks;
          # A user-typed address reaches the probe as one quoted argument.
          bracketed =
            (evalWith {
              services.victoriaStack.metrics = {
                enable = true;
                listenAddress = "[::1]:4201";
              };
            }).config.systemd.services.vmselect.serviceConfig.ExecStartPost;
        in
        if failed == { } && lib.hasSuffix " 300 http 'http://[::1]:4201/health'" bracketed then
          "echo OK > $out"
        else
          throw "readiness probe rendering wrong for: ${builtins.toJSON (builtins.attrNames failed)} (${bracketed})"
      );

  # listenAddress is a plain string the operator types; the probe must receive it
  # as one inert argument, never as shell text: `;`, spaces, quotes, `$`, backticks
  # and the specifier `%h` all stay literal (systemd would otherwise expand `$`
  # and `%`, so those are doubled).
  readiness-probe-takes-a-hostile-listen-address-as-one-inert-argument =
    pkgs.runCommand "readiness-probe-hostile-address" { }
      (
        let
          rendered =
            (evalWith {
              services.victoriaStack.logs = {
                enable = true;
                listenAddress = "127.0.0.1:9428;touch /tmp/PWNED $(id) `id` \"q\" 'x' %h";
              };
            }).config.systemd.services.victorialogs.serviceConfig.ExecStartPost;
          expectedTail = " victorialogs.service 300 http 'http://127.0.0.1:9428;touch /tmp/PWNED $$(id) `id` \"q\" '\\''x'\\'' %%h/ping'";
        in
        if lib.hasSuffix expectedTail rendered then
          "echo OK > $out"
        else
          throw "hostile listenAddress is not one escaped argument: ${rendered}"
      );

  # The same value in a real boot: nothing it contains may run. Writable by the
  # unit's own user (its state directory) so a command that did run could leave
  # the marker; the unit itself may fail to start on the invalid address.
  readiness-probe-does-not-execute-a-hostile-listen-address = pkgs.testers.nixosTest {
    name = "victoria-stack-readiness-hostile-address";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        listenAddress = "127.0.0.1:9428;touch /var/lib/victorialogs/pwned $(touch /var/lib/victorialogs/pwned2) `touch /var/lib/victorialogs/pwned3`";
      };
      systemd.services.victorialogs.wantedBy = lib.mkForce [ ];
      # The address assertion refuses this value before any unit exists; the probe
      # must be safe on its own too, so the assertions are switched off here.
      assertions = lib.mkForce [ ];
    };

    testScript = ''
      start_all()
      machine.succeed("systemctl start --no-block victorialogs.service")
      # The probe is the part that sees the address; the start is over once the
      # unit has failed and been rescheduled.
      machine.wait_until_succeeds(
          "systemctl show -p NRestarts,ActiveState victorialogs.service "
          "| grep -qE 'NRestarts=[1-9]|ActiveState=failed'",
          timeout=60,
      )
      machine.succeed("test -d /var/lib/private/victorialogs")
      machine.fail("ls /var/lib/private/victorialogs | grep -q pwned")
    '';
  };

  # The default startupTimeout is 5m, which is the probe's 300s deadline.
  storage-startup-timeout-default-is-5m = pkgs.runCommand "storage-startup-timeout-default" { } (
    let
      checks =
        lib.concatMapAttrs
          (attr: unit: {
            "${attr}: default option value" =
              (evalWith { services.victoriaStack.${attr}.enable = true; })
              .config.services.victoriaStack.${attr}.startupTimeout == "5m";
            "${attr}: probe is the shared readiness probe on /ping with a 300s deadline" =
              let
                probe = testLib.readinessProbe (
                  (evalWith { services.victoriaStack.${attr}.enable = true; }).config.systemd.services.${unit}
                );
              in
              lib.hasSuffix "/bin/victoria-stack-readiness" probe.exe
              &&
                builtins.removeAttrs probe [ "exe" ] == {
                  unit = "${unit}.service";
                  deadline = "300";
                  kind = "http";
                  target = "http://127.0.0.1:${
                    {
                      metrics = "4210";
                      logs = "4202";
                      traces = "4203";
                    }
                    .${attr}
                  }/${if attr == "metrics" then "health" else "ping"}";
                };
          })
          {
            metrics = "vmstorage";
            logs = "victorialogs";
            traces = "victoriatraces";
          };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "startupTimeout default changed: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # The boot tests' shared snippet shortens all three probes, and a test's own
  # value still wins over it.
  storage-test-startup-timeouts-snippet-applies =
    pkgs.runCommand "storage-test-startup-timeouts" { }
      (
        let
          units = {
            metrics = "vmstorage";
            logs = "victorialogs";
            traces = "victoriatraces";
          };
          evaluated =
            extra:
            evalWith {
              imports = [ testLib.testStartupTimeouts ];
              services.victoriaStack = lib.recursiveUpdate (lib.mapAttrs (_: _: { enable = true; }) units) extra;
            };
          defaults = (evaluated { }).config.systemd.services;
          overridden = (evaluated { metrics.startupTimeout = "45s"; }).config.systemd.services.vmstorage;
          checks =
            lib.mapAttrs' (
              _: unit:
              lib.nameValuePair "${unit}: snippet gives a 2m probe and a 3min unit timeout" (
                (testLib.readinessProbe defaults.${unit}).deadline == "120"
                && defaults.${unit}.serviceConfig.TimeoutStartSec == "3min"
              )
            ) units
            // {
              "a test's own value wins" = (testLib.readinessProbe overridden).deadline == "45";
            };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "test startup-timeout snippet wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Both wait4x (Go durations) and systemd read these; wait4x takes `0s` as "no
  # timeout" (measured), which would make a broken unit hang until systemd's
  # TimeoutStartSec, and rejects `5min`.
  storage-startup-timeout-type = pkgs.runCommand "storage-startup-timeout-type" { } (
    let
      accepted = [
        "1s"
        "90s"
        "5m"
        "20m"
        "1h"
        "1h30m"
        "1m30s"
        "01m"
      ];
      rejected = [
        ""
        "0s"
        "0m"
        "0h0m"
        "90"
        "5min"
        "1.5m"
        "-5m"
        "1d"
        "300ms"
        " 5m"
        "5m "
        "m"
        "5 m"
        "1h 30m"
      ];
      table =
        svc:
        let
          t = (evalWith { }).options.services.victoriaStack.${svc}.startupTimeout.type;
        in
        map (v: lib.optional (!t.check v) "${svc}: ${builtins.toJSON v} should be accepted") accepted
        ++ map (v: lib.optional (t.check v) "${svc}: ${builtins.toJSON v} should be rejected") rejected;
      problems = lib.concatLists (
        lib.concatMap table [
          "metrics"
          "logs"
          "traces"
        ]
      );
    in
    if problems == [ ] then "echo OK > $out" else throw (lib.concatStringsSep "\n" problems)
  );

  # A broken unit must not take the whole probe (5 minutes by default) to be
  # declared failed by polling a port nobody listens on. The flag is
  # harmless but unknown to the binary, so it exits at once; the probe must end
  # with the main process, whatever startupTimeout is. Dynamic and static user
  # both, since the probe checks the main process from inside each sandbox.
  broken-storage-unit-fails-when-its-main-process-dies-not-at-the-deadline = pkgs.testers.nixosTest {
    name = "victoria-stack-broken-storage-unit";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        dynamicUser = false;
        extraFlags = [ "-noSuchFlag=1" ];
      };
      # A unit failing in a loop keeps the container's boot job pending.
      systemd.services.victorialogs.wantedBy = lib.mkForce [ ];
    };

    testScript = ''
      ${testLib.brokenUnitFailureSeconds}
      start_all()
      for unit in ["victorialogs.service"]:
          took = broken_unit_failure_seconds(machine, unit)
          print(f"{unit}: probe gave up {took:.1f}s after the start, default startupTimeout")
    '';
  };

  # A slow-but-healthy start must survive a generous startupTimeout and be cut
  # off by a short one -- the option controls the real behaviour. The package
  # override makes the main process listen only after 10s, the way a large data
  # directory delays it. The generous one runs on the option's default, so a
  # live process is also proven to be waited for, not given up on early.
  startup-timeout-decides-whether-a-slow-start-survives =
    let
      # No child process: a grandchild left in the cgroup when systemd stops
      # the unit makes the stop hang until TimeoutStopSec in these containers.
      slowLogs = pkgs.writers.writePython3Bin "victoria-logs" { flakeIgnore = [ "E501" ]; } ''
        import os
        import sys
        import time

        time.sleep(10)
        real = "${pkgs.victorialogs}/bin/victoria-logs"
        os.execv(real, [real] + sys.argv[1:])
      '';
      node = timeout: {
        imports = [ module ] ++ lib.optional (timeout != null) testLib.testStartupTimeouts;
        services.victoriaStack.logs = {
          enable = true;
          package = slowLogs;
        }
        // lib.optionalAttrs (timeout != null) { startupTimeout = timeout; };
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-startup-timeout-slow-start";

      containers.generous = node null;
      # A restart loop keeps the boot's start job pending forever and the
      # container never reports ready, so this one is started by the script.
      containers.short = {
        imports = [ (node "5s") ];
        systemd.services.victorialogs.wantedBy = lib.mkForce [ ];
      };

      testScript = ''
        ${testLib.waitActivePython}
        start_all()
        wait_active(generous, "victorialogs.service")
        generous.succeed("curl -sf http://127.0.0.1:4202/ping")
        restarts = generous.succeed("systemctl show -p NRestarts --value victorialogs.service").strip()
        assert restarts == "0", f"a live but slow start was given up on: {restarts} restarts"

        # 5s of probe against a 10s start: every attempt is cut off, so the
        # unit loops through restarts and never becomes active.
        short.succeed("systemctl start --no-block victorialogs.service")
        short.wait_until_succeeds(
            "systemctl show -p NRestarts victorialogs.service | grep -qE 'NRestarts=[2-9]'",
            timeout=120,
        )
        state = short.succeed("systemctl show -p ActiveState --value victorialogs.service").strip()
        assert state != "active", state
      '';
    };

  # Effective ProtectSystem and capabilities (CapBnd, from the kernel) are read
  # from the running unit, not the rendered text: measured, DynamicUser units
  # were strict even with an explicit "full"; only static users ran with "full".
  hardening-is-effective-on-running-units = pkgs.testers.nixosTest {
    name = "victoria-stack-hardening-effective";

    containers.dyn = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        dynamicUser = false;
        dataDir = "/srv/vm-data";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      services = [
          "vmstorage", "vminsert", "vmselect", "victorialogs", "victoriatraces", "vmauth",
          "mcp-victoriametrics", "mcp-victorialogs", "mcp-victoriatraces",
      ]
      for unit in services:
          wait_active(dyn, f"{unit}.service")
      wait_active(static, "vmstorage.service")

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
      check_running(static, "vmstorage")

      # Oneshots are not running now; their loaded properties are authoritative.
      for unit in ["vmstorage-snapshot", "vmauth-secret-restart"]:
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
        # Metrics is the cluster: extraFlags are vmselect's, the data directory
        # and the snapshot unit are vmstorage's (whose address is storage.listenAddress).
        units = {
          metrics = {
            flagUnit = "vmselect";
            dataUnit = "vmstorage";
            snapshotUnit = "vmstorage";
            addressOption = "storage.listenAddress";
          };
          logs = {
            flagUnit = "victorialogs";
            dataUnit = "victorialogs";
            snapshotUnit = "victorialogs";
            addressOption = "listenAddress";
          };
          traces = {
            flagUnit = "victoriatraces";
            dataUnit = "victoriatraces";
            snapshotUnit = "victoriatraces";
            addressOption = "listenAddress";
          };
        };
        results = lib.mapAttrsToList (
          attr: u:
          let
            e = evalWith {
              services.victoriaStack.${attr} = {
                enable = true;
                extraFlags = [ flag ];
                dataDir = "/data/100%/\${x}";
              };
            };
            execStart = unit: e.config.systemd.services.${unit}.serviceConfig.ExecStart;
            snapshotStart =
              (evalWith {
                services.victoriaStack.${attr} = lib.recursiveUpdate {
                  enable = true;
                  snapshots.enable = true;
                } (lib.setAttrByPath (lib.splitString "." u.addressOption) "127.0.0.1:1%h");
              }).config.systemd.services."${u.snapshotUnit}-snapshot".serviceConfig.ExecStart;
          in
          {
            "${attr}: extraFlags escaped" = lib.hasInfix escaped (execStart u.flagUnit);
            "${attr}: no raw %h left" = !(lib.hasInfix "p%h" (execStart u.flagUnit));
            "${attr}: dataDir escaped" = lib.hasInfix "/data/100%%/$${x}" (execStart u.dataUnit);
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
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        extraFlags = [ "-envflag.prefix=p%h-\${HOME}" ];
      };
      services.victoriaStack.vmauth.extraFlags = [ "-envflag.prefix=p%h-\${HOME}" ];
    };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      wait_active(machine, "vmselect.service")
      wait_active(machine, "vmauth.service")
      for unit in ["vmselect", "vmauth"]:
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
          t = (lib.attrByPath (lib.splitString "." opt) null (opts svc)).type;
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
              svc:
              table svc "snapshots.maxAge" snapshotMaxAgeAccepted (
                snapshotMaxAgeRejected ++ retentionTypeOnlyRejected
              )
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
      # vmstorage also listens on two RPC ports (8400/8401 by default), which
      # the concurrent probes would fight over.
      extra_flags() {
        case "$1" in
          */vmstorage) echo "-vminsertAddr=127.0.0.1:0 -vmselectAddr=127.0.0.1:0" ;;
        esac
      }
      probe() {
        bin=$1 flag=$2 want=$3
        shift 3
        for v in "$@"; do
          (
            d=$(mktemp -d)
            rc=0
            out=$(timeout 3 "$bin" $(extra_flags "$bin") -storageDataPath="$d" -httpListenAddr=127.0.0.1:0 "-$flag=$v" 2>&1) || rc=$?
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
          bin = "vmstorage";
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
          svc = "metrics";
          bin = "vmstorage";
          flag = "snapshotsMaxAge";
          accepted = snapshotMaxAgeAccepted;
          rejected = snapshotMaxAgeRejected;
        }
        {
          svc = "logs";
          bin = "victoria-logs";
          flag = "snapshotsMaxAge";
          accepted = snapshotMaxAgeAccepted;
          rejected = snapshotMaxAgeRejected;
        }
        {
          svc = "traces";
          bin = "victoria-traces";
          flag = "snapshotsMaxAge";
          accepted = snapshotMaxAgeAccepted;
          rejected = snapshotMaxAgeRejected;
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

  # The flags the extraFlags assertion rejects with snapshots.enable
  # (assertions.nix snapshotKeyFlags) must be the ones that really gate the
  # snapshot endpoint the oneshot calls: 401 without a key, 200 with one, and
  # 200 with no flag at all.
  snapshot-key-flags-gate-the-real-snapshot-endpoint =
    let
      binary =
        {
          svc,
          bin,
          flag,
          path,
        }:
        let
          pkg =
            (evalWith { services.victoriaStack.${svc}.enable = true; })
            .config.services.victoriaStack.${svc}.package;
        in
        ''
          code ${pkg}/bin/${bin} ${path} 200
          code ${pkg}/bin/${bin} ${path} 401 "-${flag}=k"
          code ${pkg}/bin/${bin} "${path}?authKey=k" 200 "-${flag}=k"
        '';
    in
    pkgs.runCommand "snapshot-key-flags-gate-the-real-snapshot-endpoint"
      {
        nativeBuildInputs = [ pkgs.curl ];
      }
      ''
        code() {
          bin=$1 path=$2 want=$3
          shift 3
          d=$(mktemp -d)
          "$bin" -storageDataPath="$d" -httpListenAddr=127.0.0.1:18428 "$@" > "$d.log" 2>&1 &
          pid=$!
          # Bounded: a binary that never listens fails the check, not hangs it.
          up=
          for _ in $(seq 100); do
            curl -s -o /dev/null http://127.0.0.1:18428/health && { up=1; break; }
            sleep 0.2
          done
          [ -n "$up" ] || { cat "$d.log" >&2; exit 1; }
          got=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:18428$path")
          kill $pid
          # Killed on purpose, so its exit status says nothing.
          wait $pid || true
          if [ "$got" != "$want" ]; then
            echo "FAIL: $bin $* POST $path: got $got, want $want" >&2
            exit 1
          fi
        }
        ${lib.concatMapStrings binary [
          {
            svc = "metrics";
            bin = "vmstorage";
            flag = "snapshotAuthKey";
            path = "/snapshot/create";
          }
          {
            svc = "logs";
            bin = "victoria-logs";
            flag = "partitionManageAuthKey";
            path = "/internal/partition/snapshot/create";
          }
          {
            svc = "traces";
            bin = "victoria-traces";
            flag = "partitionManageAuthKey";
            path = "/internal/partition/snapshot/create";
          }
        ]}
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

  # A warning, not an assertion: below one day the binary refuses to start,
  # but an evaluation that only builds a closure should not be blocked.
  metrics-short-retention-warns = mkShortRetentionWarningCheck "metrics";
  logs-short-retention-warns = mkShortRetentionWarningCheck "logs";
  traces-short-retention-warns = mkShortRetentionWarningCheck "traces";

  # Also a warning: above 1200 months the binary refuses to start.
  metrics-long-retention-warns = mkLongRetentionWarningCheck "metrics";
  logs-long-retention-warns = mkLongRetentionWarningCheck "logs";
  traces-long-retention-warns = mkLongRetentionWarningCheck "traces";

  # A number too long to convert would abort the whole evaluation from
  # lib.toIntBase10 inside the module (no option name, nothing else evaluates);
  # the types must refuse it themselves, so the failure names the option.
  # tryEval distinguishes "refused" (value = false) from "aborted" (success = false).
  digit-overflow-is-refused-by-the-option-types =
    let
      refused =
        t: v:
        let
          r = builtins.tryEval (t.check v);
        in
        r.success && !r.value;
      cases = svc: [
        {
          name = "${svc}.retentionPeriod 20 digits";
          ok =
            refused (evalWith { }).options.services.victoriaStack.${svc}.retentionPeriod.type
              "99999999999999999999d";
        }
        {
          name = "${svc}.retentionPeriod 20 digits, bare";
          ok =
            refused (evalWith { }).options.services.victoriaStack.${svc}.retentionPeriod.type
              "99999999999999999999";
        }
        {
          name = "${svc}.retentionPeriod 20 fraction digits";
          ok =
            refused (evalWith { }).options.services.victoriaStack.${svc}.retentionPeriod.type
              "1.99999999999999999999d";
        }
        {
          name = "${svc}.startupTimeout 20 digits";
          ok =
            refused (evalWith { }).options.services.victoriaStack.${svc}.startupTimeout.type
              "99999999999999999999s";
        }
        {
          name = "${svc}.startupTimeout 20 digits in a later part";
          ok =
            refused (evalWith { }).options.services.victoriaStack.${svc}.startupTimeout.type
              "1m99999999999999999999s";
        }
      ];
      failed = lib.filter (c: !c.ok) (
        lib.concatMap cases [
          "metrics"
          "logs"
          "traces"
        ]
      );
    in
    pkgs.runCommand "digit-overflow-is-refused-by-the-option-types" { } (
      if failed == [ ] then
        "echo OK > $out"
      else
        throw "not cleanly refused: ${builtins.toJSON (map (c: c.name) failed)}"
    );

  # The minimum the warning states is what the binaries enforce, edges included.
  retention-minimum-matches-the-real-binaries =
    let
      bins = {
        metrics = "vmstorage";
        logs = "victoria-logs";
        traces = "victoria-traces";
      };
      pkgOf =
        svc:
        (evalWith { services.victoriaStack.${svc}.enable = true; })
        .config.services.victoriaStack.${svc}.package;
    in
    pkgs.runCommand "retention-minimum-matches-the-real-binaries" { } ''
      mkdir failures
      # vmstorage also listens on two RPC ports (8400/8401 by default), which
      # the concurrent probes would fight over.
      extra_flags() {
        case "$1" in
          */vmstorage) echo "-vminsertAddr=127.0.0.1:0 -vmselectAddr=127.0.0.1:0" ;;
        esac
      }
      probe() {
        bin=$1 v=$2 want=$3
        (
          d=$(mktemp -d)
          rc=0
          out=$(timeout 3 "$bin" $(extra_flags "$bin") -storageDataPath="$d" -httpListenAddr=127.0.0.1:0 "-retentionPeriod=$v" 2>&1) || rc=$?
          if [ "$want" = start ] && [ "$rc" -ne 124 ]; then
            echo "FAIL: $bin refused -retentionPeriod=$v: $out" > "failures/$(mktemp -u XXXXXX)"
          elif [ "$want" = refuse ] && ! echo "$out" | grep -q "cannot be smaller than a day"; then
            echo "FAIL: $bin did not refuse -retentionPeriod=$v as below a day (rc=$rc): $out" > "failures/$(mktemp -u XXXXXX)"
          fi
          rm -rf "$d"
        ) &
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (
          svc: bin:
          lib.concatMapStrings (
            v: "probe ${pkgOf svc}/bin/${bin} ${lib.escapeShellArg v} refuse\n"
          ) retentionBelowMinimum
          + lib.concatMapStrings (
            v: "probe ${pkgOf svc}/bin/${bin} ${lib.escapeShellArg v} start\n"
          ) retentionAtOrAboveMinimum
        ) bins
      )}
      wait
      if [ -n "$(ls failures)" ]; then
        cat failures/* >&2
        exit 1
      fi
      echo OK > $out
    '';

  # The 1200 months limit the warning states is what the binaries enforce, and
  # the largest value the type allows (10 digits) is refused by them too.
  retention-maximum-matches-the-real-binaries =
    let
      bins = {
        metrics = "vmstorage";
        logs = "victoria-logs";
        traces = "victoria-traces";
      };
      pkgOf =
        svc:
        (evalWith { services.victoriaStack.${svc}.enable = true; })
        .config.services.victoriaStack.${svc}.package;
    in
    pkgs.runCommand "retention-maximum-matches-the-real-binaries" { } ''
      mkdir failures
      # vmstorage also listens on two RPC ports (8400/8401 by default), which
      # the concurrent probes would fight over.
      extra_flags() {
        case "$1" in
          */vmstorage) echo "-vminsertAddr=127.0.0.1:0 -vmselectAddr=127.0.0.1:0" ;;
        esac
      }
      probe() {
        bin=$1 v=$2 want=$3
        (
          d=$(mktemp -d)
          rc=0
          out=$(timeout 3 "$bin" $(extra_flags "$bin") -storageDataPath="$d" -httpListenAddr=127.0.0.1:0 "-retentionPeriod=$v" 2>&1) || rc=$?
          if [ "$want" = start ] && [ "$rc" -ne 124 ]; then
            echo "FAIL: $bin refused -retentionPeriod=$v: $out" > "failures/$(mktemp -u XXXXXX)"
          elif [ "$want" = refuse ] && ! echo "$out" | grep -q "must be smaller than 1200"; then
            echo "FAIL: $bin did not refuse -retentionPeriod=$v as above 1200 months (rc=$rc): $out" > "failures/$(mktemp -u XXXXXX)"
          fi
          rm -rf "$d"
        ) &
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (
          svc: bin:
          lib.concatMapStrings (
            v: "probe ${pkgOf svc}/bin/${bin} ${lib.escapeShellArg v} refuse\n"
          ) retentionAboveMaximum
          + lib.concatMapStrings (
            v: "probe ${pkgOf svc}/bin/${bin} ${lib.escapeShellArg v} start\n"
          ) retentionAtOrBelowMaximum
        ) bins
      )}
      wait
      if [ -n "$(ls failures)" ]; then
        cat failures/* >&2
        exit 1
      fi
      echo OK > $out
    '';
}
