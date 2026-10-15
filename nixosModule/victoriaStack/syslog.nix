# VictoriaLogs' syslog listeners (docs/decisions/0031, 0035), turned into flags.
#
# Every -syslog.*.<transport> flag is an array that is POSITIONAL per
# transport: entry N belongs to the Nth -syslog.listenAddr.<transport>. The
# slots (udp, tcp, tls) and the named `listeners` are one list of entries, so
# all arrays are generated from it and a listener with nothing to say gets a
# blank entry (the binary treats a blank as its default; a listener without
# tenant renders the default tenant 0:0 once another listener of its
# transport has one).
{ lib }:
let
  listen = import ./listen.nix { inherit lib; };

  inherit (import ./exec-escape.nix { inherit lib; }) escape;
in
rec {
  transports = [
    "tcp"
    "udp"
  ];

  # Every listener in the order it takes in its transport's arrays: the slots
  # (udp, tcp, tls), then the named listeners by name (attrNames sorts). A tls
  # listener is a tcp one with TLS on, so it shares the tcp arrays.
  entriesOf =
    syslog:
    let
      path = "services.victoriaStack.logs.syslog";
      slot = name: transport: {
        inherit name transport;
        tls = name == "tls";
        inherit (syslog.${name}) enable;
        slot = syslog.${name};
        option = "${path}.${name}";
      };
    in
    [
      (slot "udp" "udp")
      (slot "tcp" "tcp")
      # After the tcp slot: the order of the tcp arrays.
      (slot "tls" "tcp")
    ]
    ++ map (name: {
      inherit name;
      transport = if syslog.listeners.${name}.transport == "udp" then "udp" else "tcp";
      tls = syslog.listeners.${name}.transport == "tls";
      enable = true;
      slot = syslog.listeners.${name};
      option = "${path}.listeners.${name}";
    }) (lib.attrNames syslog.listeners);

  # A listener with no address is reported by an assertion, not rendered.
  active = syslog: lib.filter (s: s.enable && s.slot.ipAddress != null) (entriesOf syslog);

  # `host:port` of every rendered listener.
  listenAddrs = syslog: map (s: listen.hostPort s.slot.ipAddress s.slot.port) (active syslog);

  onTransport = syslog: transport: lib.filter (s: s.transport == transport) (active syslog);

  # extraFlags the module's own arrays would be misaligned by: the arrays of a
  # transport that has a listener (the tls arrays belong to tcp). The unix
  # transport and the scalar flags (-syslog.timezone, -syslog.tlsMinVersion)
  # stay free.
  ownedPrefixes =
    syslog:
    lib.concatMap (
      transport:
      lib.optionals (onTransport syslog transport != [ ]) (
        [
          "syslog.listenAddr.${transport}"
          "syslog.extraFields.${transport}"
          "syslog.tenantID.${transport}"
        ]
        ++ lib.optionals (transport == "tcp") [
          "syslog.tlsCertFile"
          "syslog.tlsKeyFile"
        ]
      )
    ) transports;

  # Exact names: `syslog.tls` as a prefix would also own -syslog.tlsMinVersion.
  ownedNames = syslog: lib.optional (onTransport syslog "tcp" != [ ]) "syslog.tls";

  # Listeners of one transport share its arrays: an array flag of that
  # transport (and the tls cipher list, which follows the tcp listeners) that
  # the module does not render itself. The owned arrays are refused instead.
  isSharedArray =
    transport: name:
    (lib.hasPrefix "syslog." name && lib.hasSuffix ".${transport}" name)
    && !(
      lib.hasPrefix "syslog.listenAddr." name
      || lib.hasPrefix "syslog.extraFields." name
      || lib.hasPrefix "syslog.tenantID." name
    )
    || (transport == "tcp" && name == "syslog.tlsCipherSuites");

  needsLowPort = syslog: lib.any (s: s.slot.port < 1024) (active syslog);

  # A listener reachable from the network, unless its warning is suppressed.
  exposed =
    syslog:
    lib.filter (s: !listen.isLoopbackHost s.slot.ipAddress && !s.slot.suppressExposureWarning) (
      active syslog
    );

  # Ports the listeners ask to have opened, by firewall list. tls is tcp.
  firewallPorts =
    syslog:
    let
      ports =
        transport:
        lib.unique (
          map (s: s.slot.port) (lib.filter (s: s.slot.openFirewall) (onTransport syslog transport))
        );
    in
    {
      tcp = ports "tcp";
      udp = ports "udp";
    };

  # A tls listener's credential. The `tls` slot keeps the plain names, so a
  # listener of that name renders the same unit.
  credential =
    kind: s: if s.name == "tls" then "syslog-tls-${kind}" else "syslog-tls-${kind}-${s.name}";

  tlsEntries = syslog: lib.filter (s: s.tls) (active syslog);

  tlsActive = syslog: tlsEntries syslog != [ ];

  # The tls listeners' files, by credential name. LoadCredential= hands the
  # unit a copy, which is why they are also what the restart watchers observe.
  tlsFiles =
    syslog:
    lib.foldl' (
      acc: s:
      acc
      // lib.optionalAttrs (s.slot.certFile != null && s.slot.keyFile != null) {
        ${credential "cert" s} = s.slot.certFile;
        ${credential "key" s} = s.slot.keyFile;
      }
    ) { } (tlsEntries syslog);

  # `<accountId>:<projectId>` of a listener's tenant (the array item format of
  # -syslog.tenantID.*); 0:0 is the binary's own default tenant. An unknown name
  # is reported by an assertion, so it falls back instead of aborting evaluation.
  tenantIdOf =
    tenants: name:
    let
      t = if name == null then null else tenants.${name} or null;
    in
    if t == null then "0:0" else "${toString t.accountId}:${toString t.projectId}";

  # Flags are returned already escaped for systemd.
  mkFlags =
    tenants: syslog:
    lib.concatMap (
      transport:
      let
        entries = onTransport syslog transport;
        slots = map (s: s.slot) entries;
        # The credential flags keep their raw %d: it is systemd's own
        # credentials-directory specifier, not user text.
        tlsFlags = lib.optionals (transport == "tcp" && tlsActive syslog) (
          map (s: "-syslog.tls=${lib.boolToString s.tls}") entries
          ++ map (s: "-syslog.tlsCertFile=${lib.optionalString s.tls "%d/${credential "cert" s}"}") entries
          ++ map (s: "-syslog.tlsKeyFile=${lib.optionalString s.tls "%d/${credential "key" s}"}") entries
        );
        # Only rendered once a listener of the transport names a tenant, so a
        # stack without tenants keeps its flags unchanged.
        tenantIds = map (s: tenantIdOf tenants s.tenant) slots;
        fields = map (s: if s.extraFields == { } then "" else builtins.toJSON s.extraFields) slots;
      in
      map (s: "-syslog.listenAddr.${transport}=${escape (listen.hostPort s.ipAddress s.port)}") slots
      ++ lib.optionals (lib.any (f: f != "") fields) (
        map (f: "-syslog.extraFields.${transport}=${escape f}") fields
      )
      ++ lib.optionals (lib.any (s: s.tenant != null) slots) (
        map (t: "-syslog.tenantID.${transport}=${t}") tenantIds
      )
      ++ tlsFlags
    ) transports;
}
