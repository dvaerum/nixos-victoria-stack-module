{
  config,
  lib,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.nginx;
in
{
  config = lib.mkIf cfg.enable {
    services.nginx = {
      enable = true;

      virtualHosts."victoria-stack" = {
        locations."/victoria/" = {
          # vmauth has no subpath awareness of its own -- its url_map
          # regexes are written assuming "/victoria/" is already
          # stripped (nixosModule/victoriaStack/vmauth.nix), so this
          # keeps the trailing-slash-stripping proxy_pass behavior.
          proxyPass = "http://${topCfg.vmauth.listenAddress}/";
        };
      }
      // lib.optionalAttrs topCfg.grafana.enable {
        # No trailing slash on the proxy_pass target: Grafana's own
        # serve_from_sub_path (if the consumer sets it, entirely their
        # own services.grafana.* config per docs/decisions/0010) means
        # it registers routes INCLUDING the "/grafana/" prefix and
        # expects to see it in the incoming request path.
        locations."/grafana/".proxyPass = "http://127.0.0.1:3000";
      }
      // lib.optionalAttrs (cfg.domain != null) {
        serverName = cfg.domain;
      };
    };
  };
}
