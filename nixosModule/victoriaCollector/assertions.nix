{ config, lib, ... }:

let
  cfg = config.services.victoriaCollector;

  common = import ./common.nix { inherit lib; };
in
{
  config.assertions =
    let
      # A scheme-less value passes eval and only fails in `alloy run`; a query
      # or fragment ends up in the middle of the request path
      # (`/?x=1/opentelemetry/...`).
      endpointChecks =
        name: value:
        lib.optionals (value != null) [
          {
            assertion = lib.match "[Hh][Tt][Tt][Pp][Ss]?://.*" value != null;
            message = ''
              services.victoriaCollector.${name} must start with "http://" or
              "https://" (got "${value}"); a value without a scheme makes Alloy
              refuse to start.
            '';
          }
          {
            assertion = lib.match ".*[?#].*" value == null;
            message = ''
              services.victoriaCollector.${name} must not contain "?" or "#" (got
              "${value}"): the module appends its own paths to it, so a query
              string or fragment would end up in the middle of the request path.
            '';
          }
        ];
    in
    endpointChecks "writeEndpoint" cfg.writeEndpoint
    ++ endpointChecks "journaldWriteEndpoint" cfg.journaldWriteEndpoint
    ++ [
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
        assertion = common.needsAlloyOtlp cfg -> cfg.writeEndpoint != null;
        message = ''
          services.victoriaCollector.writeEndpoint is required when metrics.enable
          or traces.enable is true: set it to the base URL of the victoriaStack
          gateway, e.g. "https://victoria-stack.example.com:8443".
        '';
      }
      {
        assertion = cfg.logs.enable -> common.journaldEndpoint cfg != "";
        message = ''
          services.victoriaCollector.writeEndpoint is required when logs.enable is
          true (unless journaldWriteEndpoint is set): set it to the base URL of the
          victoriaStack gateway, e.g. "https://victoria-stack.example.com:8443".
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
