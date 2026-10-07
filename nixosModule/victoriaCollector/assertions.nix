{ config, lib, ... }:

let
  cfg = config.services.victoriaCollector;

  common = import ./common.nix { inherit lib; };
in
{
  config.assertions = [
    {
      # A zero-length interval makes Alloy exit at start, like a timeout longer
      # than the interval does (config.alloy.nix handles that one).
      assertion = cfg.metrics.scrapeInterval == null || common.durationNs cfg.metrics.scrapeInterval > 0;
      message = ''
        services.victoriaCollector.metrics.scrapeInterval must be longer than
        zero (got "${toString cfg.metrics.scrapeInterval}").
      '';
    }
    {
      # `..` would let a path pass config.nix's "is it under /var/lib/alloy/"
      # test while pointing outside it.
      assertion = !(lib.any (c: c == "..") (lib.splitString "/" (toString cfg.queue.directory)));
      message = ''
        services.victoriaCollector.queue.directory (${toString cfg.queue.directory})
        must not contain a ".." component; write the real path.
      '';
    }
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
