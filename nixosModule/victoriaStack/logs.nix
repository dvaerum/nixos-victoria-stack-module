{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaStack.logs;
  defaultDataDir = /var/lib/victorialogs;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.victoriaStack.logs.package = lib.mkDefault pkgs.victorialogs;
        # docs/decisions/0019's structural seam -- consumers (vmauth,
        # Grafana) read this, never cfg.listenAddress directly.
        services.victoriaStack.logs.effectiveUrl = lib.mkDefault "http://${cfg.listenAddress}";
      }

      {
        warnings =
          lib.optional (cfg.dataDir != defaultDataDir && cfg.dynamicUser && !cfg.suppressDynamicUserWarning)
            ''
              services.victoriaStack.logs.dataDir (${toString cfg.dataDir}) has been
              changed away from the default (${toString defaultDataDir}) while
              dynamicUser is still true. DynamicUser's StateDirectory handling
              tries to migrate a pre-existing dataDir into a private managed copy
              on every start, which fails against an externally-mounted path
              (e.g. a ZFS dataset) -- confirmed on two independent real
              deployments (docs/decisions/0001, 0009). Set
              services.victoriaStack.logs.dynamicUser = false, or set
              services.victoriaStack.logs.suppressDynamicUserWarning = true
              once you've confirmed this is deliberate.
            '';
      }

      (lib.mkIf (!cfg.dynamicUser) {
        users.users.victorialogs = {
          isSystemUser = true;
          group = "victorialogs";
        };
        users.groups.victorialogs = { };

        systemd.tmpfiles.rules = lib.optionals cfg.manageTmpfiles [
          "d ${toString cfg.dataDir} 0750 victorialogs victorialogs - -"
        ];
      })

      {
        systemd.services.victorialogs = {
          description = "VictoriaLogs log storage";
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
              # victoria-logs's own -retentionPeriod flag is a real,
              # documented command-line flag on the binary itself (confirmed
              # via `victoria-logs --help`) -- the nixpkgs module's lack of a
              # first-class option for it (docs/decisions/0001) was a
              # module-authoring gap, not a binary limitation, so this is
              # wired as a genuine first-class option here same as metrics'.
              ExecStart = lib.escapeShellArgs (
                [
                  "${cfg.package}/bin/victoria-logs"
                  "-storageDataPath=${toString cfg.dataDir}"
                  "-httpListenAddr=${cfg.listenAddress}"
                ]
                ++ lib.optionals (cfg.retentionPeriod != null) [ "-retentionPeriod=${cfg.retentionPeriod}" ]
                ++ cfg.extraOptions
              );
              Restart = "on-failure";
              RestartSec = 5;

              # Hardening -- copied verbatim from nixpkgs' own
              # services.victorialogs module (same pinned nixpkgs rev), an
              # unacknowledged regression from going from-scratch (ADR
              # 0001 never argued for dropping it). See
              # docs/decisions/0015. Unlike metrics/traces, nixpkgs' own
              # victorialogs module does NOT set LimitNOFILE -- matched
              # here, not added speculatively.
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
                  StateDirectory = "victorialogs";
                  StateDirectoryMode = "0700";
                }
              else
                {
                  DynamicUser = false;
                  User = "victorialogs";
                  Group = "victorialogs";
                }
            )
          ];
        };
      }
    ]
  );
}
