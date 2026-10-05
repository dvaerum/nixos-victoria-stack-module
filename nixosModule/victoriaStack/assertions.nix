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
        assertion = cfg.nginx.enable -> cfg.vmauth.enable;
        message = ''
          services.victoriaStack.nginx.enable requires
          services.victoriaStack.vmauth.enable = true -- nginx only ever
          reverse-proxies to vmauth, never directly to a raw backend port,
          so there is nothing for it to point at otherwise.
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
    ];
  };
}
