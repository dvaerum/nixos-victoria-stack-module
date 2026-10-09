# One value behind a storage unit's readiness probe (`wait4x --timeout`) and
# its TimeoutStartSec, so the unit can never be killed by systemd before its own
# probe has given up.
#
# The grammar is the intersection of what wait4x (Go durations) and systemd
# both read, measured: `5min` is refused by wait4x, `1.5m` is Go-only, and a
# zero timeout means "no timeout" to wait4x.
{ lib }:
rec {
  grammar = "([0-9]+[smh])+";

  seconds =
    s:
    lib.foldl' (
      total: part:
      let
        n = lib.toIntBase10 (builtins.elemAt part 0);
        unit = builtins.elemAt part 1;
      in
      total
      +
        n
        * {
          s = 1;
          m = 60;
          h = 3600;
        }
        .${unit}
    ) 0 (builtins.filter builtins.isList (builtins.split "([0-9]+)([smh])" s));

  type = lib.types.addCheck (lib.types.strMatching grammar) (s: seconds s > 0);

  # A minute above the probe: with both equal they would expire together and
  # Restart=on-failure would loop a slow start.
  unitTimeout =
    s:
    let
      total = seconds s + 60;
    in
    if lib.mod total 60 == 0 then "${toString (total / 60)}min" else "${toString total}s";
}
