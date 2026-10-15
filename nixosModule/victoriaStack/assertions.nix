{ config, lib, ... }:

let
  cfg = config.services.victoriaStack;
  anyBackendEnabled = cfg.metrics.enable || cfg.logs.enable || cfg.traces.enable;
  listen = import ./listen.nix { inherit lib; };
  metricsCluster = import ./metrics-cluster.nix { inherit lib; };
  clusterProcesses = metricsCluster.processes cfg.metrics;

  active = cfg.vmauth.enable && anyBackendEnabled;

  tenantNames = lib.attrNames cfg.tenants;
  # `all` is the keyword of `tenants: all` in read tokens; 0:0 is the implicit
  # default tenant of tokens without a tenant.
  badTenantNames = lib.filter (
    n: n != "all" && builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" n == null
  ) tenantNames;
  tenantsByPair = lib.groupBy (
    n:
    "accountId ${toString cfg.tenants.${n}.accountId}, projectId ${toString cfg.tenants.${n}.projectId}"
  ) tenantNames;
  duplicatePairs = lib.filterAttrs (_: names: lib.length names > 1) tenantsByPair;
  tenantOpt = n: "services.victoriaStack.tenants.${n}";
  tenantAssertions =
    map (n: {
      assertion = false;
      message = ''
        services.victoriaStack.tenants: "${n}" is not a valid tenant name. A name is 1 to 63
        characters of lower-case letters, digits and hyphens (a-z, 0-9, -), and does not
        start or end with a hyphen.
      '';
    }) badTenantNames
    ++ [
      {
        assertion = !(cfg.tenants ? all);
        message = ''
          ${tenantOpt "all"}: "all" is reserved. It is the keyword of `tenants: all` in a read
          token (every tenant), so it cannot be the name of one tenant. Pick another name.
        '';
      }
    ]
    ++ lib.mapAttrsToList (pair: names: {
      assertion = false;
      message = ''
        ${lib.concatMapStringsSep " and " tenantOpt names} both use ${pair}. Two tenants
        must not share one AccountID/ProjectID pair: they would read and write the same data.
      '';
    }) duplicatePairs
    ++ map (n: {
      assertion = false;
      message = ''
        ${tenantOpt n} has accountId 0 and projectId 0. That pair is the implicit default
        tenant (used by tokens without a tenant) and cannot be declared; give it another number.
      '';
    }) (lib.filter (n: cfg.tenants.${n}.accountId == 0 && cfg.tenants.${n}.projectId == 0) tenantNames);

  # Grafana's default organisation: where the main datasources go.
  mainGrafanaOrgId = 1;
  # A Grafana datasource uid is at most 40 characters; the tenant ones are
  # `<vm|vl|vt>-<name>`.
  maxGrafanaTenantNameLength = 37;
  halfGrafanaTenants = lib.filter (
    n: (cfg.tenants.${n}.grafanaOrgId == null) != (cfg.tenants.${n}.readTokenFile == null)
  ) tenantNames;
  grafanaTenants = lib.filter (n: cfg.tenants.${n}.grafanaOrgId != null) tenantNames;
  grafanaTenantsByOrg = lib.groupBy (n: toString cfg.tenants.${n}.grafanaOrgId) grafanaTenants;
  grafanaTenantAssertions =
    map (n: {
      assertion = false;
      message = ''
        ${tenantOpt n}: grafanaOrgId and readTokenFile go together. Set both to provision
        this tenant's datasources into its Grafana organisation, or neither
        (docs/runbooks/grafana-tenant-org.md).
      '';
    }) halfGrafanaTenants
    ++ lib.mapAttrsToList (org: names: {
      assertion = false;
      message = ''
        ${lib.concatMapStringsSep " and " tenantOpt names} both use grafanaOrgId ${org}. Each
        tenant needs its own Grafana organisation, or one tenant's datasources would
        be visible to the other's users.
      '';
    }) (lib.filterAttrs (_: names: lib.length names > 1) grafanaTenantsByOrg)
    ++ map (n: {
      assertion = false;
      message = ''
        ${tenantOpt n}.grafanaOrgId is ${toString mainGrafanaOrgId}, the organisation the main
        datasources use. Create an organisation for the tenant in Grafana and use its id.
      '';
    }) (lib.filter (n: cfg.tenants.${n}.grafanaOrgId == mainGrafanaOrgId) grafanaTenants)
    ++
      map
        (n: {
          assertion = false;
          message = ''
            ${tenantOpt n}.readTokenFile is "${cfg.tenants.${n}.readTokenFile}": it must be an
            absolute path on a single line.
          '';
        })
        (
          lib.filter (
            n:
            let
              f = cfg.tenants.${n}.readTokenFile;
            in
            f != null && builtins.match "/[^\n\r]*" f == null
          ) tenantNames
        )
    ++ map (n: {
      assertion = false;
      message = ''
        ${tenantOpt n}: the name is longer than ${toString maxGrafanaTenantNameLength} characters, too long for the Grafana
        datasource uid (at most 40 characters, `<vm|vl|vt>-<name>`) of a tenant with grafanaOrgId.
      '';
    }) (lib.filter (n: lib.stringLength n > maxGrafanaTenantNameLength) grafanaTenants);
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
      (at s.option (listen.hostPort s.slot.ipAddress s.slot.port))
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
      at "services.victoriaStack.nginx (virtualHost \"victoria-stack\")" (
        # nixpkgs leaves an explicit listen line's port null and nginx then
        # binds 80, ssl or not -- not defaultHTTPListenPort, which only feeds
        # the derived lines above.
        listen.hostPort l.addr (if l.port == null then 80 else l.port)
      )
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
    ++ lib.optionals cfg.metrics.enable (
      map (l: at l.name l.addr) (metricsCluster.extraListeners cfg.metrics)
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
  # The -httpListenAddr.* arrays (useProxyProtocol) are positional with the
  # module's own -httpListenAddr; the proxy protocol makes the readiness probe get
  # a 400. The plain -httpListenAddr itself is not owned.
  storageOwnedPrefixes = [ "httpListenAddr." ];
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
      # The process behind listenAddress is vmselect.
      inherit (clusterProcesses.select) ownedPrefixes ownedNames;
      snapshotKeyFlags = [ "snapshotAuthKey" ];
      # The process serving /snapshot is vmstorage, not the one behind listenAddress.
      snapshotFlagsOption = "storage.extraFlags";
      snapshotExtraFlags = cfg.metrics.storage.extraFlags;
      alternative = "put nginx in front of the service";
    }
    {
      name = "logs";
      active = cfg.logs.enable;
      inherit (cfg.logs) extraFlags;
      ownedPrefixes = storageOwnedPrefixes;
      ownedNames = [ ];
      snapshotKeyFlags = [ "partitionManageAuthKey" ];
      alternative = "put nginx in front of the service";
    }
    {
      name = "traces";
      active = cfg.traces.enable;
      inherit (cfg.traces) extraFlags;
      ownedPrefixes = storageOwnedPrefixes;
      ownedNames = [ ];
      snapshotKeyFlags = [ "partitionManageAuthKey" ];
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
      snapshotKeyFlags = [ ];
      alternative = "use vmauth.https / vmauth.http / listenAddress, or put nginx in front";
    }
  ];
  # The other two processes of the cluster. Kept out of flagServices: that list
  # also drives the snapshot-key check, which reads `cfg.<name>.snapshots`.
  clusterFlagServices =
    map
      (proc: {
        name = clusterProcesses.${proc}.option;
        active = cfg.metrics.enable;
        inherit (clusterProcesses.${proc}) extraFlags ownedPrefixes ownedNames;
        alternative = "use the matching typed option, or put nginx in front of the service";
      })
      [
        "insert"
        "storage"
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
  }) (flagServices ++ clusterFlagServices);

  # The snapshot oneshot POSTs to the snapshot endpoint without a key (it is a
  # loopback call), and the binary answers 401 once one of these flags is set
  # -- the timer would fail every run with no snapshot taken. The names are the
  # flags that gate that endpoint on each pinned binary (tests/storage.nix probes it).
  snapshotKeyFlagsIn =
    svc:
    lib.filter (f: lib.elem (flagName f) svc.snapshotKeyFlags) (
      svc.snapshotExtraFlags or svc.extraFlags
    );
  snapshotKeyAssertions = map (
    svc:
    let
      offending = lib.optionals (svc.active && (cfg.${svc.name}.snapshots.enable or false)) (
        snapshotKeyFlagsIn svc
      );
    in
    {
      assertion = offending == [ ];
      message = ''
        services.victoriaStack.${svc.name}.snapshots.enable is true but ${
          svc.snapshotFlagsOption or "extraFlags"
        } contains ${
          lib.concatMapStringsSep ", " (f: "`${f}`") offending
        }, which makes the snapshot endpoint require that key. The module's
        snapshot timer calls the endpoint without a key, so it would fail every
        run and no snapshot would ever be created. Instead, drop the flag, or
        set services.victoriaStack.${svc.name}.snapshots.enable = false and take
        snapshots yourself.
      '';
    }
  ) flagServices;

  # The syslog flags the slots own (syslog.nix decides which); they get their own
  # message because the generic one gives the wrong reason.
  isSyslogOwned =
    n:
    lib.any (p: lib.hasPrefix p n) (syslogLib.ownedPrefixes cfg.logs.syslog)
    || lib.elem n (syslogLib.ownedNames cfg.logs.syslog);
  syslogOwnedFlags = lib.optionals cfg.logs.enable (
    lib.filter (f: isSyslogOwned (flagName f)) cfg.logs.extraFlags
  );
  # -syslog.tls* belong to the tls listeners; the tcp arrays are shared by tcp and tls.
  syslogSlotFor =
    f:
    let
      n = flagName f;
      slots = "services.victoriaStack.logs.syslog";
      listeners = "an entry of ${slots}.listeners";
    in
    if lib.hasSuffix ".udp" n then
      "${slots}.udp or ${listeners}"
    else if lib.hasSuffix ".tcp" n then
      "${slots}.tcp, ${slots}.tls or ${listeners}"
    else
      "${slots}.tls or ${listeners}";

  syslogFlagAssertions = [
    {
      assertion = syslogOwnedFlags == [ ];
      message = ''
        services.victoriaStack.logs.extraFlags contains ${
          lib.concatMapStringsSep ", " (f: "`${f}` (use ${syslogSlotFor f})") syslogOwnedFlags
        }. The -syslog.* arrays are positional per transport: the module renders
        its own syslog listeners into them, so a hand-written entry would
        misalign them. Configure the listener through the matching option
        (services.victoriaStack.logs.syslog.udp, .tcp, .tls or .listeners) instead.
      '';
    }
  ];

  syslogEntries = syslogLib.entriesOf cfg.logs.syslog;
  enabledSyslogEntries = lib.filter (s: s.enable) syslogEntries;
  syslogListenerEntries = lib.filter (
    s: s.option == "${syslogOpt}.listeners.${s.name}"
  ) syslogEntries;
  syslogOpt = "services.victoriaStack.logs.syslog";
  syslogSlotEntries = lib.filter (s: s.option == "${syslogOpt}.${s.name}") syslogEntries;

  syslogTenants = map (s: {
    assertion = s.slot.tenant == null || cfg.tenants ? ${s.slot.tenant};
    message = ''
      ${s.option}.tenant is "${s.slot.tenant}", which is
      not a declared tenant. Declared tenants: ${
        if tenantNames == [ ] then "none" else lib.concatStringsSep ", " tenantNames
      }. Declare it
      under services.victoriaStack.tenants, or set the option to null for the default tenant.
    '';
  }) enabledSyslogEntries;

  syslogAssertions = map (s: {
    assertion = s.slot.ipAddress != null;
    message =
      if s.option == "${syslogOpt}.${s.name}" then
        ''
          ${s.option}.enable is true but
          ${s.option}.ipAddress is not set. There is
          no default address on purpose: syslog has no authentication, so nothing
          opens until you name the address to bind.
        ''
      else
        ''
          ${s.option}.ipAddress is not set. There is
          no default address on purpose: syslog has no authentication, so nothing
          opens until you name the address to bind.
        '';
  }) enabledSyslogEntries;

  # A listener's name is the key of a set, a credential name and part of a
  # path unit's name; the enabled slots' names are taken.
  validListenerName = n: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" n != null;
  syslogListenerNames = lib.attrNames cfg.logs.syslog.listeners;
  syslogNames =
    map (n: {
      assertion = false;
      message = ''
        ${syslogOpt}.listeners: "${n}" is not a valid listener name. A name is 1 to 63
        characters of lower-case letters, digits and hyphens (a-z, 0-9, -), and does not
        start or end with a hyphen.
      '';
    }) (lib.filter (n: !validListenerName n) syslogListenerNames)
    ++
      map
        (n: {
          assertion = false;
          message = ''
            ${syslogOpt}.listeners.${n} is also the name of the `${n}` slot, which is enabled:
            two listeners would share the name. Rename the listener or disable the slot.
          '';
        })
        (
          lib.filter (
            n:
            lib.elem n [
              "udp"
              "tcp"
              "tls"
            ]
            && cfg.logs.syslog.${n}.enable
          ) syslogListenerNames
        );

  # The `tls` slot: both files or neither, even while it is disabled. A
  # listener: both files exactly when its transport is tls.
  syslogTlsFiles = [
    {
      assertion =
        (cfg.logs.syslog.tls.certFile == null) == (cfg.logs.syslog.tls.keyFile == null)
        && (!cfg.logs.syslog.tls.enable || cfg.logs.syslog.tls.certFile != null);
      message = ''
        services.victoriaStack.logs.syslog.tls needs a certificate: set BOTH
        services.victoriaStack.logs.syslog.tls.certFile and .keyFile, or neither;
        one file alone is not a usable pair. This applies
        even while the slot is disabled (tls.enable = false), and an enabled slot needs both.
      '';
    }
  ]
  ++ map (s: {
    assertion = !s.tls || (s.slot.certFile != null && s.slot.keyFile != null);
    message = ''
      ${s.option} needs a certificate: a listener with transport "tls" needs BOTH
      ${s.option}.certFile and .keyFile (VictoriaLogs serves no TLS without them).
    '';
  }) syslogListenerEntries
  ++ map (s: {
    assertion = s.tls || (s.slot.certFile == null && s.slot.keyFile == null);
    message = ''
      ${s.option}.certFile and .keyFile are for transport "tls" only, and this
      listener's transport is "${s.slot.transport}". Remove them, or change the transport.
    '';
  }) syslogListenerEntries;

  syslogRequiresLogs =
    map (s: {
      assertion = !s.enable || cfg.logs.enable;
      message = ''
        ${s.option}.enable requires
        services.victoriaStack.logs.enable = true -- the listener is part of the
        VictoriaLogs process, so without it nothing would receive the syslog.
      '';
    }) syslogSlotEntries
    ++ map (s: {
      assertion = cfg.logs.enable;
      message = ''
        ${s.option} is defined but services.victoriaStack.logs.enable is not true --
        the listener is part of the VictoriaLogs process, so without it nothing would
        receive the syslog.
      '';
    }) syslogListenerEntries;

  syslogWarnings = lib.optionals cfg.logs.enable (
    map (
      s:
      let
        addr = listen.hostPort s.slot.ipAddress s.slot.port;
        option = s.option;
      in
      if s.tls then
        ''
          ${option} listens on ${addr} (tcp, TLS) and
          VictoriaLogs' syslog ingestion has no authentication (docs/decisions/0031).
          TLS encrypts but does not authenticate senders: anyone who can reach the port can still write logs.
          Restrict it with a firewall or bind a specific address, or set
          ${option}.suppressExposureWarning = true once that is deliberate.
        ''
      else
        ''
          ${option} listens on
          ${addr} (${s.transport}, unencrypted) and VictoriaLogs' syslog
          ingestion has no authentication: anyone who can reach that port can write
          log lines and create streams (docs/decisions/0031). Bind a specific
          address and restrict the port with a firewall, or set
          ${option}.suppressExposureWarning = true
          once that is deliberate.
        ''
    ) (syslogLib.exposed cfg.logs.syslog)
  );

  mcpServices = [
    "metrics"
    "logs"
    "traces"
  ];

  # The MCP servers have no authentication of their own; tool calls are gated
  # by the forwarded token at vmauth's read tier.
  mcpWarnings = lib.concatMap (
    svc:
    let
      sp = listen.split cfg.${svc}.mcp.listenAddress;
      option = "services.victoriaStack.${svc}.mcp";
    in
    lib.optional
      (mcp svc && sp != null && !listen.isLoopbackHost sp.host && !cfg.${svc}.mcp.suppressExposureWarning)
      ''
        ${option}.listenAddress is "${cfg.${svc}.mcp.listenAddress}", which is not
        loopback. The MCP server has no authentication of its own: anyone who
        can reach that port can open a session and list tools, and every tool
        call is then only as strong as the token they send, which is forwarded
        to vmauth's read tier (docs/decisions/0023). Keep it on
        loopback and use vmauth's /mcp/${svc} route, or set ${option}.suppressExposureWarning = true
        once the exposure is deliberate.
      ''
  ) mcpServices;

  # The MCP unit has no CAP_NET_BIND_SERVICE (and PrivateUsers blocks it), so a
  # privileged port would fail to bind and crash-loop. The length cap keeps
  # toIntBase10 from overflowing on an absurd digit string.
  mcpLowPortServices = lib.filter (
    svc:
    let
      sp = listen.split cfg.${svc}.mcp.listenAddress;
    in
    mcp svc && sp != null && lib.stringLength sp.port <= 5 && lib.toIntBase10 sp.port < 1024
  ) mcpServices;

  # Every address option ends up in a shell script, a systemd unit or nginx's
  # config, so it must hold only what a host:port (or a bare host) holds: that
  # is all the listen helper takes. `%` is for an IPv6 zone (`fe80::1%eth0`);
  # it is harmless in all three places once escaped.
  addressOptions =
    lib.optionals cfg.metrics.enable [
      {
        name = "metrics.listenAddress";
        value = cfg.metrics.listenAddress;
      }
    ]
    ++ lib.optionals cfg.metrics.enable [
      {
        name = "metrics.insert.listenAddress";
        value = cfg.metrics.insert.listenAddress;
      }
      {
        name = "metrics.storage.listenAddress";
        value = cfg.metrics.storage.listenAddress;
      }
    ]
    ++ lib.optionals cfg.logs.enable (
      [
        {
          name = "logs.listenAddress";
          value = cfg.logs.listenAddress;
        }
      ]
      ++ map (s: {
        name = "${lib.removePrefix "services.victoriaStack." s.option}.ipAddress";
        value = s.slot.ipAddress;
      }) (syslogLib.active cfg.logs.syslog)
    )
    ++ lib.optionals cfg.traces.enable [
      {
        name = "traces.listenAddress";
        value = cfg.traces.listenAddress;
      }
    ]
    ++
      lib.concatMap
        (
          svc:
          lib.optional (mcp svc) {
            name = "${svc}.mcp.listenAddress";
            value = cfg.${svc}.mcp.listenAddress;
          }
        )
        [
          "metrics"
          "logs"
          "traces"
        ]
    ++ lib.optionals active (
      [
        {
          name = "vmauth.listenAddress";
          value = cfg.vmauth.listenAddress;
        }
        {
          name = "vmauth.internalListenAddress";
          value = cfg.vmauth.internalListenAddress;
        }
      ]
      ++ lib.optional cfg.vmauth.https.enable {
        name = "vmauth.https.ipAddress";
        value = cfg.vmauth.https.ipAddress;
      }
      ++ lib.optional cfg.vmauth.http.enable {
        name = "vmauth.http.ipAddress";
        value = cfg.vmauth.http.ipAddress;
      }
    )
    # Not ours but read by us (nginx's proxy_pass, the collision check). Empty
    # is Grafana's "all interfaces" and is handled by listen.connectHost.
    ++ lib.optional cfg.grafana.enable {
      path = "services.grafana.settings.server.http_addr";
      value = config.services.grafana.settings.server.http_addr;
      allowEmpty = true;
    };

  # nginx's server_name, which nixpkgs also uses as the ACME certificate name,
  # so it cannot be quoted like the upstream addresses (nginx.nix).
  domainAssertions = lib.optional (cfg.nginx.enable && cfg.nginx.domain != null) {
    assertion = lib.match "[A-Za-z0-9._*-]+" cfg.nginx.domain != null;
    message = ''
      services.victoriaStack.nginx.domain = ${builtins.toJSON cfg.nginx.domain} is not a
      host name: it may contain only letters, digits and . _ * - . The value
      becomes nginx's server_name, so anything else would change the config.
    '';
  };

  addressAssertions = map (o: {
    assertion =
      (o.allowEmpty or false && o.value == "") || lib.match "[]A-Za-z0-9._:%[-]+" o.value != null;
    message = ''
      ${o.path or "services.victoriaStack.${o.name}"} = ${builtins.toJSON o.value} is not an
      address: it may contain only letters, digits and . _ : % [ ] - (a host,
      an IP address, or host:port). The value is written into unit files,
      shell scripts and the nginx config, so anything else would be executed
      or change what they mean.
    '';
  }) addressOptions;

  # dataDir lands in a tmpfiles rule, ReadWritePaths, RequiresMountsFor (space-separated
  # lists, `%` is a specifier) and -storageDataPath; a space or `%` splits or rewrites the
  # path in some of them but not others, so the directory is never created and
  # ProtectSystem=strict leaves the real path read-only.
  dataDirAssertions =
    map
      (svc: {
        assertion = lib.match "/[A-Za-z0-9._/-]+" (toString cfg.${svc}.dataDir) != null;
        message = ''
          services.victoriaStack.${svc}.dataDir = ${builtins.toJSON (toString cfg.${svc}.dataDir)} is not
          a plain absolute path: it may contain only letters, digits and . _ / - and
          must start with /. The value is written into tmpfiles rules, systemd
          path lists and the -storageDataPath flag, where a space, `%` or quote splits
          or rewrites it, so the directory would never be created.
        '';
      })
      (
        lib.filter (svc: cfg.${svc}.enable) [
          "metrics"
          "logs"
          "traces"
        ]
      );

  # Positional arrays: a single entry reaches the first listener of its transport only.
  syslogSharedArrayWarnings = lib.concatMap (
    transport:
    let
      shared = lib.filter (f: syslogLib.isSharedArray transport (flagName f)) cfg.logs.extraFlags;
      entries = syslogLib.onTransport cfg.logs.syslog transport;
    in
    lib.optional (cfg.logs.enable && lib.length entries > 1 && shared != [ ]) ''
      services.victoriaStack.logs.extraFlags contains ${lib.concatStringsSep ", " shared}, an
      array flag of VictoriaLogs' ${transport} listeners, while ${toString (lib.length entries)} syslog listeners
      share the ${transport} arrays (in order: ${
        lib.concatMapStringsSep ", " (s: "`${s.name}`") entries
      }). The array is positional: the
      first ${transport} listener (`${(lib.head entries).name}`) takes the first entry, the second
      the second, and so on, so one entry applies to the first listener only and
      the others keep the default. Give the flag once per listener in that order
      (twice for two; a blank value means the default), or use fewer listeners
      (docs/decisions/0031, docs/decisions/0036).
    ''
  ) syslogLib.transports;

  moduleAssertions =
    tenantAssertions
    ++ grafanaTenantAssertions
    ++ extraFlagsAssertions
    ++ snapshotKeyAssertions
    ++ syslogFlagAssertions
    ++ syslogAssertions
    ++ syslogTenants
    ++ syslogTlsFiles
    ++ syslogRequiresLogs
    ++ syslogNames
    ++ addressAssertions
    ++ dataDirAssertions
    ++ domainAssertions;
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
          svc.active
          && svc.selfMonitoring.enable
          && lib.any (f: lib.hasPrefix "pushmetrics." (flagName f)) svc.extraFlags
        ) services;
      in
      syslogWarnings
      ++ mcpWarnings
      ++ syslogSharedArrayWarnings
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
        assertion = mcpLowPortServices == [ ];
        message = ''
          services.victoriaStack: ${
            lib.concatMapStringsSep ", " (
              svc: "${svc}.mcp.listenAddress (${cfg.${svc}.mcp.listenAddress})"
            ) mcpLowPortServices
          } uses a port below 1024.
          The MCP unit has no CAP_NET_BIND_SERVICE, so it would fail to bind and
          crash-loop. Use a port of 1024 or above.
        '';
      }
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
          alone is not sufficient: the vmauth unit is only created when at
          least one backend is also enabled, so `vmauth.enable = true` with
          zero backends leaves nothing for nginx to reverse-proxy to.
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
      # The MCP servers forward the caller's own token to
      # vmauth's read tier (docs/decisions/0023); without vmauth they would
      # have no backend to reach.
      {
        assertion = !(cfg.metrics.enable && cfg.metrics.mcp.enable) || cfg.vmauth.enable;
        message = ''
          services.victoriaStack.metrics.mcp.enable requires services.victoriaStack.vmauth.enable = true:
          the MCP server reaches VictoriaMetrics only through vmauth's read tier, with the caller's own
          token (docs/decisions/0023-mcp-trust-boundary-extends-grafana.md).
        '';
      }
      {
        assertion = !(cfg.logs.enable && cfg.logs.mcp.enable) || cfg.vmauth.enable;
        message = ''
          services.victoriaStack.logs.mcp.enable requires services.victoriaStack.vmauth.enable = true:
          the MCP server reaches VictoriaLogs only through vmauth's read tier, with the caller's own
          token (docs/decisions/0023-mcp-trust-boundary-extends-grafana.md).
        '';
      }
      {
        assertion = !(cfg.traces.enable && cfg.traces.mcp.enable) || cfg.vmauth.enable;
        message = ''
          services.victoriaStack.traces.mcp.enable requires services.victoriaStack.vmauth.enable = true:
          the MCP server reaches VictoriaTraces only through vmauth's read tier, with the caller's own
          token (docs/decisions/0023-mcp-trust-boundary-extends-grafana.md).
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
