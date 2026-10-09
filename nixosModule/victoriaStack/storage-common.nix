# Shared builder for the 3 storage services (metrics/logs/traces) -- they
# differ only in the parameters below. Same shape as mcp.nix's
# mkMcpService; metrics.nix/logs.nix/traces.nix are thin call sites.
{
  name, # "metrics" | "logs" | "traces" -- the services.victoriaStack.<name> option subtree
  unitName, # systemd unit + static user/group name, e.g. "victoriametrics"
  binaryName, # binary under ${package}/bin, e.g. "victoria-metrics"
  packageAttr, # attribute name in pkgs used as <name>.package's default, e.g. "victoriametrics"
  defaultDataDir,
  description,
  # The snapshot API differs per binary (confirmed by probing each):
  # VictoriaMetrics serves /snapshot/create, VictoriaLogs and
  # VictoriaTraces serve /internal/partition/snapshot/create instead.
  snapshotCreatePath ? "/snapshot/create",
  # Only set where nixpkgs' own module for the same service sets it
  # (docs/decisions/0015) -- logs deliberately has none, matched rather
  # than added speculatively.
  limitNOFILE ? null,
  # -syslog.* exists on victoria-logs only (docs/decisions/0031).
  supportsSyslog ? false,
}:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.${name};
  selfMonitoring = import ./self-monitoring.nix { inherit lib; };

  listen = import ./listen.nix { inherit lib; };
  syslog = import ./syslog.nix { inherit lib; };
  # The unit keeps its empty capability set unless a syslog port is below 1024
  # (the same rule as vmauth, docs/decisions/0015).
  needsLowPort = supportsSyslog && syslog.needsLowPort cfg.syslog;
  tlsFiles = lib.optionalAttrs supportsSyslog (syslog.tlsFiles cfg.syslog);
  # What the module itself dials (readiness probe, snapshot call, effectiveUrl):
  # loopback for a wildcard listenAddress (:port, 0.0.0.0:port, [::]:port).
  bindAddr = listen.connectAddr cfg.listenAddress;

  # -retentionPeriod in seconds, per the binaries' grammar (options.nix
  # durationRegex). A bare number and `M` are months of 31 days, `y` is 365
  # days -- the lengths the binaries' own minimum check uses (measured).
  retentionSeconds =
    let
      number =
        s:
        let
          parts = lib.splitString "." s;
          frac = if builtins.length parts > 1 then builtins.elemAt parts 1 else "0";
        in
        lib.toIntBase10 (builtins.head parts)
        + lib.toIntBase10 frac / builtins.foldl' (a: _: a * 10.0) 1.0 (lib.stringToCharacters frac);
      unitSeconds = {
        "" = 31 * 86400;
        s = 1;
        h = 3600;
        d = 86400;
        w = 7 * 86400;
        M = 31 * 86400;
        y = 365 * 86400;
      };
      parts = builtins.filter builtins.isList (
        builtins.split "([0-9]+(\\.[0-9]+)?)([shdwMy]?)" cfg.retentionPeriod
      );
    in
    lib.foldl' (
      acc: m: acc + number (builtins.elemAt m 0) * unitSeconds.${builtins.elemAt m 2}
    ) 0 parts;
  minRetentionSeconds = 86400;

  inherit (import ./exec-escape.nix { inherit lib; }) escape;
in
{
  # Renamed from extraOptions to match vmauth.extraFlags and the
  # collector's alloy.extraFlags (docs/decisions/0024) -- the first
  # real use of lib.mkRenamedOptionModule in this project.
  imports = [
    (lib.mkRenamedOptionModule
      [ "services" "victoriaStack" name "extraOptions" ]
      [ "services" "victoriaStack" name "extraFlags" ]
    )
  ];

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # One attrset, not two dotted paths: Nix rejects two definitions
        # of the same dynamic attribute prefix in one set.
        services.victoriaStack.${name} = {
          package = lib.mkDefault pkgs.${packageAttr};
          # docs/decisions/0019's structural seam -- consumers (vmauth, Grafana,
          # the MCP servers, the self-monitoring push) read this, never
          # cfg.listenAddress directly.
          effectiveUrl = lib.mkDefault "http://${bindAddr}";
        };
      }

      {
        warnings =
          lib.optional
            (
              toString cfg.dataDir != toString defaultDataDir
              && cfg.dynamicUser
              && !cfg.suppressDynamicUserWarning
            )
            ''
              services.victoriaStack.${name}.dataDir (${toString cfg.dataDir}) has been
              changed away from the default (${toString defaultDataDir}) while
              dynamicUser is still true. DynamicUser's StateDirectory handling
              tries to migrate a pre-existing dataDir into a private managed copy
              on every start, which fails against an externally-mounted path
              (e.g. a ZFS dataset) (see the `dynamicUser` option and
              docs/decisions/0001, 0009). Set
              services.victoriaStack.${name}.dynamicUser = false, or set
              services.victoriaStack.${name}.suppressDynamicUserWarning = true
              once you've confirmed this is deliberate.
            ''
          ++ lib.optional (cfg.retentionPeriod != null && retentionSeconds < minRetentionSeconds) ''
            services.victoriaStack.${name}.retentionPeriod ("${cfg.retentionPeriod}") is
            shorter than the minimum of 1 day; ${binaryName} refuses to start with
            "-retentionPeriod cannot be smaller than a day". A bare number means months.
          '';
      }

      (lib.mkIf (!cfg.dynamicUser) {
        users.users.${unitName} = {
          isSystemUser = true;
          group = unitName;
        };
        users.groups.${unitName} = { };

        systemd.tmpfiles.rules = lib.optionals cfg.manageTmpfiles [
          "d ${toString cfg.dataDir} 0750 ${unitName} ${unitName} - -"
        ];
      })

      {
        systemd.services.${unitName} = {
          inherit description;
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          # Waits for dataDir's own mount (e.g. a ZFS dataset) before
          # starting; a documented systemd no-op for paths already under
          # local-fs.target, so safe unconditionally.
          unitConfig.RequiresMountsFor = toString cfg.dataDir;

          # wait4x replaces a hand-rolled curl-poll loop -- one command,
          # purpose-built for exactly this. Neither Type=notify nor socket
          # activation apply: these binaries implement neither sd_notify()
          # nor sd_listen_fds(). See docs/decisions/0015.
          path = [ pkgs.wait4x ];
          # The probe waits up to 5 minutes (a large data directory can take that
          # long to open) and TimeoutStartSec sits just above it: with both at
          # 90s (systemd's own default) they expired together and
          # Restart=on-failure looped a slow start.
          postStart = "wait4x http http://${bindAddr}/ping --timeout 5m";

          serviceConfig = lib.mkMerge [
            {
              ExecStart = lib.escapeShellArgs (
                map escape (
                  [
                    "${cfg.package}/bin/${binaryName}"
                    "-storageDataPath=${toString cfg.dataDir}"
                    "-httpListenAddr=${cfg.listenAddress}"
                  ]
                  ++ lib.optionals (cfg.retentionPeriod != null) [ "-retentionPeriod=${cfg.retentionPeriod}" ]
                  # Exist only on logs/traces (options.nix), hence `or null`.
                  ++ selfMonitoring.mkFlags {
                    selfMonitoring = cfg.selfMonitoring;
                    metricsEnabled = topCfg.metrics.enable;
                    metricsUrl = topCfg.metrics.effectiveUrl;
                    job = unitName;
                  }
                  # null passes 0, which DISABLES pruning: omitting the flag would
                  # leave the binaries' own 3d default in force (each binary's
                  # -help), deleting snapshots the operator meant to keep.
                  ++ lib.optional cfg.snapshots.enable "-snapshotsMaxAge=${
                    if cfg.snapshots.maxAge == null then "0" else cfg.snapshots.maxAge
                  }"
                  ++ lib.optional (
                    (cfg.retentionMaxDiskSpaceUsageBytes or null) != null
                  ) "-retention.maxDiskSpaceUsageBytes=${cfg.retentionMaxDiskSpaceUsageBytes}"
                  ++ lib.optional (
                    (cfg.retentionMaxDiskUsagePercent or null) != null
                  ) "-retention.maxDiskUsagePercent=${toString cfg.retentionMaxDiskUsagePercent}"
                )
                # Escaped by the helper itself: the TLS flags carry raw %d.
                ++ lib.optionals supportsSyslog (syslog.mkFlags cfg.syslog)
                ++ map escape cfg.extraFlags
              );
              Restart = "on-failure";
              RestartSec = 5;
              TimeoutStartSec = "6min";
              # A non-root user keeps no capability across exec unless it is ambient.
              AmbientCapabilities = lib.mkIf needsLowPort [ "CAP_NET_BIND_SERVICE" ];

              # Hardening based on nixpkgs' own services.victoria* modules, but
              # with ProtectSystem=strict and an empty capability set. See
              # docs/decisions/0015.
              DeviceAllow = [ "/dev/null rw" ];
              DevicePolicy = "strict";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              # Capabilities held inside a user namespace do not count for
              # binding a port in the host's network namespace.
              PrivateUsers = !needsLowPort;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              CapabilityBoundingSet = if needsLowPort then [ "CAP_NET_BIND_SERVICE" ] else "";
              ProtectSystem = "strict";
              RemoveIPC = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SystemCallArchitectures = "native";
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "mincore"
              ];
            }

            (lib.optionalAttrs (tlsFiles != { }) {
              LoadCredential = lib.mapAttrsToList (n: path: "${n}:${path}") tlsFiles;
            })

            (lib.optionalAttrs (limitNOFILE != null) {
              # Avoids 'too many open files' when merging small parts /
              # handling many spans (same rationale nixpkgs' own modules
              # carry).
              LimitNOFILE = limitNOFILE;
            })

            (
              if cfg.dynamicUser then
                {
                  DynamicUser = true;
                  StateDirectory = unitName;
                  StateDirectoryMode = "0700";
                }
              else
                {
                  DynamicUser = false;
                  User = unitName;
                  Group = unitName;
                  # No StateDirectory for a static user, and ProtectSystem=strict
                  # makes everything else read-only.
                  ReadWritePaths = [ (toString cfg.dataDir) ];
                }
            )
          ];
        };
      }

      (lib.optionalAttrs supportsSyslog (
        let
          ports = syslog.firewallPorts cfg.syslog;
        in
        {
          networking.firewall.allowedTCPPorts = ports.tcp;
          networking.firewall.allowedUDPPorts = ports.udp;
        }
      ))

      # The unit reads a copy of each file (LoadCredential=), so a replaced file
      # must restart it. try-restart: a rotation while the service is stopped must
      # not start it. --no-block: the path unit only re-arms once this helper
      # finishes, so waiting for the service to come back would lose a file
      # replaced in the meantime.
      (lib.mkIf (tlsFiles != { }) {
        systemd.services."${unitName}-secret-restart" = {
          description = "Restart ${unitName} after one of its secret files changed";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${config.systemd.package}/bin/systemctl try-restart --no-block ${unitName}.service";
            CapabilityBoundingSet = "";
          };
        };

        systemd.paths = lib.mapAttrs' (
          n: path:
          lib.nameValuePair "${unitName}-secret-watch-${n}" {
            description = "Watch ${unitName}'s ${n} file for replacement";
            wantedBy = [ "multi-user.target" ];
            pathConfig = {
              PathChanged = path;
              Unit = "${unitName}-secret-restart.service";
            };
          }
        ) tlsFiles;
      })

      # Periodic snapshot creation: a oneshot that POSTs to the binary's
      # own snapshot API over loopback (the same trust boundary as every
      # other internal call in this module -- no credential), fired by a
      # timer. Pruning is the binary's own -snapshotsMaxAge above, not
      # this unit's job.
      (lib.mkIf cfg.snapshots.enable {
        systemd.services."${unitName}-snapshot" = {
          description = "Create a ${name} snapshot";
          after = [ "${unitName}.service" ];
          requires = [ "${unitName}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.escapeShellArgs (
              map escape [
                (lib.getExe pkgs.curl)
                "--silent"
                "--show-error"
                "--fail"
                "--request"
                "POST"
                "http://${bindAddr}${snapshotCreatePath}"
              ]
            );
            DynamicUser = true;
            CapabilityBoundingSet = "";
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
          };
        };

        systemd.timers."${unitName}-snapshot" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.snapshots.schedule;
            # Catch up a missed run after downtime rather than skipping it.
            Persistent = true;
          };
        };
      })
    ]
  );
}
