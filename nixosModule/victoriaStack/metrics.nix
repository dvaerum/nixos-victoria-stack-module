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

        systemd.tmpfiles.rules = [
          "d ${toString cfg.dataDir} 0750 victoriametrics victoriametrics - -"
        ];
      })

      {
        systemd.services.victoriametrics = {
          description = "VictoriaMetrics time series database";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

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
            }

            (
              if cfg.dynamicUser then
                {
                  DynamicUser = true;
                  StateDirectory = "victoriametrics";
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
