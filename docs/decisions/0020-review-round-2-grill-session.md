# 0020: Second review-and-fix round — grill-session resolutions

Four independent fresh-agent reviewers (split by area: storage; vmauth/
grafana/nginx; mcp/collector; cross-cutting architecture/CI) each did a
second, deeper critical pass, explicitly looking for test gaps, missing
configurability, and bad design — not just correctness bugs. Every
genuine finding was then resolved one at a time with the project owner
(a `/grill-me` session) before any code changed. The real design
decisions from that session are each their own ADR (0014–0019); this one
indexes the round and covers the smaller items that didn't need a
dedicated ADR.

## Resolved via dedicated ADRs
- 0014 — `openIngestPaths` write-tier semantics + new redundant-auth warning
- 0015 — systemd hardening baseline + `wait4x` readiness, extended beyond storage
- 0016 — nginx mirrors what it fronts (vmauth timeouts/body-size, Grafana official config)
- 0017 — port renumbering (victoriaStack services only)
- 0018 — CI automation race fix (single workflow, job dependency)
- 0019 — external-backend/clustering scope boundaries + `effectiveUrl` seam

## Resolved without a dedicated ADR (smaller, no real trade-off)
- **Secret-type fix**: `vmauth.{adminPasswordFile,readTokensFile,
  writeTokensFile}` and `victoriaCollector.writeTokenFile` retyped
  `types.path` → `types.str`. Interpolating a Nix `path` into a string
  forces a store copy at eval time — either an eval crash (the secret
  doesn't exist yet at build time, the normal case under ADR 0008's own
  `LoadCredential=` design) or a plaintext-secret leak into the
  world-readable Nix store (if it happens to exist on the build machine).
  Same bug, same fix, in the one other place it existed — no design
  question, just completing a fix already agreed for vmauth.
- **`manageTmpfiles` option** (storage services, default `true`): plain
  escape hatch for the every-boot ownership-reassertion tmpfiles rule.
  Deliberately **no warning** when set to `false` — unlike 0014's
  warning (two settings actively contradicting each other), this is a
  single option with nothing else to conflict with; a warning here would
  be second-guessing an operator's deliberate choice, not catching a
  config mismatch.
- **Systemd resource limits** (storage services): no new
  `memoryMax`/`cpuQuota` options. `systemd.services.<name>.serviceConfig`
  already does this generically for every NixOS service; the unit names
  (`victoriametrics`/`victorialogs`/`victoriatraces`) are now documented
  as a stable contract a consumer can target directly.
- **Grafana datasource tuning** (`isDefault`, `jsonData`): no new
  options. `services.grafana.provision.datasources.settings` is already a
  fully generic NixOS option a consumer can set directly; this module's
  own assignment to it is a plain, mergeable (non-`mkForce`) definition.
  One documented nuance: the three datasources this module provisions are
  list items, which don't merge per-entry — a consumer wanting to tweak
  one of *this module's own* three entries specifically needs to
  `lib.mkForce` the whole list and reconstruct it, rather than patching
  one field.
- **`traces.retentionPeriod` documentation**: fixed to state the real
  upstream default (7 days) instead of the previously-published, factually
  wrong "effectively unbounded" (the correct fact was already known,
  correctly, in `traces.nix`'s own code comment — only the generated,
  user-facing option description was wrong).
- **New default-wiring architecture diagram**: added (README/
  `docs/architecture.md`) showing which services bind loopback-only vs.
  not by default, and the full connection topology — requested directly
  in place of a warning for exposing a storage backend without auth,
  since that combination is a deliberate, informed operator choice (the
  option's own docs already say so), not a config mismatch warranting a
  nudge.

## New options added (vmauth / alloy / mcp — inert unless configured)
Concurrency/rate limiting, backend TLS, and custom header injection for
vmauth; OTLP exporter TLS/CA-trust and `sending_queue` retry/backoff
tuning for Alloy; `logLevel`/`logFormat`/`disabledTools` passthrough for
each MCP service. Every one of these defaults to leaving the underlying
flag unset entirely when not configured, so behavior matches whatever
vmauth/Alloy/the MCP binaries already default to — consistent with ADR
0002's "opt-in everything" philosophy.

IP allow/deny lists and load-balancing/failover backend lists for
vmauth were considered during this same review and explicitly NOT
added — see ADR 0019's addendum for why (IP filters are an
Enterprise-only vmauth feature that would silently no-op on the OSS
package; load-balancing needs more than one backend instance per
signal, the same "more than one backend" shape already deferred under
clustering).
</content>
