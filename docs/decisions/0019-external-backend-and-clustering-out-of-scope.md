# 0019: External/remote backends and multi-instance clustering are
explicit, revisitable scope boundaries

## Decision

Two gaps found by review turn out to be unstated assumptions baked into
the code, not bugs:

- **External/remote backends**: `vmauth.nix`/`grafana.nix`/`nginx.nix`
  all build their routing/datasource addresses from this module's own
  sibling `listenAddress` options — there is no way to point any of them
  at an externally-hosted Victoria* backend instead of a co-located one.
- **Multi-instance/clustering**: every storage service only ever builds
  single-node CLI flags (`-storageDataPath`, `-httpListenAddr`,
  `-retentionPeriod`) — there is no `vminsert`/`vmselect`/`vmstorage`
  wiring anywhere.

Both are now explicitly documented as **out of scope for now** — not
ruled out forever, just not part of this pass — rather than left as a
silently-implicit assumption a future reader (or review pass) would have
to rediscover.

A structural seam is added regardless, in anticipation of
external-backend support specifically: each service's `options.nix`
exposes one internal `effectiveUrl`-style value (today always
`"http://${cfg.listenAddress}"`) that `vmauth.nix`/`grafana.nix`/
`nginx.nix` read instead of `listenAddress` directly. This confines any
future `remoteUrl`-style option to a single definition per service,
rather than requiring changes at three or more call sites across the
module tree.

## Why

Neither gap was ever discussed or decided against during this project's
original design (PLAN.md, ADRs 0001–0013 never mention either) — they're
implicit consequences of how the code happens to be structured, not
deliberate trade-offs. Making the boundary explicit costs one line in
PLAN.md's deferred-scope list and this ADR; actually building either
feature now would be new scope disproportionate to a bug-fixing pass.
The `effectiveUrl` seam is cheap insurance against a *future* breaking
change specifically for external-backend support, without committing to
building the feature itself today.

## Addendum: two more vmauth options considered and explicitly NOT added

Found while implementing Phase 26's vmauth option additions
(concurrency limits, backend TLS, custom headers all landed — see
`options.nix`):

- **vmauth IP filters** (`ip_filters.allow_list`/`deny_list`) are an
  **Enterprise-only vmauth feature** — confirmed directly from
  vmauth's own docs ("The Enterprise version of vmauth can be
  configured to allow/deny incoming requests via global and per-user IP
  filters"). This project packages `pkgs.victoriametrics`, the open-source
  build. Shipping a Nix option for this would silently do nothing against
  the actual binary this module defaults to — not implemented.
- **Load-balancing/failover** (`url_prefix` as a list + `load_balancing_
  policy`) requires *multiple independent backend instances* for the
  same signal — structurally the same "more than one backend" concept
  this ADR already defers under multi-instance/clustering. This
  module's `effectiveUrl` seam produces exactly one URL per signal by
  design; there is no list to load-balance across without first building
  multi-backend support, which this ADR already puts out of scope. Not
  implemented for the same reason multi-instance clustering isn't.

</content>
