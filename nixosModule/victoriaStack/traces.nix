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

        systemd.tmpfiles.rules = [
          "d ${toString cfg.dataDir} 0750 victoriatraces victoriatraces - -"
        ];
      })

      {
        systemd.services.victoriatraces = {
          description = "VictoriaTraces distributed tracing storage";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

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
            }

            (
              if cfg.dynamicUser then
                {
                  DynamicUser = true;
                  StateDirectory = "victoriatraces";
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
