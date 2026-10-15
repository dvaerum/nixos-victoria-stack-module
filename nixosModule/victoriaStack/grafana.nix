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
  inherit (import ./exec-escape.nix { inherit lib; }) escapeEnvironment;
  restartBackoff = import ../restart-backoff.nix;

  # LoadCredential= and PathChanged= expand systemd specifiers, so a `%` in the
  # path is doubled. A `:` needs nothing: only the first one splits ID:PATH.
  readTokenPath = escapeEnvironment cfg.readTokenFile;

  # Datasources talk to vmauth's read tier, never to a backend: Grafana's
  # datasource proxy forwards any method and path for any Viewer
  # (docs/decisions/0029). Which URL vmauth dials for each backend (effectiveUrl,
  # docs/decisions/0019) stays vmauth's business.
  vmauthUrl = "http://${listen.connectAddr topCfg.vmauth.listenAddress}";

  # LoadCredential= makes the token readable by Grafana's own user whatever
  # the source file's owner. The header value must be ONE `$__file{}`
  # reference or nixpkgs warns that the token leaks into the store (its check
  # rejects a "Bearer " prefix), so the unit builds the whole header value
  # into a file first. `$__file{}` is expanded by Grafana when it loads the
  # provisioning file; only the path is in the store.
  #
  # Each tenant that opts in with `grafanaOrgId` + `readTokenFile`
  # (docs/decisions/0032-tenants-in-token-files.md) gets its own credential and header file the same way.
  # Tenant names are [a-z0-9-], so they are safe in both names as they are.
  mainToken = {
    credential = "grafana-read-token";
    headerFile = "/run/grafana/vmauth-authorization";
    path = readTokenPath;
  };
  tenantOrgs = lib.filterAttrs (
    _: t: t.grafanaOrgId != null && t.readTokenFile != null
  ) topCfg.tenants;
  tenantToken = name: {
    credential = "grafana-tenant-${name}";
    headerFile = "/run/grafana/vmauth-authorization-${name}";
    path = escapeEnvironment tenantOrgs.${name}.readTokenFile;
  };
  tenantTokens = map tenantToken (lib.attrNames tenantOrgs);
  allTokens = lib.optional (cfg.readTokenFile != null) mainToken ++ tenantTokens;

  buildAuthHeader = pkgs.writeShellApplication {
    name = "grafana-vmauth-auth-header";
    text = ''
      umask 077
    ''
    + lib.concatMapStrings (t: ''
      printf 'Bearer %s' "$(<"$CREDENTIALS_DIRECTORY/${t.credential}")" >${t.headerFile}
    '') allTokens;
  };

  mkDatasourceSpecs =
    { uid, label }:
    lib.optional topCfg.metrics.enable {
      name = label "VictoriaMetrics";
      type = "victoriametrics-metrics-datasource";
      uid = uid "victoriametrics-ds" "vm";
      url = "${vmauthUrl}/metrics";
      isDefault = true;
    }
    ++ lib.optional topCfg.logs.enable {
      name = label "VictoriaLogs";
      type = "victoriametrics-logs-datasource";
      uid = uid "victorialogs-ds" "vl";
      url = "${vmauthUrl}/logs";
      isDefault = false;
    }
    ++ lib.optional topCfg.traces.enable {
      name = label "VictoriaTraces";
      type = "jaeger";
      uid = uid "victoriatraces-ds" "vt";
      url = "${vmauthUrl}/traces/select/jaeger";
      isDefault = false;
    };

  datasourceSpecs = mkDatasourceSpecs {
    uid = main: _: main;
    label = lib.id;
  };

  # Grafana caps a uid at 40 characters; assertions.nix bounds the tenant name.
  tenantSpecs =
    name:
    map (spec: spec // { orgId = tenantOrgs.${name}.grafanaOrgId; }) (mkDatasourceSpecs {
      uid = _: short: "${short}-${name}";
      label = product: "${product} (${name})";
    });

  mkDatasource =
    spec: headerFile:
    {
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
    }
    // lib.optionalAttrs (spec ? orgId) { inherit (spec) orgId; };

  # Defaults are per org: the tenants' (orgId != 1) do not count here.
  defaultDatasources = lib.filter (d: (d.isDefault or false) && (d.orgId or 1) == 1) (
    config.services.grafana.provision.datasources.settings.datasources or [ ]
  );
in
{
  config = lib.mkIf cfg.enable {
    # Provisioning is what this option adds over plain
    # services.grafana.enable, apart from the read-token wiring below.
    # Grafana still starts fine, hence a warning, not an assertion.
    warnings =
      lib.optional (datasourceSpecs == [ ]) ''
        services.victoriaStack.grafana.enable is set, but none of
        services.victoriaStack.metrics/logs/traces.enable is, so
        no datasource is actually provisioned into Grafana. Apart from
        the read-token wiring, provisioning is all
        services.victoriaStack.grafana.enable adds over plain
        services.grafana.enable, so there is nothing to provision.
      ''
      # A warning, not an assertion: Grafana rejects this at provisioning on
      # the versions we know, but that is Grafana's call, not ours.
      ++ lib.optional (lib.length defaultDatasources > 1) ''
        services.victoriaStack.grafana.enable provisions a default datasource,
        but services.grafana.provision.datasources.settings.datasources has
        more than one with isDefault = true
        (${lib.concatStringsSep ", " (lib.sort lib.lessThan (map (d: d.name) defaultDatasources))}).
        Grafana normally refuses to provision more than one default: set
        isDefault = false on all but one (README, "Escape hatches").
      '';

    # VictoriaMetrics' own datasource plugins are used; VictoriaLogs speaks
    # LogsQL, not LogQL, so the built-in "loki" type does not fit. Traces
    # need no plugin: VictoriaTraces implements the Jaeger HTTP API, so the
    # built-in "jaeger" type works.
    services.grafana.declarativePlugins = lib.mkMerge [
      (lib.mkIf topCfg.metrics.enable [ pkgs.grafanaPlugins.victoriametrics-metrics-datasource ])
      (lib.mkIf topCfg.logs.enable [ pkgs.grafanaPlugins.victoriametrics-logs-datasource ])
    ];

    systemd.services.grafana.serviceConfig = lib.mkMerge [
      (lib.mkIf (allTokens != [ ]) {
        LoadCredential = map (t: "${t.credential}:${t.path}") allTokens;
        ExecStartPre = [ (lib.getExe buildAuthHeader) ];
      })
      # A Grafana killed inside its start-up leaves a row in its own database
      # (server_lock "oss-ac-basic-role-seeder") that fails every start for
      # 2 minutes; at nixpkgs' RestartSec=100ms that spends the start limit in
      # under a second and the unit stays failed. The backed-off retries outlast
      # the lock (docs/decisions/0015). mkDefault: the operator owns Grafana's unit.
      {
        RestartSec = lib.mkDefault 5;
        RestartSteps = lib.mkDefault restartBackoff.RestartSteps;
        RestartMaxDelaySec = lib.mkDefault restartBackoff.RestartMaxDelaySec;
      }
    ];

    # try-restart: a rotation while Grafana is stopped must not start it.
    # --no-block: the path unit only re-arms once this helper finishes, so waiting
    # for Grafana to come back would lose a token replaced in the meantime.
    systemd.services.grafana-secret-restart = lib.mkIf (allTokens != [ ]) {
      description = "Restart Grafana after its vmauth read token changed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.systemd.package}/bin/systemctl try-restart --no-block grafana.service";
        CapabilityBoundingSet = "";
      };
    };
    systemd.paths.grafana-read-token-watch = lib.mkIf (cfg.readTokenFile != null) {
      description = "Watch Grafana's vmauth read token file for replacement";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = readTokenPath;
        Unit = "grafana-secret-restart.service";
      };
    };

    systemd.paths.grafana-tenant-token-watch = lib.mkIf (tenantTokens != [ ]) {
      description = "Watch the tenants' Grafana read token files for replacement";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = map (t: t.path) tenantTokens;
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
      datasources =
        lib.forEach datasourceSpecs (spec: mkDatasource spec mainToken.headerFile)
        ++ lib.concatMap (n: map (spec: mkDatasource spec (tenantToken n).headerFile) (tenantSpecs n)) (
          lib.attrNames tenantOrgs
        );

      # Grafana >=12.2 matches an existing datasource by id+uid (not just
      # name) when provisioning re-runs, and treats a mismatch as a fatal
      # startup error rather than a soft one
      # (github.com/grafana/grafana#110740) -- confirmed on a real
      # deployment: a crash loop the moment any of these three datasources
      # went from no-pinned-uid to a pinned one. deleteDatasources forces
      # a clean delete-then-recreate by name every provisioning run,
      # sidestepping the buggy by-uid update path -- nixpkgs' own
      # documented pattern for this exact case.
      deleteDatasources =
        lib.forEach datasourceSpecs (spec: {
          inherit (spec) name;
          orgId = 1;
        })
        ++ lib.concatMap (
          n:
          map (spec: {
            inherit (spec) name orgId;
          }) (tenantSpecs n)
        ) (lib.attrNames tenantOrgs);
    };
  };
}
