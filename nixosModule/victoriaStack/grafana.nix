{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.grafana;

  datasourceSpecs =
    lib.optional topCfg.metrics.enable {
      name = "VictoriaMetrics";
      type = "victoriametrics-metrics-datasource";
      uid = "victoriametrics-ds";
      url = "http://${topCfg.metrics.listenAddress}";
      isDefault = true;
    }
    ++ lib.optional topCfg.logs.enable {
      name = "VictoriaLogs";
      type = "victoriametrics-logs-datasource";
      uid = "victorialogs-ds";
      url = "http://${topCfg.logs.listenAddress}";
      isDefault = false;
    }
    ++ lib.optional topCfg.traces.enable {
      name = "VictoriaTraces";
      type = "jaeger";
      uid = "victoriatraces-ds";
      url = "http://${topCfg.traces.listenAddress}/select/jaeger";
      isDefault = false;
    };
in
{
  config = lib.mkIf cfg.enable {
    # Neither VictoriaMetrics nor VictoriaLogs is what Grafana's built-in
    # "prometheus"/"loki" datasource types actually expect on the wire
    # (VictoriaLogs speaks its own LogsQL, not LogQL) -- these are the
    # real, VictoriaMetrics-authored plugins for exactly this. Traces need
    # no plugin: VictoriaTraces implements the real Jaeger HTTP API, so
    # Grafana's built-in "jaeger" type works directly.
    services.grafana.declarativePlugins = lib.mkMerge [
      (lib.mkIf topCfg.metrics.enable [ pkgs.grafanaPlugins.victoriametrics-metrics-datasource ])
      (lib.mkIf topCfg.logs.enable [ pkgs.grafanaPlugins.victoriametrics-logs-datasource ])
    ];

    services.grafana.provision.datasources.settings = {
      apiVersion = 1;
      datasources = lib.forEach datasourceSpecs (spec: {
        inherit (spec)
          name
          type
          uid
          url
          isDefault
          ;
        access = "proxy";
        editable = false;
      });

      # Grafana >=12.2 matches an existing datasource by id+uid (not just
      # name) when provisioning re-runs, and treats a mismatch as a fatal
      # startup error rather than a soft one
      # (github.com/grafana/grafana#110740) -- confirmed on a real
      # deployment: a crash loop the moment any of these three datasources
      # went from no-pinned-uid to a pinned one. deleteDatasources forces
      # a clean delete-then-recreate by name every provisioning run,
      # sidestepping the buggy by-uid update path -- nixpkgs' own
      # documented pattern for this exact case.
      deleteDatasources = lib.forEach datasourceSpecs (spec: {
        inherit (spec) name;
        orgId = 1;
      });
    };
  };
}
