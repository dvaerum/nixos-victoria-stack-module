{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaStack.metrics;
  defaultDataDir = /var/lib/victoriametrics;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.victoriaStack.metrics.package = lib.mkDefault pkgs.victoriametrics;
        # docs/decisions/0019's structural seam -- consumers (vmauth,
        # Grafana) read this, never cfg.listenAddress directly.
        services.victoriaStack.metrics.effectiveUrl = lib.mkDefault "http://${cfg.listenAddress}";
      }

      {
        warnings =
          lib.optional (cfg.dataDir != defaultDataDir && cfg.dynamicUser && !cfg.suppressDynamicUserWarning)
            ''
              services.victoriaStack.metrics.dataDir (${toString cfg.dataDir}) has been
              changed away from the default (${toString defaultDataDir}) while
              dynamicUser is still true. DynamicUser's StateDirectory handling
              tries to migrate a pre-existing dataDir into a private managed copy
              on every start, which fails against an externally-mounted path
              (e.g. a ZFS dataset) -- confirmed on two independent real
              deployments (docs/decisions/0001, 0009). Set
              services.victoriaStack.metrics.dynamicUser = false, or set
              services.victoriaStack.metrics.suppressDynamicUserWarning = true
              once you've confirmed this is deliberate.
            '';
      }

      (lib.mkIf (!cfg.dynamicUser) {
        users.users.victoriametrics = {
          isSystemUser = true;
          group = "victoriametrics";
        };
        users.groups.victoriametrics = { };

        systemd.tmpfiles.rules = lib.optionals cfg.manageTmpfiles [
          "d ${toString cfg.dataDir} 0750 victoriametrics victoriametrics - -"
        ];
      })

      {
        systemd.services.victoriametrics = {
          description = "VictoriaMetrics time series database";
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
              # The IPv4 (0.0.0.0), IPv6 ([::]), and bare (":<port>", no
              # host part at all -- confirmed a real, upstream-recognized
              # form: the pinned nixpkgs victoriametrics/victorialogs/
              # victoriatraces modules' own postStart handles this exact
              # same prefix) wildcard forms are all legitimate
              # -httpListenAddr values -- probing the wildcard address
              # itself as a *destination* is unreliable across
              # kernels/configurations, so all three substitute to
              # loopback. lib.last (lib.splitString ":" ...) extracts the
              # port correctly in every case: splitString splits on every
              # ":", and the port is always the final fragment regardless
              # of how many colons appear in the host part before it (or
              # whether there's a host part at all).
              isWildcard =
                lib.hasPrefix "0.0.0.0:" cfg.listenAddress
                || lib.hasPrefix "[::]:" cfg.listenAddress
                || lib.hasPrefix ":" cfg.listenAddress;
              bindAddr =
                if isWildcard then
                  "127.0.0.1:${lib.last (lib.splitString ":" cfg.listenAddress)}"
                else
                  cfg.listenAddress;
            in
            "wait4x http http://${bindAddr}/ping --timeout 90s";

          serviceConfig = lib.mkMerge [
            {
              ExecStart = lib.escapeShellArgs (
                [
                  "${cfg.package}/bin/victoria-metrics"
                  "-storageDataPath=${toString cfg.dataDir}"
                  "-httpListenAddr=${cfg.listenAddress}"
                ]
                ++ lib.optionals (cfg.retentionPeriod != null) [ "-retentionPeriod=${cfg.retentionPeriod}" ]
                ++ cfg.extraOptions
              );
              Restart = "on-failure";
              RestartSec = 5;

              # Hardening -- copied verbatim from nixpkgs' own
              # services.victoriametrics module (same pinned nixpkgs rev),
              # an unacknowledged regression from going from-scratch (ADR
              # 0001 never argued for dropping it). See docs/decisions/0015.
              # Increase the limit to avoid errors like 'too many open
              # files' when merging small parts (same comment nixpkgs'
              # own module carries).
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
                  StateDirectory = "victoriametrics";
                  StateDirectoryMode = "0700";
                }
              else
                {
                  DynamicUser = false;
                  User = "victoriametrics";
                  Group = "victoriametrics";
                }
            )
          ];
        };
      }
    ]
  );
}
