# Small definitions shared by the collector's option, config and assertion files
# (each used to compute its own copy).
{ lib }:
rec {
  needsAlloyOtlp = cfg: cfg.metrics.enable || cfg.traces.enable;

  # What systemd-journal-upload is actually pointed at.
  journaldEndpoint =
    cfg: if cfg.journaldWriteEndpoint != null then cfg.journaldWriteEndpoint else cfg.writeEndpoint;

  # Drops trailing slashes so `<base>/path` never becomes `<base>//path`.
  stripTrailingSlashes =
    s:
    let
      m = lib.match "(.*[^/])/*" s;
    in
    if m == null then s else builtins.head m;

  # A Go-style duration as Alloy accepts it ("30s", "1m30s", "500ms"). Interpolated
  # into the generated config, so the charset is restricted rather than escaped.
  durationRegex = "([0-9]+(ns|us|ms|s|m|h))+";
  durationType = lib.types.strMatching durationRegex;

  # Total length of a duration (already matching durationRegex) in nanoseconds.
  durationNs =
    d:
    let
      unit = {
        ns = 1;
        us = 1000;
        ms = 1000000;
        s = 1000000000;
        m = 60000000000;
        h = 3600000000000;
      };
      parts = builtins.filter builtins.isList (builtins.split "([0-9]+)(ns|us|ms|s|m|h)" d);
      number = n: lib.toInt (builtins.head (lib.match "0*([0-9]+)" n));
    in
    lib.foldl' (acc: p: acc + number (builtins.elemAt p 0) * unit.${builtins.elemAt p 1}) 0 parts;
}
