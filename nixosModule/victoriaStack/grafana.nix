{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.grafana;
  listen = import ./listen.nix { inherit lib; };

  # Datasources talk to vmauth's read tier, never to a backend: Grafana's
  # datasource proxy forwards any method and path for any Viewer
  # (docs/decisions/0029). vmauth.effectiveUrl hops (docs/decisions/0019) stay
  # vmauth's business.
  vmauthUrl = "http://${listen.connectAddr topCfg.vmauth.listenAddress}";

  # LoadCredential= makes the token readable by Grafana's own user whatever
  # the source file's owner. The header value must be ONE `$__file{}`
  # reference or nixpkgs warns that the token leaks into the store (its check
  # rejects a "Bearer " prefix), so the unit builds the whole header value
  # into a file first. `$__file{}` is expanded by Grafana when it loads the
  # provisioning file; only the path is in the store.
  tokenCredential = "grafana-read-token";
  headerFile = "/run/grafana/vmauth-authorization";
  buildAuthHeader = pkgs.writeShellApplication {
    name = "grafana-vmauth-auth-header";
    text = ''
      umask 077
      printf 'Bearer %s' "$(<"$CREDENTIALS_DIRECTORY/${tokenCredential}")" >${headerFile}
    '';
  };

  datasourceSpecs =
    lib.optional topCfg.metrics.enable {
      name = "VictoriaMetrics";
      type = "victoriametrics-metrics-datasource";
      uid = "victoriametrics-ds";
      url = "${vmauthUrl}/metrics";
      isDefault = true;
    }
    ++ lib.optional topCfg.logs.enable {
      name = "VictoriaLogs";
      type = "victoriametrics-logs-datasource";
      uid = "victorialogs-ds";
      url = "${vmauthUrl}/logs";
      isDefault = false;
    }
    ++ lib.optional topCfg.traces.enable {
      name = "VictoriaTraces";
      type = "jaeger";
      uid = "victoriatraces-ds";
      url = "${vmauthUrl}/traces/select/jaeger";
      isDefault = false;
    };
in
{
  config = lib.mkIf cfg.enable {
    # Datasource provisioning is all this option adds over plain
    # services.grafana.enable, so with no backend enabled it does nothing.
    # Grafana still starts fine, hence a warning, not an assertion.
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

    systemd.services.grafana.serviceConfig = lib.mkIf (cfg.readTokenFile != null) {
      LoadCredential = [ "${tokenCredential}:${cfg.readTokenFile}" ];
      ExecStartPre = [ (lib.getExe buildAuthHeader) ];
    };

    # try-restart: a rotation while Grafana is stopped must not start it.
    systemd.services.grafana-secret-restart = lib.mkIf (cfg.readTokenFile != null) {
      description = "Restart Grafana after its vmauth read token changed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.systemd.package}/bin/systemctl try-restart grafana.service";
        CapabilityBoundingSet = "";
      };
    };
    systemd.paths.grafana-read-token-watch = lib.mkIf (cfg.readTokenFile != null) {
      description = "Watch Grafana's vmauth read token file for replacement";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.readTokenFile;
        Unit = "grafana-secret-restart.service";
      };
    };

    services.grafana.provision.datasources.settings = {
      apiVersion = 1;
      # Without prune, a datasource whose backend was later disabled stays
      # behind forever: deleteDatasources is built from the same
      # datasourceSpecs, so the disabled entry is absent from both lists.
      # Grafana documents `prune` for this, but it does not work on the pinned
      # Grafana (github.com/grafana/grafana/issues/94645), so stale
      # datasources must be deleted by hand (Grafana's UI, or
      # `curl -X DELETE .../api/datasources/uid/<uid>`); a disabled backend's
      # uid is no longer knowable from the current config. Kept so it takes
      # effect once the pinned Grafana picks up the upstream fix
      # (grafana/grafana#83034).
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
        jsonData.httpHeaderName1 = "Authorization";
        secureJsonData.httpHeaderValue1 = "$__file{${headerFile}}";
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
