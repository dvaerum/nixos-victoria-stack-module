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
  # Only set where nixpkgs' own module for the same service sets it
  # (docs/decisions/0015) -- logs deliberately has none, matched rather
  # than added speculatively.
  limitNOFILE ? null,
}:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaStack.${name};
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
          # docs/decisions/0019's structural seam -- consumers (vmauth,
          # Grafana) read this, never cfg.listenAddress directly.
          effectiveUrl = lib.mkDefault "http://${cfg.listenAddress}";
        };
      }

      {
        warnings =
          lib.optional (cfg.dataDir != defaultDataDir && cfg.dynamicUser && !cfg.suppressDynamicUserWarning)
            ''
              services.victoriaStack.${name}.dataDir (${toString cfg.dataDir}) has been
              changed away from the default (${toString defaultDataDir}) while
              dynamicUser is still true. DynamicUser's StateDirectory handling
              tries to migrate a pre-existing dataDir into a private managed copy
              on every start, which fails against an externally-mounted path
              (e.g. a ZFS dataset) -- confirmed on two independent real
              deployments (docs/decisions/0001, 0009). Set
              services.victoriaStack.${name}.dynamicUser = false, or set
              services.victoriaStack.${name}.suppressDynamicUserWarning = true
              once you've confirmed this is deliberate.
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
          postStart =
            let
              # The IPv4 (0.0.0.0), IPv6 ([::]), and bare (":<port>", no
              # host part at all -- a real, upstream-recognized form: the
              # pinned nixpkgs victoria* modules' own postStart handles
              # this exact same prefix) wildcard forms are all legitimate
              # -httpListenAddr values -- probing the wildcard address
              # itself as a *destination* is unreliable across
              # kernels/configurations, so all three substitute to
              # loopback. lib.last (lib.splitString ":" ...) extracts the
              # port correctly in every case: the port is always the
              # final fragment regardless of how many colons appear in
              # the host part (or whether there's a host part at all).
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
                  "${cfg.package}/bin/${binaryName}"
                  "-storageDataPath=${toString cfg.dataDir}"
                  "-httpListenAddr=${cfg.listenAddress}"
                ]
                ++ lib.optionals (cfg.retentionPeriod != null) [ "-retentionPeriod=${cfg.retentionPeriod}" ]
                # Exist only on logs/traces (options.nix), hence `or null`.
                ++ lib.optional (
                  (cfg.retentionMaxDiskSpaceUsageBytes or null) != null
                ) "-retention.maxDiskSpaceUsageBytes=${cfg.retentionMaxDiskSpaceUsageBytes}"
                ++ lib.optional (
                  (cfg.retentionMaxDiskUsagePercent or null) != null
                ) "-retention.maxDiskUsagePercent=${toString cfg.retentionMaxDiskUsagePercent}"
                ++ cfg.extraFlags
              );
              Restart = "on-failure";
              RestartSec = 5;

              # Hardening -- copied from nixpkgs' own services.victoria*
              # modules (same pinned nixpkgs rev), an unacknowledged
              # regression from going from-scratch (ADR 0001 never argued
              # for dropping it). See docs/decisions/0015.
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
                }
            )
          ];
        };
      }
    ]
  );
}
