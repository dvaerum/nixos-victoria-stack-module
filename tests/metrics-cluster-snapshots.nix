{ pkgs, nixosModule }:

# Snapshots and self-monitoring of the metrics cluster (metrics.mode = "cluster"):
# the snapshot oneshot + timer belong to vmstorage, and every process of the
# stack pushes its own metrics to vminsert's tenant-0 import endpoint.
let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;
  ownMessages = lib.filter (lib.hasInfix "services.victoriaStack");

  stack = services: (evalWith { services.victoriaStack = services; }).config;
  clusterStack =
    metrics: others:
    stack (
      {
        metrics = {
          enable = true;
          mode = "cluster";
        }
        // metrics;
      }
      // others
    );
  failedOf = c: ownMessages (map (a: a.message) (lib.filter (a: !a.assertion) c.assertions));

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

  sc = c: unit: c.systemd.services.${unit}.serviceConfig;
  exec = c: unit: (sc c unit).ExecStart;

  snapshotsOn = clusterStack { snapshots.enable = true; } { };
  snapshotsCustom = clusterStack {
    snapshots = {
      enable = true;
      schedule = "hourly";
      maxAge = "7d";
    };
    storage.listenAddress = "[::1]:4210";
    insert.listenAddress = "[::1]:4209";
  } { };
  snapshotsForever = clusterStack {
    snapshots = {
      enable = true;
      maxAge = null;
    };
  } { };
  snapshotsWildcard = clusterStack {
    snapshots.enable = true;
    storage.listenAddress = ":4210";
  } { };
  snapshotsOff = clusterStack { } { };
  singleOn = stack {
    metrics = {
      enable = true;
      snapshots.enable = true;
    };
  };

  curlLine =
    url:
    lib.escapeShellArgs [
      (lib.getExe pkgs.curl)
      "--silent"
      "--show-error"
      "--fail"
      "--request"
      "POST"
      url
    ];

  svc = c: unit: c.systemd.services.${unit};
  timer = c: c.systemd.timers."vmstorage-snapshot";

  # The same flag on the process the assertion looks at and on the others.
  keyFlag = "-snapshotAuthKey=k";
  withKeyOn = where: clusterStack ({ snapshots.enable = true; } // where) { };
  snapshotMessage = lib.hasInfix "snapshots.enable is true but";
  snapshotFailures = c: lib.filter snapshotMessage (failedOf c);

  # Every process pushes; the stack's other services too.
  fullOn = clusterStack { } {
    logs.enable = true;
    traces.enable = true;
  };
  fullCustom =
    clusterStack
      {
        insert.listenAddress = ":4209";
      }
      {
        logs.enable = true;
        traces.enable = true;
      };
  fullOff = clusterStack { selfMonitoring.enable = false; } {
    logs = {
      enable = true;
      selfMonitoring.enable = false;
    };
  };
  singleFull = stack {
    metrics.enable = true;
    logs.enable = true;
    traces.enable = true;
  };

  push = job: url: [
    "-pushmetrics.url=${url}"
    "-pushmetrics.interval=30s"
    "-pushmetrics.extraLabel=job=\"${job}\""
  ];
  insertPush = "http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus";
  singlePush = "http://127.0.0.1:4201/api/v1/import/prometheus";
  hasPush =
    c: unit: job: url:
    lib.hasInfix (lib.escapeShellArgs (push job url)) (exec c unit);
  hasNoPush = c: unit: !(lib.hasInfix "pushmetrics" (exec c unit));

  python = ''
    ${testLib.waitActivePython}
  '';
in
{
  # --- L1: snapshots ---

  cluster-snapshots-unit-posts-to-vmstorage = table "cluster-snapshots-unit" {
    "unit and timer exist, named for vmstorage" =
      snapshotsOn.systemd.services ? "vmstorage-snapshot"
      && snapshotsOn.systemd.timers ? "vmstorage-snapshot";
    "no single-node snapshot unit" =
      !(snapshotsOn.systemd.services ? "victoriametrics-snapshot")
      && !(snapshotsOn.systemd.timers ? "victoriametrics-snapshot");
    "ExecStart POSTs vmstorage's create endpoint" =
      exec snapshotsOn "vmstorage-snapshot" == curlLine "http://127.0.0.1:4210/snapshot/create";
    "storage.listenAddress follows (IPv6)" =
      exec snapshotsCustom "vmstorage-snapshot" == curlLine "http://[::1]:4210/snapshot/create";
    "a wildcard storage.listenAddress is dialled on loopback" =
      exec snapshotsWildcard "vmstorage-snapshot" == curlLine "http://127.0.0.1:4210/snapshot/create";
    "skipped, not failed, while vmstorage is not active" =
      (sc snapshotsOn "vmstorage-snapshot").ExecCondition
      == "+${snapshotsOn.systemd.package}/bin/systemctl is-active --quiet vmstorage.service";
    "ordered after vmstorage, with no requires/wants/bindsTo" =
      (svc snapshotsOn "vmstorage-snapshot").after == [ "vmstorage.service" ]
      && (svc snapshotsOn "vmstorage-snapshot").requires == [ ]
      && (svc snapshotsOn "vmstorage-snapshot").wants == [ ]
      && (svc snapshotsOn "vmstorage-snapshot").bindsTo == [ ];
    "oneshot with the sandbox" =
      let
        s = sc snapshotsOn "vmstorage-snapshot";
      in
      s.Type == "oneshot"
      && s.DynamicUser
      && s.CapabilityBoundingSet == ""
      && s.NoNewPrivileges
      && s.PrivateDevices
      && s.PrivateTmp
      && s.ProtectHome
      && s.ProtectSystem == "strict"
      &&
        s.RestrictAddressFamilies == [
          "AF_INET"
          "AF_INET6"
        ];
    "timer: daily by default, persistent, wanted by timers.target" =
      (timer snapshotsOn).timerConfig.OnCalendar == "daily"
      && (timer snapshotsOn).timerConfig.Persistent == true
      && (timer snapshotsOn).wantedBy == [ "timers.target" ];
    "timer: schedule option" = (timer snapshotsCustom).timerConfig.OnCalendar == "hourly";
  };

  cluster-snapshots-max-age-is-vmstorages-flag = table "cluster-snapshots-max-age" {
    "storage: default 30d" = lib.hasInfix "-snapshotsMaxAge=30d" (exec snapshotsOn "vmstorage");
    "storage: custom 7d" = lib.hasInfix "-snapshotsMaxAge=7d" (exec snapshotsCustom "vmstorage");
    "storage: null keeps snapshots (0 disables pruning)" =
      lib.hasInfix "-snapshotsMaxAge=0" (exec snapshotsForever "vmstorage")
      && snapshotsForever.systemd.timers ? "vmstorage-snapshot";
    "insert and select carry no snapshot flag" =
      !(lib.hasInfix "snapshotsMaxAge" (exec snapshotsOn "vminsert"))
      && !(lib.hasInfix "snapshotsMaxAge" (exec snapshotsOn "vmselect"));
    "off: no flag, no unit, no timer" =
      !(lib.hasInfix "snapshotsMaxAge" (exec snapshotsOff "vmstorage"))
      && !(snapshotsOff.systemd.services ? "vmstorage-snapshot")
      && !(snapshotsOff.systemd.timers ? "vmstorage-snapshot")
      && !(snapshotsOff.systemd.services ? "victoriametrics-snapshot");
  };

  single-mode-snapshot-unit-is-unchanged = table "single-snapshots-unchanged" {
    "unit, timer and URL" =
      singleOn.systemd.services ? "victoriametrics-snapshot"
      && singleOn.systemd.timers ? "victoriametrics-snapshot"
      && !(singleOn.systemd.services ? "vmstorage-snapshot")
      && exec singleOn "victoriametrics-snapshot" == curlLine "http://127.0.0.1:4201/snapshot/create";
    "description" =
      (svc singleOn "victoriametrics-snapshot").description == "Create a metrics snapshot";
    "maxAge flag" = lib.hasInfix "-snapshotsMaxAge=30d" (exec singleOn "victoriametrics");
  };

  # --- L1: the snapshot-key assertion follows the process that serves /snapshot ---

  cluster-snapshots-key-flag-assertion-hangs-off-storage = table "cluster-snapshots-key-assertion" {
    "storage.extraFlags with the key flag is rejected, naming that option" =
      let
        f = snapshotFailures (withKeyOn {
          storage.extraFlags = [ keyFlag ];
        });
      in
      lib.length f == 1
      && lib.hasInfix "services.victoriaStack.metrics.snapshots.enable is true but storage.extraFlags contains `${keyFlag}`" (
        lib.head f
      );
    "the bare name form is rejected too" =
      snapshotFailures (withKeyOn {
        storage.extraFlags = [ "-snapshotAuthKey" ];
      }) != [ ];
    "metrics.extraFlags (vmselect) is not this assertion's business" =
      snapshotFailures (withKeyOn {
        extraFlags = [ keyFlag ];
      }) == [ ];
    "insert.extraFlags is not either" =
      snapshotFailures (withKeyOn {
        insert.extraFlags = [ keyFlag ];
      }) == [ ];
    "with snapshots off the flag is fine" =
      snapshotFailures (clusterStack { storage.extraFlags = [ keyFlag ]; } { }) == [ ];
    "a similar flag is fine" =
      snapshotFailures (withKeyOn {
        storage.extraFlags = [ "-snapshotAuthKeyX=k" ];
      }) == [ ];
    "single mode: still metrics.extraFlags" =
      let
        f = snapshotFailures (stack {
          metrics = {
            enable = true;
            snapshots.enable = true;
            extraFlags = [ keyFlag ];
          };
        });
      in
      lib.length f == 1
      && lib.hasInfix "services.victoriaStack.metrics.snapshots.enable is true but extraFlags contains `${keyFlag}`" (
        lib.head f
      );
  };

  # --- L1: self-monitoring ---

  cluster-self-monitoring-pushes-to-vminsert = table "cluster-self-monitoring" {
    "vmstorage" = hasPush fullOn "vmstorage" "vmstorage" insertPush;
    "vminsert" = hasPush fullOn "vminsert" "vminsert" insertPush;
    "vmselect" = hasPush fullOn "vmselect" "vmselect" insertPush;
    "logs" = hasPush fullOn "victorialogs" "victorialogs" insertPush;
    "traces" = hasPush fullOn "victoriatraces" "victoriatraces" insertPush;
    "vmauth" = hasPush fullOn "vmauth" "vmauth" insertPush;
    "the target is not vmselect's" =
      !(lib.hasInfix "4201" (
        lib.concatStringsSep " " (
          map (exec fullOn) [
            "vmstorage"
            "vminsert"
            "victorialogs"
            "vmauth"
          ]
        )
      ));
    "the wildcard insert address is dialled on loopback" =
      hasPush fullCustom "vmstorage" "vmstorage" insertPush
      && hasPush fullCustom "vmauth" "vmauth" insertPush;
    "no token or auth flag in any push" =
      !(lib.any (u: lib.hasInfix "pushmetrics.header" (exec fullOn u)) [
        "vmstorage"
        "vminsert"
        "vmselect"
        "victorialogs"
        "vmauth"
      ]);
    "the interval option is used" = lib.hasInfix "-pushmetrics.interval=10s" (
      exec (clusterStack { selfMonitoring.interval = "10s"; } { }) "vmselect"
    );
    "disabled: no flags on any process" = lib.all (u: hasNoPush fullOff u) [
      "vmstorage"
      "vminsert"
      "vmselect"
      "victorialogs"
    ];
    "jobs are distinct" =
      let
        jobs = map (u: lib.head (lib.match ".*job=\"([a-z]+)\".*" (exec fullOn u))) [
          "vmstorage"
          "vminsert"
          "vmselect"
          "victorialogs"
          "victoriatraces"
          "vmauth"
        ];
      in
      lib.length (lib.unique jobs) == lib.length jobs;
  };

  single-mode-self-monitoring-is-unchanged = table "single-self-monitoring" {
    "metrics" = hasPush singleFull "victoriametrics" "victoriametrics" singlePush;
    "logs" = hasPush singleFull "victorialogs" "victorialogs" singlePush;
    "traces" = hasPush singleFull "victoriatraces" "victoriatraces" singlePush;
    "vmauth" = hasPush singleFull "vmauth" "vmauth" singlePush;
  };

  # --- L3 ---

  cluster-snapshot-creates-and-skips-when-stopped = pkgs.testers.nixosTest {
    name = "victoria-stack-cluster-snapshot";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        mode = "cluster";
        snapshots.enable = true;
      };
    };

    testScript = ''
      ${python}
      import json

      start_all()
      for u in ["vmstorage", "vminsert", "vmselect"]:
          wait_active(machine, f"{u}.service")

      machine.succeed(
          "curl -sf -X POST --data-binary 'cluster_snapshot_a 7' "
          "'http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/select/0/prometheus/api/v1/export?match[]=cluster_snapshot_a' "
          "| grep -q '\"values\":\\[7\\]'",
          timeout=60,
      )

      # The oneshot really creates one, under vmstorage's data directory. A
      # snapshot holds only flushed parts, and the fresh sample sits in memory
      # until vmstorage's periodic flush, so wait for the part files first.
      machine.wait_until_succeeds(
          "find /var/lib/victoriametrics/data/small -mindepth 2 -type f | grep -q .", timeout=60
      )
      machine.succeed("systemctl start vmstorage-snapshot.service")
      base = "/var/lib/victoriametrics/snapshots"
      listed = json.loads(machine.succeed("curl -sf http://127.0.0.1:4210/snapshot/list"))
      assert len(listed["snapshots"]) == 1, listed
      name = listed["snapshots"][0]
      machine.succeed(f"test -d {base}/{name}/metadata")
      # The data is in it: data/{small,big,indexdb} link to the live parts (hence -L).
      machine.succeed(f"find -L {base}/{name}/data -mindepth 2 -type f | grep -q .")

      # The schedule is armed.
      machine.succeed("systemctl is-enabled vmstorage-snapshot.timer")
      machine.succeed("systemctl is-active vmstorage-snapshot.timer")

      # A deliberately stopped vmstorage stays stopped: the oneshot is skipped,
      # not failed, and does not start it.
      machine.succeed("systemctl stop vmstorage.service")
      machine.succeed("systemctl start vmstorage-snapshot.service")
      assert machine.succeed("systemctl is-active vmstorage.service || true").strip() == "inactive"
      assert machine.succeed("systemctl is-failed vmstorage-snapshot.service || true").strip() != "failed"
      assert machine.succeed("systemctl show -p Result --value vmstorage-snapshot.service").strip() == "exec-condition"
    '';
  };

  cluster-self-monitoring-reaches-vminsert = pkgs.testers.nixosTest {
    name = "victoria-stack-cluster-self-monitoring";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          mode = "cluster";
          selfMonitoring.interval = "2s";
        };
        logs = {
          enable = true;
          selfMonitoring.interval = "2s";
        };
      };
    };

    testScript = ''
      ${python}
      start_all()
      for u in ["vmstorage", "vminsert", "vmselect", "victorialogs"]:
          wait_active(machine, f"{u}.service")

      # Each process's own vm_app_version arrives with its own job label,
      # through vminsert and out of vmselect (/export: not held back by
      # -search.latencyOffset, unlike an instant query).
      for job in ["vmstorage", "vminsert", "vmselect", "victorialogs"]:
          machine.wait_until_succeeds(
              "curl -sf 'http://127.0.0.1:4201/select/0/prometheus/api/v1/export"
              f"?match[]=vm_app_version%7Bjob%3D%22{job}%22%7D' | grep -q vm_app_version",
              timeout=90,
          )
    '';
  };
}
