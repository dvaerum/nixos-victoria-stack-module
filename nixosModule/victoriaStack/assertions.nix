{ config, lib, ... }:

let
  cfg = config.services.victoriaStack;
  anyBackendEnabled = cfg.metrics.enable || cfg.logs.enable || cfg.traces.enable;

  # Every listener this module would bind -- vmauth only counts when it
  # actually activates (vmauth.nix needs a backend too).
  enabledListenAddrs =
    lib.optional cfg.metrics.enable cfg.metrics.listenAddress
    ++ lib.optional cfg.logs.enable cfg.logs.listenAddress
    ++ lib.optional cfg.traces.enable cfg.traces.listenAddress
    ++ lib.optional (cfg.vmauth.enable && anyBackendEnabled) cfg.vmauth.listenAddress
    ++ lib.optional (cfg.vmauth.enable && anyBackendEnabled) cfg.vmauth.internalListenAddress
    ++ lib.optional (cfg.vmauth.enable && anyBackendEnabled && cfg.vmauth.https.enable) (
      "${cfg.vmauth.https.ipAddress}:${toString cfg.vmauth.https.port}"
    )
    ++ lib.optional (cfg.vmauth.enable && anyBackendEnabled && cfg.vmauth.http.enable) (
      "${cfg.vmauth.http.ipAddress}:${toString cfg.vmauth.http.port}"
    )
    ++ lib.optional (cfg.metrics.enable && cfg.metrics.mcp.enable) cfg.metrics.mcp.listenAddress
    ++ lib.optional (cfg.logs.enable && cfg.logs.mcp.enable) cfg.logs.mcp.listenAddress
    ++ lib.optional (cfg.traces.enable && cfg.traces.mcp.enable) cfg.traces.mcp.listenAddress;
in
{
  config = {
    # Auto-enable whenever any backend is on (vmauth hands all the auth for
    # the stack), but stay a soft default so an explicit
    # `vmauth.enable = false` (trusting a network boundary instead of a
    # credential) remains a deliberate, informed override -- see
    # docs/decisions/0002-opt-in-everything.md. A `true` value here has no
    # effect at all when no backend is enabled (nothing for vmauth to
    # front); that's enforced structurally in vmauth.nix (Phase 6), not
    # here.
    services.victoriaStack.vmauth.enable = lib.mkDefault anyBackendEnabled;

    # Each service pushing its own metrics is on whenever the metrics
    # database it would push into is enabled (docs/decisions/0026).
    services.victoriaStack.metrics.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.logs.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.traces.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.vmauth.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;

    # selfMonitoring is on by default, so an operator who already passes
    # their own -pushmetrics.* flags through extraFlags would silently get
    # BOTH sets (the flags are arrays, so the service pushes to two URLs with
    # two label sets). Warn rather than fail: it is the operator's call.
    warnings =
      let
        services = [
          {
            name = "metrics";
            active = cfg.metrics.enable;
            inherit (cfg.metrics) selfMonitoring extraFlags;
          }
          {
            name = "logs";
            active = cfg.logs.enable;
            inherit (cfg.logs) selfMonitoring extraFlags;
          }
          {
            name = "traces";
            active = cfg.traces.enable;
            inherit (cfg.traces) selfMonitoring extraFlags;
          }
          {
            name = "vmauth";
            active = cfg.vmauth.enable && anyBackendEnabled;
            inherit (cfg.vmauth) selfMonitoring extraFlags;
          }
        ];
        conflicts = lib.filter (
          svc:
          svc.active && svc.selfMonitoring.enable && lib.any (lib.hasPrefix "-pushmetrics.") svc.extraFlags
        ) services;
      in
      map (svc: ''
        services.victoriaStack.${svc.name}.extraFlags contains -pushmetrics.*
        flags, but services.victoriaStack.${svc.name}.selfMonitoring.enable is
        also true (it is on by default whenever metrics.enable is) -- the
        service would push its metrics twice, to both targets. Either drop
        your own flags, or set
        services.victoriaStack.${svc.name}.selfMonitoring.enable = false.
      '') conflicts;

    assertions = [
      {
        assertion = lib.length enabledListenAddrs == lib.length (lib.unique enabledListenAddrs);
        message = ''
          services.victoriaStack: two enabled services are configured with
          the same listenAddress -- the second one to start would fail to
          bind and crash-loop. Enabled listenAddresses: ${lib.concatStringsSep ", " enabledListenAddrs}
        '';
      }
      {
        assertion = cfg.nginx.enable -> (cfg.vmauth.enable && anyBackendEnabled);
        message = ''
          services.victoriaStack.nginx.enable requires
          services.victoriaStack.vmauth.enable = true AND at least one of
          metrics/logs/traces.enable = true -- nginx only ever
          reverse-proxies to vmauth, never directly to a raw backend port,
          so there is nothing for it to point at otherwise. vmauth.enable
          alone is not sufficient: vmauth.nix's own config block only
          activates when a backend is also enabled (see the comment above
          on the vmauth.enable default), so `vmauth.enable = true` with
          zero backends produces no actual vmauth service for nginx to
          reverse-proxy to.
        '';
      }
      {
        assertion =
          !(
            cfg.logs.retentionMaxDiskSpaceUsageBytes != null && cfg.logs.retentionMaxDiskUsagePercent != null
          );
        message = ''
          services.victoriaStack.logs.retentionMaxDiskSpaceUsageBytes and
          services.victoriaStack.logs.retentionMaxDiskUsagePercent are
          mutually exclusive -- set only one of them.
        '';
      }
      {
        assertion =
          !(
            cfg.traces.retentionMaxDiskSpaceUsageBytes != null
            && cfg.traces.retentionMaxDiskUsagePercent != null
          );
        message = ''
          services.victoriaStack.traces.retentionMaxDiskSpaceUsageBytes and
          services.victoriaStack.traces.retentionMaxDiskUsagePercent are
          mutually exclusive -- set only one of them.
        '';
      }
      {
        assertion =
          !(
            cfg.metrics.selfMonitoring.enable
            || cfg.logs.selfMonitoring.enable
            || cfg.traces.selfMonitoring.enable
            || cfg.vmauth.selfMonitoring.enable
          )
          || cfg.metrics.enable;
        message = ''
          services.victoriaStack.*.selfMonitoring.enable needs
          services.victoriaStack.metrics.enable = true -- each service pushes
          its own metrics into the local VictoriaMetrics instance, so there is
          nothing to push to otherwise.
        '';
      }
      {
        assertion = cfg.metrics.mcp.enable -> cfg.metrics.enable;
        message = ''
          services.victoriaStack.metrics.mcp.enable requires
          services.victoriaStack.metrics.enable = true -- an mcp server
          proxies to one specific backend instance by construction; if
          metrics itself is disabled there is nothing for it to connect to.
        '';
      }
      {
        assertion = cfg.logs.mcp.enable -> cfg.logs.enable;
        message = ''
          services.victoriaStack.logs.mcp.enable requires
          services.victoriaStack.logs.enable = true -- an mcp server
          proxies to one specific backend instance by construction; if logs
          itself is disabled there is nothing for it to connect to.
        '';
      }
      {
        assertion = cfg.traces.mcp.enable -> cfg.traces.enable;
        message = ''
          services.victoriaStack.traces.mcp.enable requires
          services.victoriaStack.traces.enable = true -- an mcp server
          proxies to one specific backend instance by construction; if
          traces itself is disabled there is nothing for it to connect to.
        '';
      }
      {
        assertion = cfg.grafana.enable -> config.services.grafana.enable;
        message = ''
          services.victoriaStack.grafana.enable requires
          services.grafana.enable = true -- this module only provisions
          datasources into an already-enabled Grafana (docs/decisions/0010),
          it never enables the Grafana service itself; without it there is
          nothing to provision datasources into, and nginx would otherwise
          reverse-proxy "/grafana/" at a service that was never started.
        '';
      }
      {
        assertion =
          !cfg.vmauth.https.enable
          || (
            let
              filesSet = cfg.vmauth.https.certFile != null || cfg.vmauth.https.keyFile != null;
              filesBoth = cfg.vmauth.https.certFile != null && cfg.vmauth.https.keyFile != null;
              acme = cfg.vmauth.https.acmeCertName != null;
            in
            if acme then !filesSet else filesBoth
          );
        message = ''
          services.victoriaStack.vmauth.https.enable needs a certificate:
          set BOTH vmauth.https.certFile and vmauth.https.keyFile, OR
          vmauth.https.acmeCertName -- not both, and not just one of the
          two files.
        '';
      }
      {
        assertion =
          !(cfg.vmauth.https.enable && cfg.vmauth.https.acmeCertName != null)
          || (config.security.acme.certs ? ${cfg.vmauth.https.acmeCertName});
        message = ''
          services.victoriaStack.vmauth.https.acmeCertName names
          "${toString cfg.vmauth.https.acmeCertName}", but there is no
          security.acme.certs."${toString cfg.vmauth.https.acmeCertName}" entry --
          this module reads an ACME cert the operator already defines, it
          never creates one.
        '';
      }
      {
        assertion = (cfg.vmauth.backendTls.certFile == null) == (cfg.vmauth.backendTls.keyFile == null);
        message = ''
          services.victoriaStack.vmauth.backendTls.certFile and .keyFile
          must be set together or not at all -- they form one mTLS client
          certificate pair passed to vmauth as
          -backend.tlsCertFile/-backend.tlsKeyFile; supplying only one half
          produces an incomplete client certificate vmauth's underlying Go
          TLS stack will reject at connection time, not at eval time.
        '';
      }
    ];
  };
}
