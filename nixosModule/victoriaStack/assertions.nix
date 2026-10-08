{ config, lib, ... }:

let
  cfg = config.services.victoriaStack;
  anyBackendEnabled = cfg.metrics.enable || cfg.logs.enable || cfg.traces.enable;
  listen = import ./listen.nix { inherit lib; };

  active = cfg.vmauth.enable && anyBackendEnabled;
  mcp = svc: cfg.${svc}.enable && cfg.${svc}.mcp.enable;
  # Listeners are tcp unless stated: a udp and a tcp socket may share a port.
  at = name: addr: {
    inherit name addr;
    proto = "tcp";
  };
  syslogLib = import ./syslog.nix { inherit lib; };
  syslogListeners = lib.optionals cfg.logs.enable (
    map (
      s:
      (at "services.victoriaStack.logs.syslog.${s.name}" (listen.hostPort s.slot.ipAddress s.slot.port))
      // {
        proto = s.transport;
      }
    ) (syslogLib.active cfg.logs.syslog)
  );

  # nginx's listen lines for the module's own virtualHost, resolved the way
  # nixpkgs' nginx module does (vhost.listen, else defaultListen, else the
  # listenAddresses, each given the default HTTP/TLS port). Unix sockets don't
  # take part.
  nginxListeners =
    let
      ngx = config.services.nginx;
      vhost = ngx.virtualHosts."victoria-stack";
      hasSsl = vhost.onlySSL || vhost.addSSL || vhost.forceSSL;
      withPorts =
        lines:
        lib.optionals (hasSsl || vhost.rejectSSL) (
          map (l: { port = ngx.defaultSSLListenPort; } // l) (lib.filter (l: l.ssl or true) lines)
        )
        ++ lib.optionals (!vhost.onlySSL) (
          map (l: { port = ngx.defaultHTTPListenPort; } // l) (lib.filter (l: !(l.ssl or false)) lines)
        );
      lines =
        if vhost.listen != [ ] then
          vhost.listen
        else if ngx.defaultListen != [ ] then
          withPorts (map (lib.filterAttrs (_: v: v != null)) ngx.defaultListen)
        else
          withPorts (
            map (addr: { inherit addr; }) (
              if vhost.listenAddresses != [ ] then vhost.listenAddresses else ngx.defaultListenAddresses
            )
          );
    in
    map (
      l:
      at "services.victoriaStack.nginx (virtualHost \"victoria-stack\")" (listen.hostPort l.addr l.port)
    ) (lib.filter (l: !(lib.hasPrefix "unix:" l.addr)) lines);

  # Every listener this module would bind, labelled so a collision can name
  # both sides -- vmauth only counts when it actually activates (vmauth.nix
  # needs a backend too).
  enabledListeners =
    lib.optional cfg.metrics.enable (
      at "services.victoriaStack.metrics.listenAddress" cfg.metrics.listenAddress
    )
    ++ lib.optional cfg.logs.enable (
      at "services.victoriaStack.logs.listenAddress" cfg.logs.listenAddress
    )
    ++ lib.optional cfg.traces.enable (
      at "services.victoriaStack.traces.listenAddress" cfg.traces.listenAddress
    )
    ++ lib.optional active (at "services.victoriaStack.vmauth.listenAddress" cfg.vmauth.listenAddress)
    ++ lib.optional active (
      at "services.victoriaStack.vmauth.internalListenAddress" cfg.vmauth.internalListenAddress
    )
    ++ lib.optional (active && cfg.vmauth.https.enable) (
      at "services.victoriaStack.vmauth.https" (
        listen.hostPort cfg.vmauth.https.ipAddress cfg.vmauth.https.port
      )
    )
    ++ lib.optional (active && cfg.vmauth.http.enable) (
      at "services.victoriaStack.vmauth.http" (
        listen.hostPort cfg.vmauth.http.ipAddress cfg.vmauth.http.port
      )
    )
    ++ lib.optional (mcp "metrics") (
      at "services.victoriaStack.metrics.mcp.listenAddress" cfg.metrics.mcp.listenAddress
    )
    ++ lib.optional (mcp "logs") (
      at "services.victoriaStack.logs.mcp.listenAddress" cfg.logs.mcp.listenAddress
    )
    ++ lib.optional (mcp "traces") (
      at "services.victoriaStack.traces.mcp.listenAddress" cfg.traces.mcp.listenAddress
    )
    ++ syslogListeners
    ++ lib.optionals cfg.nginx.enable nginxListeners
    ++ lib.optional cfg.grafana.enable (
      at "services.grafana.settings.server (http_addr, http_port)" (
        listen.hostPort config.services.grafana.settings.server.http_addr config.services.grafana.settings.server.http_port
      )
    );

  # Two listeners collide when they cannot both be bound -- the same address, a
  # wildcard (`0.0.0.0:p`, `:p`, `[::]:p`) next to an address it covers, or
  # `localhost` next to a loopback address.
  collisions = lib.concatLists (
    lib.imap0 (
      i: a:
      map (b: { inherit a b; }) (
        # Same name = one party's own lines (nginx's 0.0.0.0 and [::0] pair), which it binds
        # together on purpose.
        lib.filter (b: a.name != b.name && listen.overlapsProto a.proto a.addr b.proto b.addr) (
          lib.drop (i + 1) enabledListeners
        )
      )
    ) enabledListeners
  );
  anyListenersCollide = collisions != [ ];

  # extraFlags that change where or how a service is reached. The module's
  # readiness check and self-push talk plain http to the known address and
  # path, so these would break them silently. The flag NAME decides, whether
  # given as `-f`, `--f`, `-f=v` or `--f=v`; Go flags are case-sensitive.
  flagName = f: lib.head (lib.splitString "=" (lib.removePrefix "-" (lib.removePrefix "-" f)));
  addressingOrAuthPrefixes = [
    "http.pathPrefix"
    "tls"
    "httpAuth."
  ];
  flagServices = [
    {
      name = "metrics";
      active = cfg.metrics.enable;
      inherit (cfg.metrics) extraFlags;
      ownedPrefixes = [ ];
      ownedNames = [ ];
      alternative = "put nginx in front of the service";
    }
    {
      name = "logs";
      active = cfg.logs.enable;
      inherit (cfg.logs) extraFlags;
      ownedPrefixes = syslogLib.ownedPrefixes cfg.logs.syslog;
      ownedNames = syslogLib.ownedNames cfg.logs.syslog;
      alternative = "put nginx in front of the service (for the -syslog.* flags the syslog.udp / syslog.tcp options own, use those)";
    }
    {
      name = "traces";
      active = cfg.traces.enable;
      inherit (cfg.traces) extraFlags;
      ownedPrefixes = [ ];
      ownedNames = [ ];
      alternative = "put nginx in front of the service";
    }
    {
      name = "vmauth";
      inherit active;
      inherit (cfg.vmauth) extraFlags;
      # The module owns the listener arrays (positional with its -tls* arrays).
      ownedPrefixes = [
        "httpListenAddr"
        "httpInternalListenAddr"
      ];
      ownedNames = [ ];
      alternative = "use vmauth.https / vmauth.http / listenAddress, or put nginx in front";
    }
  ];
  forbiddenFlags =
    svc:
    lib.optionals svc.active (
      lib.filter (
        f:
        let
          n = flagName f;
        in
        lib.any (p: lib.hasPrefix p n) (addressingOrAuthPrefixes ++ svc.ownedPrefixes)
        || lib.elem n svc.ownedNames
      ) svc.extraFlags
    );

  extraFlagsAssertions = map (svc: {
    assertion = forbiddenFlags svc == [ ];
    message = ''
      services.victoriaStack.${svc.name}.extraFlags contains ${
        lib.concatMapStringsSep ", " (f: "`${f}`") (forbiddenFlags svc)
      }, which changes how the service is addressed or authenticated. The
      module's readiness check and its self-push use plain http on the known
      address and path, so such a flag breaks them. Instead, ${svc.alternative}.
    '';
  }) flagServices;

  syslogSlotNames = [
    "udp"
    "tcp"
    "tls"
  ];

  syslogAssertions = map (slot: {
    assertion = !cfg.logs.syslog.${slot}.enable || cfg.logs.syslog.${slot}.ipAddress != null;
    message = ''
      services.victoriaStack.logs.syslog.${slot}.enable is true but
      services.victoriaStack.logs.syslog.${slot}.ipAddress is not set. There is
      no default address on purpose: syslog has no authentication, so nothing
      opens until you name the address to bind.
    '';
  }) syslogSlotNames;

  syslogTlsFiles = [
    {
      assertion =
        (cfg.logs.syslog.tls.certFile == null) == (cfg.logs.syslog.tls.keyFile == null)
        && (!cfg.logs.syslog.tls.enable || cfg.logs.syslog.tls.certFile != null);
      message = ''
        services.victoriaStack.logs.syslog.tls needs a certificate: set BOTH
        services.victoriaStack.logs.syslog.tls.certFile and .keyFile, and set them
        whenever the slot is enabled; one file alone is not a usable pair.
      '';
    }
  ];

  syslogRequiresLogs = map (slot: {
    assertion = !cfg.logs.syslog.${slot}.enable || cfg.logs.enable;
    message = ''
      services.victoriaStack.logs.syslog.${slot}.enable requires
      services.victoriaStack.logs.enable = true -- the listener is part of the
      VictoriaLogs process, so without it nothing would receive the syslog.
    '';
  }) syslogSlotNames;

  syslogWarnings = lib.optionals cfg.logs.enable (
    map (s: ''
      services.victoriaStack.logs.syslog.${s.name} listens on
      ${listen.hostPort s.slot.ipAddress s.slot.port} (${s.transport}, unencrypted) and VictoriaLogs' syslog
      ingestion has no authentication: anyone who can reach that port can write
      log lines and create streams (docs/decisions/0031). Bind a specific
      address and restrict the port with a firewall, or set
      services.victoriaStack.logs.syslog.${s.name}.suppressExposureWarning = true
      once that is deliberate.
    '') (syslogLib.exposedPlain cfg.logs.syslog)
  );

  moduleAssertions = extraFlagsAssertions ++ syslogAssertions ++ syslogTlsFiles ++ syslogRequiresLogs;
in
{
  config = {
    # Auto-enable whenever any backend is on (vmauth hands all the auth for
    # the stack), but stay a soft default so an explicit
    # `vmauth.enable = false` (trusting a network boundary instead of a
    # credential) remains a deliberate, informed override -- see
    # docs/decisions/0002-opt-in-everything.md. A `true` value here has no
    # effect at all when no backend is enabled (nothing for vmauth to
    # front); that's enforced structurally in vmauth.nix, not
    # here.
    services.victoriaStack.vmauth.enable = lib.mkDefault anyBackendEnabled;

    # Each service pushing its own metrics is on whenever the metrics
    # database it would push into is enabled (docs/decisions/0026).
    services.victoriaStack.metrics.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.logs.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.traces.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;
    services.victoriaStack.vmauth.selfMonitoring.enable = lib.mkDefault cfg.metrics.enable;

    # selfMonitoring is on by default, so an operator who already passes
    # their own -pushmetrics.* flags through extraFlags would silently get
    # BOTH sets (the flags are arrays, so the service pushes to two URLs with
    # two label sets). Warn rather than fail: it is the operator's call.
    warnings =
      let
        services = [
          {
            name = "metrics";
            active = cfg.metrics.enable;
            inherit (cfg.metrics) selfMonitoring extraFlags;
          }
          {
            name = "logs";
            active = cfg.logs.enable;
            inherit (cfg.logs) selfMonitoring extraFlags;
          }
          {
            name = "traces";
            active = cfg.traces.enable;
            inherit (cfg.traces) selfMonitoring extraFlags;
          }
          {
            name = "vmauth";
            active = cfg.vmauth.enable && anyBackendEnabled;
            inherit (cfg.vmauth) selfMonitoring extraFlags;
          }
        ];
        conflicts = lib.filter (
          svc:
          svc.active && svc.selfMonitoring.enable && lib.any (lib.hasPrefix "-pushmetrics.") svc.extraFlags
        ) services;
      in
      syslogWarnings
      ++ map (svc: ''
        services.victoriaStack.${svc.name}.extraFlags contains -pushmetrics.*
        flags, but services.victoriaStack.${svc.name}.selfMonitoring.enable is
        also true (it is on by default whenever metrics.enable is) -- the
        service would push its metrics twice, to both targets. Either drop
        your own flags, or set
        services.victoriaStack.${svc.name}.selfMonitoring.enable = false.
      '') conflicts;

    assertions = moduleAssertions ++ [
      {
        assertion = !anyListenersCollide;
        message = ''
          services.victoriaStack: two enabled listeners are configured with
          the same listenAddress -- the second one to start would fail to
          bind and crash-loop. Colliding: ${
            lib.concatMapStringsSep "; " (
              c: "${c.a.name} (${c.a.addr}) and ${c.b.name} (${c.b.addr})"
            ) collisions
          }
        '';
      }
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
        assertion =
          !(
            cfg.logs.retentionMaxDiskSpaceUsageBytes != null && cfg.logs.retentionMaxDiskUsagePercent != null
          );
        message = ''
          services.victoriaStack.logs.retentionMaxDiskSpaceUsageBytes and
          services.victoriaStack.logs.retentionMaxDiskUsagePercent are
          mutually exclusive -- set only one of them.
        '';
      }
      {
        assertion =
          !(
            cfg.traces.retentionMaxDiskSpaceUsageBytes != null
            && cfg.traces.retentionMaxDiskUsagePercent != null
          );
        message = ''
          services.victoriaStack.traces.retentionMaxDiskSpaceUsageBytes and
          services.victoriaStack.traces.retentionMaxDiskUsagePercent are
          mutually exclusive -- set only one of them.
        '';
      }
      {
        assertion =
          !(
            cfg.metrics.selfMonitoring.enable
            || cfg.logs.selfMonitoring.enable
            || cfg.traces.selfMonitoring.enable
            || cfg.vmauth.selfMonitoring.enable
          )
          || cfg.metrics.enable;
        message = ''
          services.victoriaStack.*.selfMonitoring.enable needs
          services.victoriaStack.metrics.enable = true -- each service pushes
          its own metrics into the local VictoriaMetrics instance, so there is
          nothing to push to otherwise.
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
      # Grafana's datasource proxy forwards any method and path to the
      # datasource URL for every Viewer, so the datasources must go through
      # vmauth's read tier with a token (docs/decisions/0029). Nothing is
      # provisioned without a backend, so nothing is required either.
      {
        assertion = !(cfg.grafana.enable && anyBackendEnabled) || cfg.vmauth.enable;
        message = ''
          services.victoriaStack.grafana.enable requires vmauth.enable = true:
          Grafana's datasources reach the backends only through vmauth's read
          tier, because a datasource pointing straight at a backend lets every
          Grafana Viewer write and delete data
          (docs/decisions/0029-grafana-datasources-through-vmauth-read-tier.md).
        '';
      }
      {
        assertion = !(cfg.grafana.enable && anyBackendEnabled) || cfg.grafana.readTokenFile != null;
        message = ''
          services.victoriaStack.grafana.readTokenFile must be set when
          grafana.enable is on: it is the bearer token Grafana's datasources
          send to vmauth's read tier
          (docs/decisions/0029-grafana-datasources-through-vmauth-read-tier.md).
        '';
      }
      {
        assertion = !(cfg.grafana.enable && anyBackendEnabled) || cfg.vmauth.readTokensFile != null;
        message = ''
          services.victoriaStack.grafana.enable needs vmauth.readTokensFile:
          the token in grafana.readTokenFile must be listed there, or vmauth
          rejects every datasource query
          (docs/decisions/0029-grafana-datasources-through-vmauth-read-tier.md).
        '';
      }
      {
        assertion =
          !cfg.vmauth.https.enable
          || (
            let
              filesSet = cfg.vmauth.https.certFile != null || cfg.vmauth.https.keyFile != null;
              filesBoth = cfg.vmauth.https.certFile != null && cfg.vmauth.https.keyFile != null;
              acme = cfg.vmauth.https.acmeCertName != null;
            in
            if acme then !filesSet else filesBoth
          );
        message = ''
          services.victoriaStack.vmauth.https.enable needs a certificate:
          set BOTH vmauth.https.certFile and vmauth.https.keyFile, OR
          vmauth.https.acmeCertName -- not both, and not just one of the
          two files.
        '';
      }
      {
        assertion =
          !(cfg.vmauth.https.enable && cfg.vmauth.https.acmeCertName != null)
          || (config.security.acme.certs ? ${cfg.vmauth.https.acmeCertName});
        message = ''
          services.victoriaStack.vmauth.https.acmeCertName names
          "${toString cfg.vmauth.https.acmeCertName}", but there is no
          security.acme.certs."${toString cfg.vmauth.https.acmeCertName}" entry --
          this module reads an ACME cert the operator already defines, it
          never creates one.
        '';
      }
      {
        assertion = (cfg.vmauth.backendTls.certFile == null) == (cfg.vmauth.backendTls.keyFile == null);
        message = ''
          services.victoriaStack.vmauth.backendTls.certFile and .keyFile
          must be set together or not at all -- they form one mTLS client
          certificate pair passed to vmauth as
          -backend.TLSCertFile/-backend.TLSKeyFile; supplying only one half
          produces an incomplete client certificate vmauth's underlying Go
          TLS stack will reject at connection time, not at eval time.
        '';
      }
    ];
  };
}
