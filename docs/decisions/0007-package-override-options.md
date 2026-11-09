# 0007: Independent .package options on every service, vmauth defaults from metrics

## Decision

`metrics`, `logs`, `traces`, `vmauth`, and all three MCP server services each
get their own `mkPackageOption`-style `.package` option. `vmauth.package`
specifically defaults to `lib.mkDefault config.services.victoriaStack.metrics.package`
rather than independently to `pkgs.victoriametrics`, while remaining fully
overridable on its own. When metrics is disabled (vmauth runs on logs or
traces alone) it falls back to `pkgs.victoriametrics`, since
`metrics.package` has no value then.

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

Update: `metrics.package` is now the cluster package, which has no vmauth, so
`vmauth.package` defaults to `pkgs.victoriametrics` again and no longer follows
`metrics.package`. A check keeps the two versions equal
([0033](./0033-metrics-cluster-replaces-single-node.md)).

## Update: vmauth is built from the cluster tag

The claim above that vmauth is not part of the cluster tag was wrong about the
source: `app/vmauth` is byte-identical in `v<version>` and `v<version>-cluster`
for every mainline release checked; the cluster package just never built it.
`packages/victoriametrics-cluster` now builds all four binaries, and
`vmauth.package` defaults to that same derivation as `metrics.package`, so the
two cannot skew. The version check is removed, and with it the deadlock where a
nixpkgs bump moved `pkgs.victoriametrics` before the cluster package could
follow (four failed weekly bumps in a row). `vmauth.package` stays overridable
(`pkgs.victoriametrics` still works).

The floor is vmauth 1.138.0: the module's rendered config uses `access_log`,
which 1.136.0 rejects at start and which is accepted from 1.138.0. A
`vmauth.package` with a version below it triggers a warning; a package with no
version is not checked. Cluster and vmauth versions one release apart passed the
module's vmauth tests in both directions.
