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

        systemd.tmpfiles.rules = [
          "d ${toString cfg.dataDir} 0750 victorialogs victorialogs - -"
        ];
      })

      {
        systemd.services.victorialogs = {
          description = "VictoriaLogs log storage";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

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
            }

            (
              if cfg.dynamicUser then
                {
                  DynamicUser = true;
                  StateDirectory = "victorialogs";
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
