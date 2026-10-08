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
  # Every slot in the order it takes in its transport's arrays.
  slotsOf = syslog: [
    {
      transport = "udp";
      inherit (syslog) udp;
    }
    {
      transport = "tcp";
      inherit (syslog) tcp;
    }
  ];

  # A slot with no address is reported by an assertion, not rendered.
  active =
    syslog:
    lib.filter (s: s.${s.transport}.enable && s.${s.transport}.ipAddress != null) (slotsOf syslog);

  needsLowPort = syslog: lib.any (s: s.${s.transport}.port < 1024) (active syslog);

  # Flags are returned already escaped for systemd.
  mkFlags =
    syslog:
    lib.concatMap
      (
        transport:
        let
          slots = map (s: s.${transport}) (lib.filter (s: s.transport == transport) (active syslog));
          fields = map (s: if s.extraFields == { } then "" else builtins.toJSON s.extraFields) slots;
        in
        map (s: "-syslog.listenAddr.${transport}=${listen.hostPort s.ipAddress s.port}") slots
        ++ lib.optionals (lib.any (f: f != "") fields) (
          map (f: "-syslog.extraFields.${transport}=${esc f}") fields
        )
      )
      [
        "tcp"
        "udp"
      ];
}
