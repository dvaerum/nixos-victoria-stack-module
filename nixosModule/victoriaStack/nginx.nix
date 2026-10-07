{
  config,
  lib,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.nginx;
  listen = import ./listen.nix { inherit lib; };

  # Read from Grafana's own settings rather than assumed: the consumer may
  # override them (docs/decisions/0010).
  grafanaHttpAddr = config.services.grafana.settings.server.http_addr;
  # Wildcard and IPv6 handling lives in listen.nix.
  grafanaHost = listen.connectHost grafanaHttpAddr;
  grafanaUrl = "http://${grafanaHost}:${toString config.services.grafana.settings.server.http_port}";

  # First path segments of what nginx's /victoria/ lets through: the 3
  # backends' read APIs plus the MCP routes, plus operator additions.
  readPrefixes = [
    "metrics"
    "logs"
    "traces"
    "mcp"
  ]
  # Escaped: a "." in an operator's segment must not act as a regex wildcard.
  ++ map lib.escapeRegex cfg.extraReadPaths;

  # Without these, vmauth/Grafana only ever see nginx's own loopback
  # address as the client. proxy_add_x_forwarded_for appends rather than
  # overwrites, so a client-supplied X-Forwarded-For stays in the chain
  # but nginx's own view of the peer is always the last entry.
  clientIpHeaders = ''
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  '';

  # Grafana's own official sub-path config
  # (grafana.com/tutorials/run-grafana-behind-a-proxy/), followed verbatim per
  # docs/decisions/0016. Shared by the main and websocket locations, which
  # both need the same Host header and prefix-stripping rewrite.
  grafanaLocationExtraConfig = ''
    proxy_set_header Host $host;
    ${clientIpHeaders}
    rewrite ^/grafana/(.*) /$1 break;
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Without this ordering nginx can start before its upstreams and answer
    # 502 (seen in tests/nginx.nix). vmauth has a readiness probe (vmauth.nix),
    # so `after` there means "listening"; Grafana has none (not this module's
    # service to harden, docs/decisions/0010), so it only gets ordering.
    systemd.services.nginx.after = [
      "vmauth.service"
    ]
    ++ lib.optional topCfg.grafana.enable "grafana.service";
    systemd.services.nginx.wants = [
      "vmauth.service"
    ]
    ++ lib.optional topCfg.grafana.enable "grafana.service";

    # nginx strips /grafana/ before proxying, so Grafana has to be told it is
    # served from that sub-path: its redirects and <base href> then stay under
    # /grafana/ (only the PATH of root_url matters; the host part is only used for
    # absolute links such as alert emails). serve_from_sub_path stays false because
    # the proxy already strips the prefix -- true would 301 the stripped request.
    # An operator's own value wins.
    services.grafana.settings.server.root_url = lib.mkIf topCfg.grafana.enable (
      lib.mkDefault "%(protocol)s://%(domain)s/grafana/"
    );

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
        # "victoria-stack" is a stable, documented, intentional public
        # extension point (ADR 0022), not an internal implementation
        # detail -- this module deliberately has no TLS/ACME option of
        # its own (options.nix: "deliberately has no ACME/TLS opinion").
        # An operator wanting HTTPS configures it directly on this same
        # virtualHost, e.g.:
        #
        #   services.nginx.virtualHosts."victoria-stack" = {
        #     forceSSL = true;
        #     enableACME = true;
        #   };
        #
        # NixOS's module system merges that operator config with
        # everything this module defines on the same attribute name --
        # same philosophy as ADR 0010's Grafana integration ("does NOT
        # configure services.grafana itself"). Renaming this key is a
        # breaking change for any such operator config, same severity as
        # changing an option's own name.
        locations = {
          # Reads only (docs/decisions/0025): the read prefixes are
          # proxied to vmauth, with "/victoria" stripped by hand -- a
          # regex location cannot use proxy_pass's own URI rewriting,
          # which is what the old single "/victoria/" prefix location
          # relied on. vmauth has no subpath awareness of its own: its
          # url_map regexes are written assuming "/victoria" is already
          # gone (nixosModule/victoriaStack/vmauth.nix).
          "~ ^/victoria/(${lib.concatStringsSep "|" readPrefixes})(/|$)" = {
            proxyPass = "http://${listen.connectAddr topCfg.vmauth.listenAddress}";

            # Mirrors vmauth's own tuning, never an independently-chosen
            # nginx default (docs/decisions/0016 -- "nginx mirrors what
            # it fronts").
            extraConfig = ''
              rewrite ^/victoria/(.*) /$1 break;
              proxy_connect_timeout ${topCfg.vmauth.idleConnTimeout};
              proxy_send_timeout ${topCfg.vmauth.idleConnTimeout};
              proxy_read_timeout ${topCfg.vmauth.idleConnTimeout};
              # vmauth has no body-size ceiling of its own (its request buffering
              # is a different thing), and /victoria/ only carries reads (writes go
              # to vmauth's own doors, ADR 0025): so nginx is where an anonymous
              # client's oversized body gets stopped. Unbuffered, so vmauth checks
              # the credential before the body is accepted and no temp file is
              # written; capped, so nobody streams unlimited data through nginx.
              proxy_request_buffering off;
              client_max_body_size ${cfg.maxRequestBodySize};
              ${clientIpHeaders}
            '';
          };

          # Everything else under /victoria/ -- notably every write path.
          "/victoria/" = {
            return = "404";
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
