{ config, lib, ... }:

let
  cfg = config.services.victoriaCollector;

  # What systemd-journal-upload is actually pointed at (config.nix).
  journaldEndpoint =
    if cfg.journaldWriteEndpoint != null then cfg.journaldWriteEndpoint else cfg.writeEndpoint;
  # scheme://host[:port][/path]; host is a name, an IPv4, or a bracketed IPv6.
  parts = lib.match "[A-Za-z][A-Za-z0-9+.-]*://([[][^]]+[]]|[^/:]+)(:[0-9]+)?(/.+)?" journaldEndpoint;
  hasPort = parts != null && builtins.elemAt parts 1 != null;
  hasPath = parts != null && builtins.elemAt parts 2 != null;
in
{
  config.assertions = [
    {
      # systemd-journal-upload appends its default :19532 after any path
      # when the URL has no explicit port, e.g.
      # "https://stack/victoria/insert/journald:19532/upload" -- the
      # gateway answers 400 and no log ever ships.
      assertion = !(cfg.logs.enable && hasPath && !hasPort);
      message = ''
        services.victoriaCollector: the endpoint logs are shipped to
        (${journaldEndpoint}) has a path but no explicit port.
        systemd-journal-upload then appends its default port after the path
        and the gateway rejects every upload with a 400. Add the port
        (e.g. "https://host:443/prefix"), or drop the path.
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
