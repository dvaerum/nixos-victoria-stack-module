# The three systemd units of the metrics cluster (`metrics.mode = "cluster"`):
# vmstorage owns the data, vminsert and vmselect are stateless. Mirrors the
# single-node unit of storage-common.nix (hardening, readiness probe, restart
# backoff, data directory handling); the process facts come from
# metrics-cluster.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.metrics;
  on = cfg.enable && cfg.mode == "cluster";

  cluster = import ./metrics-cluster.nix { inherit lib; };
  procs = cluster.processes cfg;
  listen = import ./listen.nix { inherit lib; };
  readiness = import ./readiness.nix { inherit lib pkgs; };
  startupTimeout = import ./startup-timeout.nix { inherit lib; };
  restartBackoff = import ../restart-backoff.nix;
  selfMonitoring = import ./self-monitoring.nix { inherit lib; };
  snapshot = import ./snapshot.nix { inherit config lib pkgs; };
  inherit (import ./exec-escape.nix { inherit lib; }) escape;

  # The static user is the one storage-common.nix declares for `metrics`; the
  # data directory keeps its default name, so StateDirectory matches it.
  staticUser = "victoriametrics";

  mkUnit =
    {
      proc,
      description,
      flags,
      after ? [ ],
      serviceConfig ? { },
      unitConfig ? { },
    }:
    {
      inherit description unitConfig;
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ after;
      # Ordering only: no `requires` (a vmstorage restart must not cascade) and
      # no `wants` either. Measured (tests/restart-backoff.nix): a `wants` makes
      # each automatic restart of vminsert/vmselect queue a start of vmstorage,
      # and that start cuts short the backoff vmstorage is waiting out.
      serviceConfig = lib.mkMerge [
        {
          # Neither Type=notify nor socket activation apply (docs/decisions/0015),
          # so readiness is a probe that also ends when the main process dies.
          ExecStartPost = readiness.command {
            unit = "${proc.binary}.service";
            kind = "http";
            target = "http://${listen.connectAddr proc.listenAddr}/health";
            timeout = cfg.startupTimeout;
          };
          ExecStart = lib.escapeShellArgs (
            map escape (
              [
                "${cfg.clusterPackage}/bin/${proc.binary}"
                "-httpListenAddr=${proc.listenAddr}"
              ]
              ++ cluster.tcp6Flags proc
              # Each process pushes its own metrics to vminsert, like the
              # single-node process did to itself (docs/decisions/0026).
              ++ selfMonitoring.mkFlags {
                selfMonitoring = cfg.selfMonitoring;
                metricsEnabled = cfg.enable;
                insertUrl = cfg.effectiveInsertUrl;
                cluster = true;
                job = proc.binary;
              }
              ++ flags
              ++ proc.extraFlags
            )
          );
          Restart = "on-failure";
          RestartSec = 5;
          inherit (restartBackoff) RestartSteps RestartMaxDelaySec;
          TimeoutStartSec = startupTimeout.unitTimeout cfg.startupTimeout;
        }
        (import ./hardening.nix { })
        serviceConfig
      ];
    };

  storage = procs.storage;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.victoriaStack.metrics.clusterPackage = lib.mkDefault (
          pkgs.callPackage ../../packages/victoriametrics-cluster/package.nix { }
        );
      }

      # Single mode: both are the one URL of the single-node server, so an
      # override of `effectiveUrl` still reaches every consumer.
      {
        services.victoriaStack.metrics = {
          effectiveSelectUrl = lib.mkDefault (
            if on then "http://${listen.connectAddr cfg.listenAddress}" else cfg.effectiveUrl
          );
          effectiveInsertUrl = lib.mkDefault (
            if on then "http://${listen.connectAddr cfg.insert.listenAddress}" else cfg.effectiveUrl
          );
        };
      }

      # The snapshot API is vmstorage's: it is the process that owns the data.
      (lib.mkIf (on && cfg.snapshots.enable) {
        systemd = snapshot.mkUnits {
          inherit (cfg) snapshots;
          service = "vmstorage";
          description = "Create a vmstorage snapshot";
          url = "http://${listen.connectAddr storage.listenAddr}/snapshot/create";
        };
      })

      (lib.mkIf on {
        systemd.services = {
          vmstorage = mkUnit {
            proc = storage;
            description = "VictoriaMetrics cluster storage (vmstorage)";
            flags = [
              "-storageDataPath=${toString cfg.dataDir}"
            ]
            ++ lib.optional (cfg.retentionPeriod != null) "-retentionPeriod=${cfg.retentionPeriod}"
            ++ [
              "-vminsertAddr=${cluster.rpc.vminsertAddr}"
              "-vmselectAddr=${cluster.rpc.vmselectAddr}"
            ]
            ++ snapshot.maxAgeFlags cfg.snapshots;
            # Waits for dataDir's own mount (e.g. a ZFS dataset) before starting.
            unitConfig.RequiresMountsFor = toString cfg.dataDir;
            serviceConfig = lib.mkMerge [
              { LimitNOFILE = 1048576; }
              (
                if cfg.dynamicUser then
                  {
                    DynamicUser = true;
                    StateDirectory = staticUser;
                    StateDirectoryMode = "0700";
                  }
                else
                  {
                    DynamicUser = false;
                    User = staticUser;
                    Group = staticUser;
                    ReadWritePaths = [ (toString cfg.dataDir) ];
                  }
              )
            ];
          };

          # Both start after vmstorage so their probe finds it listening, but neither
          # needs it to start: vminsert and vmselect come up and retry the RPC
          # connection themselves, so the ordering is about probe quality only.
          vminsert = mkUnit {
            proc = procs.insert;
            description = "VictoriaMetrics cluster write API (vminsert)";
            flags = [ "-storageNode=${cluster.rpc.vminsertAddr}" ];
            after = [ "vmstorage.service" ];
            serviceConfig.DynamicUser = true;
          };

          # No -cacheDataPath: the cache is not persisted by default and the
          # temporary query results go to /tmp, which PrivateTmp provides.
          vmselect = mkUnit {
            proc = procs.select;
            description = "VictoriaMetrics cluster read API (vmselect)";
            flags = [ "-storageNode=${cluster.rpc.vmselectAddr}" ];
            after = [ "vmstorage.service" ];
            serviceConfig.DynamicUser = true;
          };
        };
      })
    ]
  );
}
