{
  config,
  lib,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.nginx;

  # Grafana's own official reverse-proxy address -- same discipline as
  # every other backend address in this module, read dynamically rather
  # than assumed (nixpkgs' real defaults: 127.0.0.1:3000, but
  # consumer-overridable per docs/decisions/0010).
  grafanaUrl = "http://${config.services.grafana.settings.server.http_addr}:${toString config.services.grafana.settings.server.http_port}";

  # Grafana's own official sub-path config
  # (grafana.com/tutorials/run-grafana-behind-a-proxy/), fetched live and
  # followed verbatim per docs/decisions/0016 -- never improvised. Shared
  # between the main location and the dedicated websocket one below,
  # since both need the same Host header + prefix-stripping rewrite.
  grafanaLocationExtraConfig = ''
    proxy_set_header Host $host;
    rewrite ^/grafana/(.*) /$1 break;
  '';
in
{
  config = lib.mkIf cfg.enable {
    services.nginx = {
      enable = true;

      # Required at the http{} level for Grafana Live (WebSocket) to
      # resolve $connection_upgrade at all -- Grafana's own official doc's
      # exact block, nixpkgs' nginx module has no first-class option for
      # a bare map{} directive outside a server/location block.
      appendHttpConfig = lib.mkIf topCfg.grafana.enable ''
        map $http_upgrade $connection_upgrade {
          default upgrade;
          ''' close;
        }
      '';

      virtualHosts."victoria-stack" = {
        locations = {
          "/victoria/" = {
            # vmauth has no subpath awareness of its own -- its url_map
            # regexes are written assuming "/victoria/" is already
            # stripped (nixosModule/victoriaStack/vmauth.nix), so this
            # keeps the trailing-slash-stripping proxy_pass behavior.
            proxyPass = "http://${topCfg.vmauth.listenAddress}/";

            # Mirrors vmauth's own tuning, never an independently-chosen
            # nginx default (docs/decisions/0016 -- "nginx mirrors what
            # it fronts").
            extraConfig = ''
              proxy_connect_timeout ${topCfg.vmauth.idleConnTimeout};
              proxy_send_timeout ${topCfg.vmauth.idleConnTimeout};
              proxy_read_timeout ${topCfg.vmauth.idleConnTimeout};
              # vmauth itself has no body-size ceiling of its own --
              # confirmed from its real upstream docs: it only has
              # request body BUFFERING
              # (-requestBufferSize/-maxQueueDuration, a different
              # concept -- freeing backend connections sooner on slow
              # uploads, not limiting max size). nginx shouldn't
              # introduce a ceiling vmauth doesn't have.
              client_max_body_size 0;
            '';
          };
        }
        // lib.optionalAttrs topCfg.grafana.enable {
          "/grafana/" = {
            proxyPass = grafanaUrl;
            extraConfig = grafanaLocationExtraConfig;
          };

          # Grafana's own docs mark this as REQUIRED for Grafana Live
          # (WebSocket-based real-time dashboard/alerting updates) to
          # work at all through a sub-path reverse proxy -- without it,
          # Grafana Live silently fails to connect.
          "/grafana/api/live/" = {
            proxyPass = grafanaUrl;
            extraConfig = ''
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
              ${grafanaLocationExtraConfig}
            '';
          };
        };
      }
      // lib.optionalAttrs (cfg.domain != null) {
        serverName = cfg.domain;
      };
    };
  };
}
