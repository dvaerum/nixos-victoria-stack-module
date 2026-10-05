# 0001: VictoriaMetrics/Logs/Traces built from scratch, not wrapped

## Decision

`services.victoriaStack.{metrics,logs,traces}` are independent systemd units
built directly on `pkgs.victoriametrics`'s binaries. They do not import or
configure nixpkgs' own `services.victoriametrics`/`services.victorialogs`/
`services.victoriatraces` modules at all.

## Why

Both real deployments this module generalizes from (`deployment-a`,
`deployment-b`) independently hit the same wall and independently built the same
workaround: nixpkgs' own modules hardcode `-storageDataPath=/var/lib/<service>`
with no option to override it, and hardcode `DynamicUser = true`, whose
`StateDirectory` handling tries to migrate a pre-existing `/var/lib/<name>`
into a private DynamicUser-managed copy on every start — confirmed to fail
outright ("Device or resource busy") once that path is an externally-managed
mount (a ZFS dataset in both real cases). Reconstructing `ExecStart` from
nixpkgs source to fix one hardcoded flag, twice, in two unrelated repos, is
the actual confirmed cost of wrapping these modules.

Building from scratch means `dataDir` and `dynamicUser` are first-class,
independent options from day one — no `ExecStart` reconstruction, no
fragility against a future nixpkgs module refactor changing the exact flags
this project would otherwise need to keep mirroring.

## Also fixes

- `victorialogs` has no first-class `retentionPeriod` option upstream at all
  (confirmed by reading nixpkgs source) — ours does.
- `vmauth` has no nixpkgs module at all (it's a bundled binary in the
  `victoriametrics` package) — ours is a real, first-class part of the
  option surface, not a hand-rolled unit bolted onto someone's
  `configuration.nix`.
