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
      url = topCfg.metrics.effectiveUrl; # docs/decisions/0019
      isDefault = true;
    }
    ++ lib.optional topCfg.logs.enable {
      name = "VictoriaLogs";
      type = "victoriametrics-logs-datasource";
      uid = "victorialogs-ds";
      url = topCfg.logs.effectiveUrl;
      isDefault = false;
    }
    ++ lib.optional topCfg.traces.enable {
      name = "VictoriaTraces";
      type = "jaeger";
      uid = "victoriatraces-ds";
      url = "${topCfg.traces.effectiveUrl}/select/jaeger";
      isDefault = false;
    };
in
{
  config = lib.mkIf cfg.enable {
    # The only reason to reach for this module's own grafana.enable
    # instead of plain services.grafana.enable directly is the
    # auto-wired datasource provisioning above -- with zero backends
    # enabled, datasourceSpecs is empty and that auto-wiring delivers
    # nothing, unlike e.g. requireAuthForWrites+no-token or
    # manageTmpfiles=false, which both have a real alternative deployment
    # shape behind them. Still technically works (Grafana starts fine
    # with no provisioned datasources), so a warning, not an assertion.
    warnings = lib.optional (datasourceSpecs == [ ]) ''
      services.victoriaStack.grafana.enable is set, but none of
      metrics/logs/traces.enable is -- this leaves datasourceSpecs empty,
      so no datasource is actually provisioned into Grafana. The only
      thing services.victoriaStack.grafana.enable does beyond plain
      services.grafana.enable is this auto-wiring; with no backend
      enabled there is nothing for it to wire up.
    '';

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
      # Grafana's own provisioning docs: without this, a datasource
      # that disappears from the file entirely (a backend that was
      # enabled, then later disabled) is simply left untouched forever
      # -- NOT the same thing deleteDatasources below already handles
      # (that list is built from the SAME datasourceSpecs as
      # `datasources`, so a disabled backend's entry is absent from
      # BOTH lists on the next provisioning run, and nothing ever
      # revisits it again). Confirmed missing by a fresh-agent review
      # and reproduced live via a real switch-to-configuration test
      # (metrics.enable true -> false, same real generation switch an
      # operator would do): the VictoriaMetrics datasource stayed behind
      # permanently, still isDefault=true, still pointing at a port
      # nothing listens on anymore, with its type/typeName degraded
      # once declarativePlugins also stopped installing the matching
      # plugin.
      #
      # `prune: true` is Grafana's own documented mechanism for exactly
      # this case -- but confirmed live (same test, repeated after
      # adding this) that it does NOT yet actually prune anything on the
      # pinned Grafana version (13.1.6): a real, previously reported
      # upstream bug (github.com/grafana/grafana/issues/94645, "Data
      # source: pruning doesn't work"), fixed upstream only very
      # recently (grafana/grafana#83034). Added anyway -- it's the
      # textbook-correct, documented setting, costs nothing today, and
      # starts working for free the moment the pinned nixpkgs grafana
      # package picks up a version with that fix. Until then, an
      # operator who disables a backend needs to delete the stale
      # datasource manually (Grafana's own UI, or
      # `curl -X DELETE .../api/datasources/uid/<uid>`) -- this module
      # has no way to do it for them: a disabled backend's uid isn't
      # knowable from the CURRENT generation's config alone, there's
      # nothing left to build a deleteDatasources entry from.
      prune = true;
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
