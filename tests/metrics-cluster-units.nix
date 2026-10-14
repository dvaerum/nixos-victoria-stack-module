{ pkgs, nixosModule }:

# The three systemd units of the metrics cluster (metrics.mode = "cluster"):
# what is rendered (L1 tables) and how they behave booted (L3).
let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;

  evalMetrics =
    metrics:
    (evalWith {
      services.victoriaStack.metrics = {
        enable = true;
      }
      // metrics;
    }).config;
  clusterEval = extra: evalMetrics ({ mode = "cluster"; } // extra);

  unitsOf =
    c:
    lib.filter (
      u:
      lib.elem u [
        "victoriametrics"
        "vminsert"
        "vmselect"
        "vmstorage"
      ]
    ) (lib.attrNames c.systemd.services);
  clusterPkg = c: c.services.victoriaStack.metrics.clusterPackage;

  table =
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

  exec = c: unit: c.systemd.services.${unit}.serviceConfig.ExecStart;
  sc = c: unit: c.systemd.services.${unit}.serviceConfig;
  line =
    c: bin: args:
    lib.escapeShellArgs ([ "${clusterPkg c}/bin/${bin}" ] ++ args);

  defaults = clusterEval { };
  custom = clusterEval {
    dataDir = "/srv/vm-data";
    dynamicUser = false;
    retentionPeriod = "3";
    listenAddress = "[::1]:4201";
    extraFlags = [ "-search.maxQueryDuration=10s" ];
    insert = {
      listenAddress = "[::1]:4209";
      extraFlags = [
        "-maxLabelsPerTimeseries=60"
        "-relabelConfig=/etc/a%b"
      ];
    };
    storage = {
      listenAddress = "[::1]:4210";
      extraFlags = [ "-dedup.minScrapeInterval=30s" ];
    };
  };
  onlyInsertV6 = clusterEval { insert.listenAddress = "[::1]:4209"; };
  singleMode = evalMetrics { snapshots.enable = true; };
  clusterSnapshots = clusterEval { snapshots.enable = true; };
  timeouts = clusterEval { startupTimeout = "90s"; };
  withNeighbours =
    (evalWith {
      services.victoriaStack = {
        metrics = {
          enable = true;
          mode = "cluster";
          mcp.enable = true;
        };
        logs.enable = true;
        traces.enable = true;
        grafana.enable = true;
      };
      services.grafana.enable = true;
    }).config;

  probeOf = c: unit: testLib.readinessProbe c.systemd.services.${unit};

  hardened = c: unit: testLib.hardeningDiff (sc c unit) == [ ];

  # The broken-unit and boot tests below: all three binaries are replaced by one
  # that exits at once (a clusterPackage override).
  brokenCluster = pkgs.symlinkJoin {
    name = "broken-victoriametrics-cluster";
    paths = map (b: pkgs.writeShellScriptBin b "exit 3") [
      "vmstorage"
      "vminsert"
      "vmselect"
    ];
  };

  python = ''
    ${testLib.waitActivePython}

    def write_sample(machine, name, value, insert="127.0.0.1:4209"):
        machine.succeed(
            f"curl -sf -X POST --data-binary '{name} {value}' "
            f"'http://{insert}/insert/0/prometheus/api/v1/import/prometheus'"
        )

    # /export is raw samples: unlike an instant query it is not held back by
    # -search.latencyOffset (30s), so a fresh write shows at once.
    def read_sample(machine, name, select="127.0.0.1:4201"):
        return machine.succeed(
            f"curl -sf 'http://{select}/select/0/prometheus/api/v1/export?match[]={name}'"
        )

    def wait_sample(machine, name, value, select="127.0.0.1:4201"):
        machine.wait_until_succeeds(
            f"curl -sf 'http://{select}/select/0/prometheus/api/v1/export?match[]={name}' | grep -q '\"values\":\\[{value}\\]'",
            timeout=60,
        )
  '';
in
{
  # --- L1 ---

  units-exist-in-cluster-mode-and-the-single-node-unit-does-not = table "cluster-units-set" {
    "cluster: exactly the three" =
      unitsOf defaults == [
        "vminsert"
        "vmselect"
        "vmstorage"
      ];
    "single: only the single-node unit" = unitsOf (evalMetrics { }) == [ "victoriametrics" ];
    "metrics disabled: none" =
      unitsOf (evalWith { services.victoriaStack.metrics.mode = "cluster"; }).config == [ ];
    "single keeps its snapshot unit" = singleMode.systemd.services ? "victoriametrics-snapshot";
    "cluster renders no snapshot unit (task 2.5)" =
      !(clusterSnapshots.systemd.services ? "victoriametrics-snapshot");
    "cluster: the neighbours still evaluate" =
      lib.all (u: withNeighbours.systemd.services ? ${u}) [
        "vmauth"
        "mcp-victoriametrics"
        "victorialogs"
        "victoriatraces"
      ]
      && builtins.isList withNeighbours.systemd.services.vmauth.after;
  };

  exec-start-per-process = table "cluster-units-exec-start" {
    "storage defaults" =
      exec defaults "vmstorage" == line defaults "vmstorage" [
        "-httpListenAddr=127.0.0.1:4210"
        "-storageDataPath=/var/lib/victoriametrics"
        "-vminsertAddr=127.0.0.1:4211"
        "-vmselectAddr=127.0.0.1:4212"
      ];
    "insert defaults" =
      exec defaults "vminsert" == line defaults "vminsert" [
        "-httpListenAddr=127.0.0.1:4209"
        "-storageNode=127.0.0.1:4211"
      ];
    "select defaults" =
      exec defaults "vmselect" == line defaults "vmselect" [
        "-httpListenAddr=127.0.0.1:4201"
        "-storageNode=127.0.0.1:4212"
      ];
    "storage: retention, IPv6, own extraFlags, custom dataDir" =
      exec custom "vmstorage" == line custom "vmstorage" [
        "-httpListenAddr=[::1]:4210"
        "-enableTCP6"
        "-storageDataPath=/srv/vm-data"
        "-retentionPeriod=3"
        "-vminsertAddr=127.0.0.1:4211"
        "-vmselectAddr=127.0.0.1:4212"
        "-dedup.minScrapeInterval=30s"
      ];
    "insert: IPv6, % escaped, own extraFlags only" =
      exec custom "vminsert" == line custom "vminsert" [
        "-httpListenAddr=[::1]:4209"
        "-enableTCP6"
        "-storageNode=127.0.0.1:4211"
        "-maxLabelsPerTimeseries=60"
        "-relabelConfig=/etc/a%%b"
      ];
    "select: IPv6, own extraFlags only" =
      exec custom "vmselect" == line custom "vmselect" [
        "-httpListenAddr=[::1]:4201"
        "-enableTCP6"
        "-storageNode=127.0.0.1:4212"
        "-search.maxQueryDuration=10s"
      ];
    "-enableTCP6 only on the process with the IPv6 address" =
      !(lib.hasInfix "-enableTCP6" (exec onlyInsertV6 "vmstorage"))
      && lib.hasInfix "-enableTCP6" (exec onlyInsertV6 "vminsert")
      && !(lib.hasInfix "-enableTCP6" (exec onlyInsertV6 "vmselect"));
  };

  units-carry-the-hardening-backoff-and-ordering = table "cluster-units-hardening-ordering" {
    "storage hardening" = hardened defaults "vmstorage";
    "insert hardening" = hardened defaults "vminsert";
    "select hardening" = hardened defaults "vmselect";
    "backoff on all three" =
      lib.all
        (
          u:
          (sc defaults u).RestartSteps == 3
          && (sc defaults u).RestartMaxDelaySec == 30
          && (sc defaults u).Restart == "on-failure"
          && (sc defaults u).RestartSec == 5
        )
        [
          "vmstorage"
          "vminsert"
          "vmselect"
        ];
    "insert and select start after vmstorage" =
      lib.all (u: lib.elem "vmstorage.service" defaults.systemd.services.${u}.after)
        [
          "vminsert"
          "vmselect"
        ];
    "vmstorage is not after the others" =
      !(lib.any (u: lib.elem u defaults.systemd.services.vmstorage.after) [
        "vminsert.service"
        "vmselect.service"
      ]);
    # A `wants` cuts vmstorage's restart backoff short (restart-backoff test).
    "no unit wants another" = lib.all (u: (defaults.systemd.services.${u}.wants or [ ]) == [ ]) [
      "vmstorage"
      "vminsert"
      "vmselect"
    ];
    "no unit requires or binds another (a vmstorage restart must not cascade)" =
      lib.all
        (
          u:
          (defaults.systemd.services.${u}.requires or [ ]) == [ ]
          && (defaults.systemd.services.${u}.bindsTo or [ ]) == [ ]
        )
        [
          "vmstorage"
          "vminsert"
          "vmselect"
        ];
    "all wanted by multi-user" =
      lib.all (u: defaults.systemd.services.${u}.wantedBy == [ "multi-user.target" ])
        [
          "vmstorage"
          "vminsert"
          "vmselect"
        ];
    "storage has the high file limit" = (sc defaults "vmstorage").LimitNOFILE == 1048576;
  };

  data-directory-belongs-to-vmstorage-alone = table "cluster-units-data-directory" {
    "storage: DynamicUser + StateDirectory" =
      (sc defaults "vmstorage").DynamicUser == true
      && (sc defaults "vmstorage").StateDirectory == "victoriametrics";
    "storage: RequiresMountsFor dataDir" =
      defaults.systemd.services.vmstorage.unitConfig.RequiresMountsFor == "/var/lib/victoriametrics";
    "insert and select: DynamicUser, no state or cache directory" =
      lib.all
        (
          u:
          (sc defaults u).DynamicUser == true
          && !(sc defaults u ? StateDirectory)
          && !(sc defaults u ? CacheDirectory)
          && !(sc defaults u ? ReadWritePaths)
        )
        [
          "vminsert"
          "vmselect"
        ];
    "storage, static user: User, Group, ReadWritePaths, no StateDirectory" =
      let
        s = sc custom "vmstorage";
      in
      s.DynamicUser == false
      && s.User == "victoriametrics"
      && s.Group == "victoriametrics"
      && s.ReadWritePaths == [ "/srv/vm-data" ]
      && !(s ? StateDirectory);
    "static user: the user, group and tmpfiles rule exist" =
      custom.users.users ? victoriametrics
      && lib.elem "d /srv/vm-data 0750 victoriametrics victoriametrics - -" custom.systemd.tmpfiles.rules;
    "static user: insert and select stay dynamic" = lib.all (u: (sc custom u).DynamicUser == true) [
      "vminsert"
      "vmselect"
    ];
    "RequiresMountsFor only on vmstorage" =
      lib.all (u: !(defaults.systemd.services.${u}.unitConfig ? RequiresMountsFor))
        [
          "vminsert"
          "vmselect"
        ];
    "the cluster package default is this flake's own package" =
      lib.hasPrefix "victoriametrics-cluster-" (clusterPkg defaults).name;
  };

  readiness-probes-target-each-process-own-health-endpoint = table "cluster-units-readiness" {
    "storage probes its HTTP port" =
      let
        p = probeOf defaults "vmstorage";
      in
      p.unit == "vmstorage.service" && p.kind == "http" && p.target == "http://127.0.0.1:4210/health";
    "insert probes /health" =
      let
        p = probeOf defaults "vminsert";
      in
      p.unit == "vminsert.service" && p.kind == "http" && p.target == "http://127.0.0.1:4209/health";
    "select probes /health" =
      let
        p = probeOf defaults "vmselect";
      in
      p.unit == "vmselect.service" && p.kind == "http" && p.target == "http://127.0.0.1:4201/health";
    "a wildcard address is probed on loopback" =
      (probeOf (clusterEval { insert.listenAddress = "0.0.0.0:4209"; }) "vminsert").target
      == "http://127.0.0.1:4209/health";
    "an IPv6 address is probed as written (shell-quoted)" =
      lib.hasSuffix " 'http://[::1]:4209/health'" (sc custom "vminsert").ExecStartPost;
    "default deadline 300s, unit timeout 6min on all three" =
      lib.all (u: (probeOf defaults u).deadline == "300" && (sc defaults u).TimeoutStartSec == "6min")
        [
          "vmstorage"
          "vminsert"
          "vmselect"
        ];
    "startupTimeout 90s: probe 90s, unit 150s, on all three" =
      lib.all
        (
          u:
          testLib.probeAndStartSeconds timeouts.systemd.services.${u} == {
            probe = 90;
            start = 150;
          }
        )
        [
          "vmstorage"
          "vminsert"
          "vmselect"
        ];
  };

  # --- L3 ---

  metrics-cluster-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-cluster-roundtrip";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        mode = "cluster";
      };
    };

    testScript = ''
      ${python}
      start_all()
      for u in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{u}.service")

      # vmselect in particular: its cache and temporary results must work under
      # the hardening (no writable directory but PrivateTmp's /tmp).
      for url in ("4210", "4209", "4201"):
          machine.succeed(f"curl -sf http://127.0.0.1:{url}/health")

      write_sample(machine, "cluster_roundtrip_a", 41)
      wait_sample(machine, "cluster_roundtrip_a", 41)

      # Each process restarted ALONE: the others keep running and the path works after.
      pids = {}
      for u in ["vmstorage", "vminsert", "vmselect"]:
          pids[u] = machine.succeed(f"systemctl show -p MainPID --value {u}.service").strip()
      for i, victim in enumerate(["vminsert", "vmselect", "vmstorage"]):
          machine.succeed(f"systemctl restart {victim}.service")
          wait_active(machine, f"{victim}.service")
          for u in ["vmstorage", "vminsert", "vmselect"]:
              now = machine.succeed(f"systemctl show -p MainPID --value {u}.service").strip()
              if u == victim:
                  assert now != pids[u], f"{u} was not restarted"
                  pids[u] = now
              else:
                  assert now == pids[u], f"restarting {victim} restarted {u} ({pids[u]} -> {now})"
          # vminsert needs vmstorage's RPC listener back before its retry succeeds.
          machine.wait_until_succeeds(
              f"curl -sf -X POST --data-binary 'cluster_roundtrip_after_{victim} {i}' "
              "'http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus'",
              timeout=60,
          )
          wait_sample(machine, f"cluster_roundtrip_after_{victim}", i)
          # The data written before any restart survived all of them (vmstorage's
          # own restart included, on the last round).
          wait_sample(machine, "cluster_roundtrip_a", 41)
    '';
  };

  # The binaries bind IPv4 only unless started with -enableTCP6; the RPC ports
  # between the processes stay IPv4 loopback.
  metrics-cluster-listeners-serve-over-ipv6 = pkgs.testers.nixosTest {
    name = "victoria-stack-metrics-cluster-ipv6";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        mode = "cluster";
        listenAddress = "[::1]:4201";
        insert.listenAddress = "[::1]:4209";
        storage.listenAddress = "[::1]:4210";
      };
    };

    testScript = ''
      ${python}
      start_all()
      for u in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{u}.service")
      for port in ("4210", "4209", "4201"):
          machine.succeed(f"curl -sf 'http://[::1]:{port}/health'")
      write_sample(machine, "cluster_ipv6_a", 7, insert="[::1]:4209")
      wait_sample(machine, "cluster_ipv6_a", 7, select="[::1]:4201")
    '';
  };

  broken-cluster-unit-fails-fast = pkgs.testers.nixosTest {
    name = "victoria-stack-broken-cluster-units";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.metrics = {
        enable = true;
        mode = "cluster";
        clusterPackage = brokenCluster;
      };
      # A unit failing in a loop keeps the container's boot job pending.
      systemd.services = lib.genAttrs [ "vmstorage" "vminsert" "vmselect" ] (_: {
        wantedBy = lib.mkForce [ ];
      });
    };

    testScript = ''
      ${testLib.brokenUnitFailureSeconds}
      start_all()
      machine.wait_for_unit("multi-user.target")
      # One at a time, each fails by its own main process dying, at once and not
      # at the 300s default deadline.
      for unit in ["vmstorage.service", "vminsert.service", "vmselect.service"]:
          took = broken_unit_failure_seconds(machine, unit)
          print(f"{unit}: probe gave up {took:.1f}s after the start")
          assert took < 20, f"{unit}: took {took:.1f}s; the default startupTimeout is 300s"
    '';
  };
}
