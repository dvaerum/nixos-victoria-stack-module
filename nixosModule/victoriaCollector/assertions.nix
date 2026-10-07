{ config, ... }:

let
  cfg = config.services.victoriaCollector;
in
{
  config.assertions = [
    {
      assertion = (cfg.metrics.enable || cfg.traces.enable) -> cfg.hostType != null;
      message = ''
        services.victoriaCollector.hostType is required when metrics.enable
        or traces.enable is true -- config.alloy.nix's host_type label
        promotion needs a real value. Not required for logs-only (that path
        has no Alloy pipeline to attach the label in).
      '';
    }
  ];
}
