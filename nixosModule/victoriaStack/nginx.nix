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
  #
  # Bracket-wrapped only when it looks like a bare IPv6 literal (contains
  # ":" and isn't already bracketed) -- nginx's proxy_pass (like every
  # other URL-parsing consumer) requires "[::1]:3000", not "::1:3000",
  # or it can't tell where the host ends and the port begins. Unreached
  # by any test with this module's own defaults (IPv4 127.0.0.1), but a
  # real break for an operator who sets http_addr to a bare IPv6
  # literal -- a legitimate, if unusual, override of a fully generic
  # upstream Grafana option this module doesn't otherwise constrain.
  grafanaHttpAddr = config.services.grafana.settings.server.http_addr;
  grafanaHost =
    if lib.hasInfix ":" grafanaHttpAddr && !lib.hasPrefix "[" grafanaHttpAddr then
      "[${grafanaHttpAddr}]"
    else
      grafanaHttpAddr;
  grafanaUrl = "http://${grafanaHost}:${toString config.services.grafana.settings.server.http_port}";

  # First path segments of what nginx's /victoria/ lets through: the 3
  # backends' read APIs plus the MCP routes, plus operator additions.
  readPrefixes = [
    "metrics"
    "logs"
    "traces"
    "mcp"
  ]
  ++ cfg.extraReadPaths;

  # Grafana's own official sub-path config
  # (grafana.com/tutorials/run-grafana-behind-a-proxy/), fetched live and
  # followed verbatim per docs/decisions/0016 -- never improvised. Shared
  # between the main location and the dedicated websocket one below,
  # since both need the same Host header + prefix-stripping rewrite.
  # Without these, vmauth/Grafana only ever see nginx's own loopback
  # address as the client. proxy_add_x_forwarded_for appends rather than
  # overwrites, so a client-supplied X-Forwarded-For stays in the chain
  # but nginx's own view of the peer is always the last entry.
  clientIpHeaders = ''
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  '';

  grafanaLocationExtraConfig = ''
    proxy_set_header Host $host;
    ${clientIpHeaders}
    rewrite ^/grafana/(.*) /$1 break;
  '';
in
{
  config = lib.mkIf cfg.enable {
    # nginx reverse-proxies to both vmauth ("/victoria/") and, when
    # enabled, Grafana directly ("/grafana/") -- found missing by a
    # fresh-agent review: nginx had no systemd ordering on either at
    # all, both just `wantedBy multi-user.target` with nothing linking
    # them, so systemd was free to start nginx concurrently with (or
    # before) either backend on every boot. Confirmed directly:
    # `systemctl show nginx.service -p After` on a real running
    # container listed only generic boot targets, neither vmauth.service
    # nor grafana.service anywhere in it -- and tests/nginx.nix's own
    # existing comments already document hitting the resulting race
    # live ("nginx's proxy_pass raced it and got 502 Bad Gateway"),
    # previously worked around only in the TEST SCRIPT
    # (wait_for_open_port), never fixed at the unit level. vmauth now
    # has its own TCP readiness probe (vmauth.nix) so this `after` means
    # "actually listening", not just "process forked" -- Grafana has no
    # such probe of its own (not this module's service to harden,
    # docs/decisions/0010), so that half only gets ordering, the same
    # residual race the Grafana-datasource tests already document and
    # work around with wait_until_succeeds.
    systemd.services.nginx.after = [
      "vmauth.service"
    ]
    ++ lib.optional topCfg.grafana.enable "grafana.service";
    systemd.services.nginx.wants = [
      "vmauth.service"
    ]
    ++ lib.optional topCfg.grafana.enable "grafana.service";

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
            proxyPass = "http://${topCfg.vmauth.listenAddress}";

            # Mirrors vmauth's own tuning, never an independently-chosen
            # nginx default (docs/decisions/0016 -- "nginx mirrors what
            # it fronts").
            extraConfig = ''
              rewrite ^/victoria/(.*) /$1 break;
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
