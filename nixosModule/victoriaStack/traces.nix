{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaStack.traces;
  defaultDataDir = /var/lib/victoriatraces;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.victoriaStack.traces.package = lib.mkDefault pkgs.victoriatraces;
        # docs/decisions/0019's structural seam -- consumers (vmauth,
        # Grafana) read this, never cfg.listenAddress directly.
        services.victoriaStack.traces.effectiveUrl = lib.mkDefault "http://${cfg.listenAddress}";
      }

      {
        warnings =
          lib.optional (cfg.dataDir != defaultDataDir && cfg.dynamicUser && !cfg.suppressDynamicUserWarning)
            ''
              services.victoriaStack.traces.dataDir (${toString cfg.dataDir}) has been
              changed away from the default (${toString defaultDataDir}) while
              dynamicUser is still true. DynamicUser's StateDirectory handling
              tries to migrate a pre-existing dataDir into a private managed copy
              on every start, which fails against an externally-mounted path
              (e.g. a ZFS dataset) -- confirmed on two independent real
              deployments (docs/decisions/0001, 0009). Set
              services.victoriaStack.traces.dynamicUser = false, or set
              services.victoriaStack.traces.suppressDynamicUserWarning = true
              once you've confirmed this is deliberate.
            '';
      }

      (lib.mkIf (!cfg.dynamicUser) {
        users.users.victoriatraces = {
          isSystemUser = true;
          group = "victoriatraces";
        };
        users.groups.victoriatraces = { };

        systemd.tmpfiles.rules = lib.optionals cfg.manageTmpfiles [
          "d ${toString cfg.dataDir} 0750 victoriatraces victoriatraces - -"
        ];
      })

      {
        systemd.services.victoriatraces = {
          description = "VictoriaTraces distributed tracing storage";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          # wait4x (pkgs.wait4x) replaces a hand-rolled curl-poll loop --
          # one command, purpose-built for exactly this, confirmed no
          # shared helper exists anywhere in nixpkgs for this (every
          # module hand-rolls the identical loop independently). Neither
          # Type=notify nor socket activation apply: this binary
          # implements neither sd_notify() nor sd_listen_fds(). See
          # docs/decisions/0015.
          path = [ pkgs.wait4x ];
          postStart =
            let
              bindAddr =
                if lib.hasPrefix "0.0.0.0:" cfg.listenAddress then
                  "127.0.0.1:${lib.last (lib.splitString ":" cfg.listenAddress)}"
                else
                  cfg.listenAddress;
            in
            "wait4x http http://${bindAddr}/ping --timeout 90s";

          serviceConfig = lib.mkMerge [
            {
              # Unlike metrics/logs, victoria-traces' own default
              # retentionPeriod is 7d, not unbounded -- confirmed from its
              # own --help. cfg.retentionPeriod = null still means "don't
              # pass the flag" (matching upstream's own default), not "force
              # unbounded"; that's a deliberate, documented difference from
              # metrics/logs captured in each service's own retentionPeriod
              # description ("whatever the binary does when the flag is
              # omitted").
              ExecStart = lib.escapeShellArgs (
                [
                  "${cfg.package}/bin/victoria-traces"
                  "-storageDataPath=${toString cfg.dataDir}"
                  "-httpListenAddr=${cfg.listenAddress}"
                ]
                ++ lib.optionals (cfg.retentionPeriod != null) [ "-retentionPeriod=${cfg.retentionPeriod}" ]
                ++ cfg.extraOptions
              );
              Restart = "on-failure";
              RestartSec = 5;

              # Hardening -- copied verbatim from nixpkgs' own
              # services.victoriatraces module (same pinned nixpkgs rev),
              # an unacknowledged regression from going from-scratch (ADR
              # 0001 never argued for dropping it). See docs/decisions/0015.
              # Increase the limit to avoid errors like 'too many open
              # files' when handling many trace spans (same comment
              # nixpkgs' own module carries).
              LimitNOFILE = 1048576;
              DeviceAllow = [ "/dev/null rw" ];
              DevicePolicy = "strict";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              PrivateUsers = true;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              ProtectSystem = "full";
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

            (
              if cfg.dynamicUser then
                {
                  DynamicUser = true;
                  StateDirectory = "victoriatraces";
                  StateDirectoryMode = "0700";
                }
              else
                {
                  DynamicUser = false;
                  User = "victoriatraces";
                  Group = "victoriatraces";
                }
            )
          ];
        };
      }
    ]
  );
}
