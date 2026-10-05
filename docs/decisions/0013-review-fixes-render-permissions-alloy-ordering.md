# 0013: Fixes from independent fresh-agent review

Two independent reviewers (no shared context with the implementation
session, grounded only in PLAN.md/ADRs/the repo) each found real,
confirmed bugs. Both are fixed here; captured as one ADR since they're
one review round's outcome, not separate design decisions.

## Alloy write-token `EnvironmentFile=` raced its own `preStart`

`alloy.service`'s `preStart` wrote `/run/alloy/write-token.env`, which
`environmentFile=` also named. systemd resolves `EnvironmentFile=`
before every exec in the unit -- including `ExecStartPre=` itself --
so the file never existed yet: `alloy.service` failed on every boot
whenever `writeTokenFile` was set (the realistic/default case).
Empirically reproduced by the reviewer with a minimal unit of the same
shape before being reported.

This is the exact trap 0012 already fixes for `systemd-journal-upload`
-- just not applied here too. Fixed the same way: a dedicated oneshot
(`victoria-collector-alloy-write-token`, `before`/`wantedBy` on
`alloy.service`) renders the file, never `alloy.service`'s own
`preStart`.

## Rendered credential files were world-readable

Three render sites wrote secrets to `/run/*` files with the default
systemd umask (0022 -> mode 644): vmauth's `config.json` (every bearer
token + the admin password), Alloy's `write-token.env`, and
journal-upload's `50-write-token.conf`. `LoadCredential=`'s own staging
directory is correctly mode-restricted by systemd; every place that
copied *out of* it into a new file dropped that restriction, undermining
the "never world-readable" intent behind 0006/0008/0012.

Fixed: `UMask = "0177"` on vmauth's unit (covers both `ExecStartPre=`
and `ExecStart=`; vmauth's own process is the one that reads
`config.json` directly, not systemd, so DynamicUser ownership must be
preserved -- UMask narrows the mode without changing the owner). The
two oneshots (journal-upload's existing one, Alloy's new one above)
both run as root and `chmod 600` explicitly after each write, since
systemd itself (not the target unit's process) is what reads an
`EnvironmentFile=`/drop-in via root privilege -- no ownership
constraint there.

## Other findings fixed in the same pass

- `mcp.nix`: each `mcp-victoria<name>.service` had no explicit
  `after=` ordering on its own backend unit, cross-confirmed
  independently by both reviewers. Added (`victoriametrics.service` /
  `victorialogs.service` / `victoriatraces.service` respectively).
- `nginx.nix`: the `/grafana/` proxy target hardcoded
  `127.0.0.1:3000` instead of reading Grafana's actual
  `settings.server.http_addr`/`http_port` -- every other backend
  address in this module is read dynamically; this one wasn't. Fixed.
- `assertions.nix`: added an assertion that
  `victoriaStack.grafana.enable` requires `services.grafana.enable`
  -- the prior state let nginx wire `/grafana/` at a Grafana that was
  never actually started, with no assertion to catch it.
- `vmauth.nix`: MCP `src_paths` regexes (`/mcp/metrics.*` etc.) matched
  on the whole path with no path-separator boundary, unlike every
  sibling read-route regex (`/metrics/.*`) -- tightened to
  `/mcp/metrics(/.*)?` etc. No live misroute existed, but the
  inconsistency was real.
- Test gaps closed: `openIngestPaths = []` closing writes entirely
  even with `requireAuthForWrites = false` (the one vmauth guard with
  no prior coverage), traces-alone sufficiency for
  `needsAlloyOtlp`'s OR logic (previously only tested in combination
  with metrics), and the HTTPS branch of `journaldWriteEndpoint`
  (dummy-cert + CA-bundle rendering -- previously only the plain-HTTP
  path was exercised anywhere in this repo).

## Reviewed, found sound, no change needed

Both reviewers independently traced `vmauth.nix`'s `url_map`
construction against vmauth's real upstream `drop_src_path_prefix_parts`
semantics (worked examples, not assumed) and found the routing correct
for every enabled-backend combination; `config.alloy.nix`'s generated
Alloy config has no dangling component references in any of the four
metrics/traces enable combinations; `tests/lib.nix`'s
`services.victoriaStack`-prefix assertion/warning filter is neither too
broad nor too narrow for this module's own message set; all three MCP
packages' hashes/versions/`vendorHash = null` claims were independently
re-verified against live upstream sources, not just trusted from
comments.
