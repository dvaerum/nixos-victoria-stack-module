# VictoriaLogs' syslog listeners (docs/decisions/0031), turned into flags.
#
# Every -syslog.*.<transport> flag is an array that is POSITIONAL per
# transport: entry N belongs to the Nth -syslog.listenAddr.<transport>. Each
# slot is one listener, so all arrays are generated from the one ordered list
# of active slots, and a slot with nothing to say gets a blank entry (the
# binary treats a blank as its default).
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

  # Every slot in the order it takes in its transport's arrays.
  slotsOf = syslog: [
    {
      name = "udp";
      transport = "udp";
      slot = syslog.udp;
    }
    {
      name = "tcp";
      transport = "tcp";
      slot = syslog.tcp;
    }
    # After the tcp slot: the order of the tcp arrays.
    {
      name = "tls";
      transport = "tcp";
      slot = syslog.tls;
    }
  ];

  # A slot with no address is reported by an assertion, not rendered.
  active = syslog: lib.filter (s: s.slot.enable && s.slot.ipAddress != null) (slotsOf syslog);

  onTransport = syslog: transport: lib.filter (s: s.transport == transport) (active syslog);

  # extraFlags the module's own arrays would be misaligned by: the arrays of a
  # transport that has a slot (the tls arrays belong to tcp). The unix
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
        ]
        ++ lib.optionals (transport == "tcp") [
          "syslog.tlsCertFile"
          "syslog.tlsKeyFile"
        ]
      )
    ) transports;

  # Exact names: `syslog.tls` as a prefix would also own -syslog.tlsMinVersion.
  ownedNames = syslog: lib.optional (onTransport syslog "tcp" != [ ]) "syslog.tls";

  needsLowPort = syslog: lib.any (s: s.slot.port < 1024) (active syslog);

  # A listener reachable from the network that does not encrypt.
  exposedPlain =
    syslog:
    lib.filter (
      s: s.name != "tls" && !listen.isLoopbackHost s.slot.ipAddress && !s.slot.suppressExposureWarning
    ) (active syslog);

  # Ports the slots ask to have opened, by firewall list. The tls slot is tcp.
  firewallPorts =
    syslog:
    let
      ports =
        transport:
        map (s: s.slot.port) (lib.filter (s: s.slot.openFirewall) (onTransport syslog transport));
    in
    {
      tcp = ports "tcp";
      udp = ports "udp";
    };

  tlsActive = syslog: lib.any (s: s.name == "tls") (active syslog);

  # The tls slot's files, by credential name. LoadCredential= hands the unit a
  # copy, which is why they are also what the restart watchers observe.
  tlsFiles =
    syslog:
    lib.optionalAttrs (tlsActive syslog && syslog.tls.certFile != null && syslog.tls.keyFile != null) {
      syslog-tls-cert = syslog.tls.certFile;
      syslog-tls-key = syslog.tls.keyFile;
    };

  # Flags are returned already escaped for systemd.
  mkFlags =
    syslog:
    lib.concatMap (
      transport:
      let
        entries = onTransport syslog transport;
        slots = map (s: s.slot) entries;
        # The credential flags keep their raw %d: it is systemd's own
        # credentials-directory specifier, not user text.
        tlsFlags = lib.optionals (transport == "tcp" && tlsActive syslog) (
          map (s: "-syslog.tls=${lib.boolToString (s.name == "tls")}") entries
          ++ map (
            s: "-syslog.tlsCertFile=${lib.optionalString (s.name == "tls") "%d/syslog-tls-cert"}"
          ) entries
          ++ map (s: "-syslog.tlsKeyFile=${lib.optionalString (s.name == "tls") "%d/syslog-tls-key"}") entries
        );
        fields = map (s: if s.extraFields == { } then "" else builtins.toJSON s.extraFields) slots;
      in
      map (s: "-syslog.listenAddr.${transport}=${listen.hostPort s.ipAddress s.port}") slots
      ++ lib.optionals (lib.any (f: f != "") fields) (
        map (f: "-syslog.extraFields.${transport}=${escape f}") fields
      )
      ++ tlsFlags
    ) transports;
}
