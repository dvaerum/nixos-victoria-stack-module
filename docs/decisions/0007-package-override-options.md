# 0007: Independent .package options on every service, vmauth defaults from metrics

## Decision

`metrics`, `logs`, `traces`, `vmauth`, and all three MCP server services each
get their own `mkPackageOption`-style `.package` option. `vmauth.package`
specifically defaults to `lib.mkDefault config.services.victoriaStack.metrics.package`
rather than independently to `pkgs.victoriametrics`, while remaining fully
overridable on its own.

## Why

Standard nixpkgs convention is one override option per service — letting
someone pin a different version or a custom-patched build of any single
piece without forcing a rebuild of everything else.

`vmauth` specifically ships as a bundled binary inside the exact same
`pkgs.victoriametrics` derivation as the metrics storage server (`cmd/vmauth`
in the same upstream repo, same release, same version). Defaulting its
package to track whatever `metrics.package` is already pinned to avoids a
silent, easy-to-miss version mismatch between the two in the common case
(someone bumps `metrics.package`, forgets `vmauth.package` exists as a
separate knob) — while the rare case of genuinely wanting to decouple them
stays available via the same option.
