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

  # systemd expands specifiers (%h) and ${VAR} in Exec* lines even inside
  # quotes, and reads C escapes there too (`\"` loses its backslash); user text
  # must reach the process literally.
  esc = lib.replaceStrings [ "\\" "%" "$" ] [ "\\\\" "%%" "$$" ];
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
    lib.filter (s: !listen.isLoopbackHost s.slot.ipAddress && !s.slot.suppressExposureWarning) (
      active syslog
    );

  # Flags are returned already escaped for systemd.
  mkFlags =
    syslog:
    lib.concatMap (
      transport:
      let
        slots = map (s: s.slot) (onTransport syslog transport);
        fields = map (s: if s.extraFields == { } then "" else builtins.toJSON s.extraFields) slots;
      in
      map (s: "-syslog.listenAddr.${transport}=${listen.hostPort s.ipAddress s.port}") slots
      ++ lib.optionals (lib.any (f: f != "") fields) (
        map (f: "-syslog.extraFields.${transport}=${esc f}") fields
      )
    ) transports;
}
