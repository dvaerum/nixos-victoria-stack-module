{ config, lib, ... }:

let
  cfg = config.services.victoriaStack;
  anyBackendEnabled = cfg.metrics.enable || cfg.logs.enable || cfg.traces.enable;
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

    assertions = [
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
