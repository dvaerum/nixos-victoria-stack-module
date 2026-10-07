# Round 4 detailed implementation plan

Companion to PLAN.md's terse Phase 44-54 entries -- this file has the full
technical spec for each phase (exact options, exact file changes, exact
tests) so implementation can proceed without re-deriving design decisions
already made in the grill session. PLAN.md stays the terse historical
record of what happened; this file is the upfront, implementation-ready
spec of what's about to happen. Delete or archive once Round 4 ships (its
content becomes history at that point, same as this project's established
PLAN.md-is-retrospective convention).

Same execution discipline as every prior phase: red-first where a test
can meaningfully fail before the fix, gate with `nix flake check -L`
(backgrounded + polled), nixfmt-clean, commit per phase, push.

---

## Phase 44: test gap fixes

No new options, no behavior changes except where noted -- pure test
additions/corrections. Each item below: file, what the test sets up, what
it asserts.

1. **Alloy TLS/retry: real container-boot, not eval-only.**
   `tests/collector.nix`. Today's `alloy-tls-and-retry-options-are-inert-unless-configured`
   only string-matches rendered config text. Add a cross-container test:
   stack side's vmauth gets a real TLS-terminating reverse proxy in front
   (reuse the `selfSignedCert` pattern from `tests/nginx.nix`'s
   `http-and-https-coexist-on-the-stable-name`, or a bare `nginx`
   container importing just that virtualHost shape) -- collector's
   `alloy.tlsCaFile` points at the same CA, `writeEndpoint` uses
   `https://`. Assert the metric genuinely lands (same roundtrip
   assertion style as `metrics-roundtrip-across-containers`).

2. **`queue.directory` outside StateDirectory: real write, not just
   `ReadWritePaths` presence.** `tests/collector.nix`. Point
   `queue.directory` at a tmpfs-backed path outside `/var/lib/alloy`
   (e.g. `/run/alloy-queue-test`, pre-created via `systemd.tmpfiles.rules`
   in the test fixture itself), boot, confirm Alloy actually writes queue
   files there (`ls` non-empty after a real export), not just that the
   unit's `ReadWritePaths` lists the path.

3. **`hostType`: both shapes.** `tests/collector.nix`.
   - Valid omission: `logs.enable = true` alone, no `hostType` set,
     `nixos-rebuild build`-equivalent (`nix build` the toplevel) succeeds.
   - Failure mode (depends on Phase 45 item 2 existing first): `metrics.enable = true`,
     no `hostType` -- assert the NEW assertion's message text, not a raw
     Nix trace.

4. **`manageTmpfiles = false` + default `dataDir`.** `tests/storage.nix`.
   Mirror the 6 existing `mkManageTmpfilesCheck` invocations but with
   `dataDir` left at its default -- confirm no `systemd.tmpfiles.rules`
   entry is generated for this service.

5. **3-signals-at-once, native to `tests/collector.nix`.** New test:
   `metrics.enable = true; logs.enable = true; traces.enable = true;`
   on one collector container, real roundtrip for all 3 (not borrowed
   from `tests/full.nix`'s example).

6. **nginx ADR-0016 check, non-default value.** `tests/nginx.nix`.
   Existing check (`nginx-victoria-and-grafana-locations-coexist` or
   whichever currently reads `idleConnTimeout` back from the same eval)
   needs `vmauth.idleConnTimeout = "45s"` (or similar) in its own fixture,
   asserting nginx's `extraConfig` contains `45s` literally, not whatever
   the default happens to be.

7. **`extraRequestHeaders`/`extraResponseHeaders` across all 3 url_map
   files.** `tests/vmauth.nix`. Extend
   `extra-headers-are-inert-unless-configured` to also parse
   `WRITE_URL_MAP_FILE` and (with `openIngestPaths` overridden away from
   default) `OPEN_INGEST_PATHS_FILE` -- ties to Phase 45 item 1's fix;
   write this test to confirm the FIXED behavior (headers present in all
   3 files when configured).

8. **`writeTokensFile` malformed-YAML mirror.** `tests/vmauth.nix`. Copy
   `malformed-read-tokens-file-fails-with-a-legible-error`, same shape,
   pointed at `writeTokensFile` instead.

9. **`vmauth.listenAddress` override + `nginx.enable`.** `tests/nginx.nix`.
   New container-boot test: `vmauth.listenAddress = "127.0.0.1:19999"`,
   `nginx.enable = true`, confirm `/victoria/...` through nginx still
   reaches vmauth on the new port.

10. **`openIngestPaths` genuine partial override.** `tests/vmauth.nix`.
    New test: override to exactly one entry (e.g. metrics' own
    auto-open door, omitting logs/traces even though both enabled),
    confirm metrics' door is open and logs/traces' are not.

11. **`nginx.domain` + a credentialed vmauth tier.** `tests/nginx.nix`.
    Add `vmauth.adminPasswordFile` to one of the existing
    `nginx-custom-domain-*` tests, send `-u admin:...` through the
    name-based virtualHost, confirm it's not stripped/altered.

12. **MCP url_map entries absent when `mcp.enable = false`.**
    `tests/vmauth.nix`. Eval-only: `evalWith { metrics.enable = true;
    /* metrics.mcp.enable left false */ }`, assert no `/mcp/metrics`
    entry anywhere in `readUrlMap`.

13. **`effectiveUrl` seam, grafana.nix + vmauth.nix.** `tests/grafana.nix`
    and `tests/vmauth.nix`. Mirror `mcp-metrics-entrypoint-uses-effective-url`
    (tests/mcp.nix): `lib.mkForce` override `metrics.effectiveUrl` to a
    distinguishable fake URL, assert it reaches `datasourceSpecs`' `url`
    field (grafana) and `readUrlMap`/`autoOpenIngestPaths`' `url_prefix`
    (vmauth).

14. **MCP folded into vmauth's full-combination test.** `tests/vmauth.nix`.
    Add `metrics.mcp.enable = true` to
    `full-combination-all-tiers-plus-extra-routes-plus-headers`; assert
    `/mcp/metrics` still reachable with the admin credential alongside
    everything else already combined there.

15. **nginx -> vmauth -> `/mcp/*`.** `tests/full.nix` (already has both
    nginx and MCP enabled). Add one `curl http://127.0.0.1:80/victoria/mcp/metrics`
    assertion (real MCP `initialize` handshake through nginx, not direct
    to vmauth).

16. **`vmauth.enable = false` + MCP left at loopback default.**
    `tests/mcp.nix`. New test, `vmauth.enable = lib.mkForce false`,
    `metrics.mcp.enable = true`, `listenAddress` left at its default
    (`127.0.0.1:4205`) -- confirm the unit starts cleanly and stays
    loopback-only (no crash-loop, no surprise wildcard bind).

17. **Grafana x nginx: datasource URL stays loopback.** `tests/grafana.nix`
    or `tests/nginx.nix`. Add `nginx.enable = true; nginx.domain = "..."`
    to `datasources-direct-loopback-not-vmauth`, re-assert the same
    loopback-URL check.

18. **MCP wildcard-listenAddress pinning.** `tests/mcp.nix`. Eval-only,
    mirror `storage.nix`'s `mkWildcardReadinessCheck` shape but against
    `mcp.nix`'s own `isWildcard`/`bindAddr` `postStart` computation for
    `[::]:`  and bare `:port` forms.

19. **Multi-host fleet, 2 collectors.** `tests/collector.nix`. New test:
    `containers.stack` + `containers.collector-a` + `containers.collector-b`,
    distinct `hostType` per collector, distinct write tokens, both writing
    concurrently. Assert both hosts' `alloy_up{instance=...}` (or
    equivalent host-distinguishing label) series are present and distinct
    at the gateway.

20. **ADR 0020's `mkForce`-reconstruct workaround, proven.**
    `tests/grafana.nix`. New eval-only test: set
    `services.grafana.provision.datasources.settings.datasources =
    lib.mkForce (originalDatasourceSpecsAsBuiltByThisModule ++
    [oneExtraDatasource])`, confirm the merge produces exactly 4 entries,
    not a crash/duplicate/silent-drop.

21. **Cross-service port-collision assertion fires.** `tests/assertions.nix`.
    Depends on Phase 45 item 6 existing -- `mkAssertionFiresCheck` with
    `metrics.listenAddress = logs.listenAddress` (both explicitly set to
    the same value), assert the new collision message fires.

22. **Read-tier bearer token reaching MCP, end to end.** `tests/full.nix`.
    Add one MCP `initialize` + `tools/call` sequence using
    `full-test-read-token` (bearer) alongside the existing
    admin-credential one.

23. **One real maximal cross-product test.** New test, likely
    `tests/full.nix` or a new `tests/maximal.nix`: custom `nginx.domain`
    + TLS (operator-style `addSSL` on the stable virtualHost name, ADR
    0022) + all 3 credential tiers + all 3 backends + all 3 MCP servers
    + Grafana + a real collector shipping real data, all at once. This is
    the single most expensive test in the suite (expect 60-90s+ boot) --
    write it last, after everything else in Phase 44 is green, since any
    bug it catches should already be caught by a smaller, faster,
    more-specific test above.

---

## Phase 45: hardening / obvious improvements

1. **Fix `openIngestPaths` bypassing `withExtraHeaders`.**
   `nixosModule/victoriaStack/vmauth.nix`. Currently:
   ```nix
   openIngestPathsFile = pkgs.writeText "vmauth-open-ingest-paths.json" (
     builtins.toJSON cfg.openIngestPaths
   );
   ```
   `cfg.openIngestPaths`'s *default* is `mkDefault autoOpenIngestPaths`
   (already wrapped in `withExtraHeaders` at definition time), but a
   custom override bypasses that wrapping entirely. Fix: wrap at the
   point of serialization instead --
   ```nix
   openIngestPathsFile = pkgs.writeText "vmauth-open-ingest-paths.json" (
     builtins.toJSON (withExtraHeaders cfg.openIngestPaths)
   );
   ```
   Confirm `withExtraHeaders` is idempotent-safe to apply twice (it
   should just be `map (e: e // extraAttrs)`, re-applying the same merge
   is harmless) before relying on this for the *default* case too (it
   currently gets wrapped once already inside `autoOpenIngestPaths`'s own
   definition -- double-wrapping via both paths must not duplicate
   headers; `//` overwrite semantics should make this a no-op, confirm
   with a test).

2. **New `nixosModule/victoriaCollector/assertions.nix`.** Mirrors
   `victoriaStack/assertions.nix`'s shape/style. At minimum:
   ```nix
   assertion = (cfg.metrics.enable || cfg.traces.enable) -> cfg.hostType != null;
   message = ''
     services.victoriaCollector.hostType is required when metrics.enable
     or traces.enable is true -- config.alloy.nix's host_type label
     promotion needs a real value. Not required for logs-only (that path
     has no Alloy pipeline to attach the label in).
   '';
   ```
   Register the new file in `nixosModule/victoriaCollector/default.nix`'s
   `imports`.

3. **`mkStorageService` refactor.** New function in
   `nixosModule/victoriaStack/storage-common.nix` (new file), parameters
   mirroring `mkMcpService`'s shape: `{name, binaryName, limitNOFILE,
   ...}`. `metrics.nix`/`logs.nix`/`traces.nix` become thin call sites
   (`import ./storage-common.nix { ... }`), same pattern `mcp.nix`
   already uses for its 3 services. **No behavior change** -- this is
   pure refactor; the test suite passing unchanged both before and after
   is the acceptance criterion, not a new test.

4. **`RequiresMountsFor` wiring.** Each of `metrics.nix`/`logs.nix`/
   `traces.nix` (or the new shared `storage-common.nix` from item 3 --
   do this refactor-then-harden in that order so the fix lands once, not
   3x): add `requiresMountsFor = [ cfg.dataDir ]` to the systemd service
   definition. `RequiresMountsFor` on a path under `/` (the common case,
   default `dataDir`) is a documented systemd no-op (already satisfied by
   `local-fs.target`), so this is safe unconditionally.

5. **nginx `X-Real-IP`/`X-Forwarded-For`.** `nixosModule/victoriaStack/nginx.nix`.
   Add to both the `/victoria/` and `/grafana/` (+ the websocket variant)
   `extraConfig` blocks:
   ```
   proxy_set_header X-Real-IP $remote_addr;
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   ```

6. **Cross-service port/listenAddress collision assertion.**
   `nixosModule/victoriaStack/assertions.nix`. Collect every enabled
   service's own `listenAddress` (metrics/logs/traces/vmauth + each
   enabled MCP's `listenAddress`) into one list, assert
   `lib.length addrs == lib.length (lib.unique addrs)`.

7. **`selfScrapeInterval` options.** `options.nix`'s
   `mkStorageServiceOptions` (shared across metrics/logs/traces) +
   vmauth's own options block. `types.nullOr types.str`, default `null`,
   `-selfScrapeInterval=${v}` appended to `ExecStart` when non-null, same
   shape as `retentionPeriod`.

8. **Disk-usage retention options (logs/traces only -- metrics doesn't
   support this flag, confirmed via its own `--help`).**
   `options.nix`'s `mkStorageServiceOptions`, gated to logs/traces call
   sites only (or add as a parameter `supportsDiskRetention ? false` to
   the shared function, matching `retentionPeriodNullBehavior`'s own
   per-service-parameter pattern):
   `retentionMaxDiskSpaceUsageBytes` (`types.nullOr types.str`, e.g.
   `"500GB"`) and `retentionMaxDiskUsagePercent` (`types.nullOr types.int`),
   mutually exclusive per upstream docs -- add an assertion for that too.

9. **ADR 0002 amendment.** `docs/decisions/0002-opt-in-everything.md`.
   Add a `## Status` section (same style ADR 0012 used for its own
   supersession) noting the `nginx.enable -> vmauth.enable` invariant was
   amended in Phase 36 to `-> (vmauth.enable && anyBackendEnabled)`.

10. **New ADR: MCP's trust boundary extends ADR 0010.** New
    `docs/decisions/0023-mcp-trust-boundary-extends-grafana.md` (next
    free number -- confirm 0023 is still unused when writing this).
    Short: MCP's "no credential logic of its own" design is the same
    same-host-trust reasoning ADR 0010 already established for Grafana,
    made explicit with its own ADR number instead of living only in a
    `mcp.nix` code comment.

11. **New ADR: option-stability stance.** New
    `docs/decisions/0024-option-stability-stance.md` (confirm number).
    Non-retroactive: states this project has no versioning/release
    promise yet, and commits to `lib.mkRenamedOptionModule` for any
    future option RENAME once it adopts one. Phase 46's own rename
    becomes the first real example to point to from this ADR once it
    lands (write the ADR in the SAME commit as Phase 46, not before).

---

## Phase 46: `extraOptions` -> `extraFlags` rename

**Files:** `nixosModule/victoriaStack/options.nix` (3 occurrences inside
`mkStorageServiceOptions`), `nixosModule/victoriaStack/{metrics,logs,traces}.nix`
(each references `cfg.extraOptions` in its `ExecStart` construction --
becomes `cfg.extraFlags`), every test referencing `extraOptions` in
`tests/storage.nix`.

**Migration:** add to each of `metrics.nix`/`logs.nix`/`traces.nix`'s
own `imports` (or a shared location if the Phase 45 item 3 refactor has
already landed by this point):
```nix
imports = [
  (lib.mkRenamedOptionModule
    [ "services" "victoriaStack" "metrics" "extraOptions" ]
    [ "services" "victoriaStack" "metrics" "extraFlags" ])
];
```
(one per service, 3 total -- or parameterized once if the shared
`storage-common.nix` helper from Phase 45 exists by the time this lands).

**Test:** one eval-only check per service confirming the OLD option name
still works (with `lib.mkRenamedOptionModule`'s own standard warning) and
produces the identical `ExecStart` as using the new name directly.

---

## Phase 47: `vmauth.extraFlags`

**Files:** `options.nix` (vmauth's own options block -- add `extraFlags`,
identical shape/description to the other 3, minus the
`mkRenamedOptionModule` since this is new, not renamed).
`nixosModule/victoriaStack/vmauth.nix`'s `ExecStart` construction: append
`++ cfg.extraFlags` as the final element (same position `extraOptions`
occupies in the storage services).

**Test:** `tests/vmauth.nix` -- eval-only, confirm an
`extraFlags = ["-tlsCertFile=/foo" "-tlsKeyFile=/bar"]` entry reaches the
rendered `ExecStart` string verbatim. One real container-boot test:
`extraFlags` used to actually enable vmauth's own `-tls`/`-tlsCertFile`/
`-tlsKeyFile` (throwaway self-signed cert, mirroring the `selfSignedCert`
pattern already used in `tests/nginx.nix`), confirm `https://` direct to
vmauth's own listener (bypassing nginx) works.

---

## Phase 48: multi-host fleet test + example

**Test:** see Phase 44 item 19 above (same work, listed once).

**Example:** new `examples/fleet.nix` (or a new README section titled
"Fleet topology" linking to it) -- a worked, real NixOS config shape:
one `services.victoriaStack` host definition (the gateway) + N
`services.victoriaCollector` host definitions (distinct `hostType`,
distinct `writeTokenFile` per host, same `writeEndpoint` pointed at the
gateway's real network address, not loopback). Not a `nixosTest` module
(that's the Phase 44 test's job) -- a plain, readable example a real
operator copies from, following `examples/default.nix`'s existing style.

---

## Phase 49: `.gitleaksignore` -> inline `gitleaks:allow`

**Mechanical, no design decisions left.** For every line in the current
`.gitleaksignore`, find the corresponding file:line, add
`  # gitleaks:allow` at the end of that line (or the nearest line
containing the actual secret-shaped string, since gitleaks' fingerprints
are sometimes one line off from the human-visible credential depending on
how `curl`'s multi-line f-string/concat renders). Delete
`.gitleaksignore` once `gitleaks protect --staged` (or `detect --no-git`)
reports zero findings with the file removed. Re-confirm after every
future phase in this plan that touches a credentialed test line -- the
inline-comment approach means this should now be a non-event (no
separate file to regenerate), but worth one explicit verification this
first time.

---

## Phase 50: vmauth auto-consumes `X-Forwarded-For`

**Files:** `nixosModule/victoriaStack/vmauth.nix`. Add to `ExecStart`:
```nix
++ lib.optional topCfg.nginx.enable "-httpRealIPHeader=X-Forwarded-For"
```
(Note: this makes `vmauth.nix` read `topCfg.nginx.enable` -- confirm this
doesn't introduce a circular module-evaluation issue; `nginx.nix` already
reads from `topCfg.vmauth.*`, so this is the reverse direction. Since
both are siblings under the same `topCfg`, not nested module imports of
each other, this should be fine, but verify with a real `nix eval` before
assuming.)

**Test:** `tests/vmauth.nix`, eval-only: `nginx.enable = true` ->
`-httpRealIPHeader=X-Forwarded-For` present in `ExecStart`;
`nginx.enable = false` (default) -> absent. Real container-boot test
(could fold into Phase 45 item 5's own nginx+vmauth test): send a request
through nginx with a spoofed inbound `X-Forwarded-For` already set,
confirm vmauth's own `access_log` shows nginx's `proxy_add_x_forwarded_for`
value (the real client chain), not the raw spoofed header passed through
unprocessed -- `proxy_add_x_forwarded_for` appends rather than overwrites,
confirm this nuance doesn't let a client spoof their way to the front of
the chain.

---

## Phase 51: `extraWriteUrlMap`

**Files:** `options.nix` (vmauth block) -- new option, identical shape to
`extraReadUrlMap`:
```nix
extraWriteUrlMap = mkOption {
  type = types.listOf (types.attrsOf types.anything);
  default = [ ];
  description = ''
    Escape hatch: extra vmauth url_map entries appended to the write-tier
    credential's own url_map (readTokensFile's own read-tier entries are
    untouched -- see extraReadUrlMap for that side). Same
    operator's-own-responsibility philosophy: entries here are NOT
    validated against the allow-list ADR 0021 established for the
    built-in routes. Real use case: VictoriaMetrics' own /write
    (InfluxDB line protocol) or /api/v1/write (Prometheus remote-write)
    paths this module doesn't open a door for by default.
  '';
};
```
`vmauth.nix`: `writeUrlMap = withExtraHeaders (autoOpenIngestPaths ++
cfg.extraWriteUrlMap);` (mirrors `readUrlMap`'s own `++ cfg.extraReadUrlMap`
tail), threaded through to `writeUrlMapFile`'s serialization.

**Guardrail test:** `tests/vmauth.nix`, eval-only, mirrors
`read-tier-url-map-is-a-closed-allow-list-not-a-wildcard`'s own pattern
but scoped to flagging an obviously-dangerous wildcard
(`lib.hasSuffix ".*" p` with no narrowing prefix) specifically WITHIN
`extraWriteUrlMap`/`extraReadUrlMap`'s own entries when configured --
this is a warning-style check (the escape hatch is still allowed to do
this if the operator insists), not a hard assertion, matching the
"operator's own responsibility" framing in the option's own description.

**Functional test:** real container-boot, `extraWriteUrlMap` pointed at
`/write`, a real InfluxDB-line-protocol curl payload, confirm it lands
AND confirm a read-tier credential cannot reach the same path (the
exact property ADR 0021 exists to guarantee, re-confirmed for the new
escape hatch).

---

## Phase 52: per-token scoping (read AND write tiers)

This is the largest single phase in this round -- budget real time for
TDD discipline here specifically.

**New YAML shape** (`readTokensFile`/`writeTokensFile`, both):
```yaml
tokens:
  - token: "read-token-one" # unscoped -- same as today's behavior
  - token: "read-token-two"
    backends: ["traces"]    # scoped: /traces/* + /mcp/traces only
```

**`vmauth.nix`'s `vmauth-render-config` script** needs real surgery:

1. `validate_tokens_shape` changes from "array of strings" to "array of
   objects, each with a required string `token` key and an optional
   list-of-string `backends` key". New jq check:
   ```
   type == "array" and all(.[]; type == "object" and (.token | type == "string") and ((.backends // []) | type == "array"))
   ```
   Error message must distinguish "still the old bare-string format"
   (detect via `all(.[]; type == "string")` as a SEPARATE prior check,
   emit a migration-specific message) from "genuinely malformed" (neither
   shape matches).

2. The `jq` construction that currently does
   `map({bearer_token: ., url_map: $urlmap[0]})` becomes, per-token:
   - no `backends` key (or empty list): `{bearer_token: .token, url_map: $urlmap[0]}` (today's behavior, full url_map)
   - `backends` present: filter `$urlmap[0]` down to only the entries
     whose `src_paths` start with one of the listed backend's own path
     prefix (`/metrics`, `/logs`, `/traces` for raw API; `/mcp/metrics`,
     `/mcp/logs`, `/mcp/traces` for that signal's MCP route -- both
     included together per the grill decision). This needs a jq function
     taking the backend name list and producing the matching prefix set,
     likely cleanest written as a small lookup table passed in via
     another `--argjson` (e.g. a `BACKEND_PREFIXES_FILE` env var,
     `{"metrics": ["/metrics", "/mcp/metrics"], "logs": [...], "traces": [...]}`,
     generated in Nix alongside `READ_URL_MAP_FILE` etc. so the prefix
     list itself stays a single source of truth, not duplicated between
     Nix and the embedded jq query).

3. Apply identically to the `write_tokens_json` branch (using
   `WRITE_URL_MAP_FILE`'s own prefix shapes --
   `/opentelemetry`/`/insert/journald`/`/insert/opentelemetry/v1/traces`,
   confirmed from `autoOpenIngestPaths`' real `src_paths` -- these don't
   share the clean `/metrics`/`/logs`/`/traces` prefix convention the
   read side does, so the backend-name-to-prefix lookup table needs
   per-tier values, not one shared table).

**Tests:**
- RED-before-fix: confirm an unscoped token still works exactly as
  before (regression, mirrors existing `all-three-credential-tiers-coexist`).
- A scoped read-token reaching only its listed backend(s)' raw API AND
  MCP route, and genuinely failing on every other enabled backend/MCP
  route -- real container boot, all 3 backends + all 3 MCP servers
  enabled, one token scoped to `["traces"]` only.
- A scoped write-token, same shape, write side.
- Malformed-shape error legibility: old bare-string format vs genuinely
  malformed, two separate tests confirming two distinct error messages.
- Eval-only: confirm `backends` omitted entirely still produces the full,
  unfiltered url_map (today's default-preserving case) -- this is the
  backward-compatibility guarantee, make it explicit.

**Docs:** `options.nix`'s `readTokensFile`/`writeTokensFile` descriptions
need the new YAML shape spelled out with a worked example (the existing
description already documents the file format in prose -- update in
place, this is a breaking change to that documented contract and must
say so explicitly, plus a one-line migration note since this isn't
Nix-auto-migratable per PLAN.md Phase 52's own reasoning).

---

## Phase 53: collector metrics customization

**Files:** `nixosModule/victoriaCollector/options.nix` -- new options
under `metrics`:
```nix
metrics = {
  enable = mkEnableOption "...";  # existing
  extraCollectors = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "processes" "textfile" ];
    description = ''
      Extra node_exporter collectors to enable, on top of
      node_exporter's own default-enabled set (confirmed via Alloy's own
      prometheus.exporter.unix docs: cpu, diskstats, filesystem,
      loadavg, meminfo, netdev, etc. -- see that component's own
      "Collectors list" table for the full default set) PLUS this
      module's own always-on "systemd" collector. `[ ]` (the default)
      changes nothing from today's behavior.
    '';
  };
  disabledCollectors = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "hwmon" "zfs" ];
    description = ''
      node_exporter collectors to disable -- e.g. an expensive one on a
      resource-constrained host. Takes precedence over extraCollectors
      if the same name appears in both (Alloy's own documented
      disable_collectors semantics).
    '';
  };
  scrapeInterval = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "30s";
    description = ''
      Overrides Alloy's own prometheus.scrape default (60s) for the host
      metrics scrape job specifically. `null` (the default) omits the
      argument entirely, matching Alloy's own upstream default.
    '';
  };
};
```

`config.alloy.nix`'s `metricsSection`:
```
prometheus.exporter.unix "host" {
  enable_collectors = ["systemd"${lib.optionalString (cfg.metrics.extraCollectors != []) ", " + ...}]
  ${lib.optionalString (cfg.metrics.disabledCollectors != []) ''disable_collectors = [...]''}
  systemd {}
}

prometheus.scrape "host" {
  targets    = prometheus.exporter.unix.host.targets
  forward_to = [otelcol.receiver.prometheus.host.receiver]
  ${lib.optionalString (cfg.metrics.scrapeInterval != null) ''scrape_interval = "${cfg.metrics.scrapeInterval}"''}
}
```
(exact Alloy HCL-ish syntax needs double-checking against the real
grammar at implementation time -- list literal formatting, string
escaping for the generated `.alloy` file -- this is pseudocode for the
option wiring, not copy-paste-ready Alloy syntax.)

**Tests:** `tests/collector.nix`.
- Eval-only: `extraCollectors`/`disabledCollectors`/`scrapeInterval` all
  `[]`/`null` (default) -> rendered config identical to today's
  hardcoded `enable_collectors = ["systemd"]`, no `disable_collectors`/
  `scrape_interval` lines at all.
- Real container-boot: `extraCollectors = ["processes"]`, confirm
  `node_processes_pids` (or similar, confirm exact metric name via real
  node_exporter docs at implementation time) actually lands at the
  gateway, the same empirical-verification style used throughout this
  project (don't just check the rendered text).
- Real container-boot: `disabledCollectors = ["loadavg"]`, confirm
  `node_load1` does NOT land (it does today, by default -- this is a
  genuine behavior change to verify, not just an eval check).

---

## Phase 54: on-disk snapshot creation + pruning

**Files:** `options.nix`'s `mkStorageServiceOptions` (shared across
metrics/logs/traces). **Not yet confirmed for logs/traces specifically**
-- `/snapshot/create`/`-snapshotsMaxAge` were only verified against
VictoriaMetrics' own docs this session; VictoriaLogs/VictoriaTraces'
own `--help`/docs need checking at implementation time before assuming
parity (same "confirmed independently, not assumed shared" discipline
this plan cites below for the test). If either doesn't actually support
this, that service's own `snapshots` sub-option tree should not be
added at all rather than silently rendering a flag the binary rejects.
```nix
snapshots = {
  enable = mkEnableOption "periodic snapshot creation via /snapshot/create";
  schedule = mkOption {
    type = types.str;
    default = "daily";
    description = ''
      systemd OnCalendar expression for how often to create a snapshot.
      "daily" means midnight, matching systemd's own OnCalendar shorthand.
    '';
  };
  maxAge = mkOption {
    type = types.nullOr types.str;
    default = "30d";
    description = ''
      -snapshotsMaxAge -- the binary prunes its own old snapshots
      automatically on this schedule (confirmed: a real, binary-native
      mechanism, not something this module's timer does). `null`
      disables automatic pruning entirely -- snapshots then accumulate
      forever under <dataDir>/snapshots until manually deleted via the
      real /snapshot/delete API (never rm/cp/rsync directly -- snapshots
      are hard-links into live data; those commands can silently
      corrupt them).

      NOTE: a snapshot never leaves this host's own disk. This protects
      against accidental/logical data loss (a bad query, an operator
      mistake), NOT disk failure -- shipping a snapshot off-host needs
      VictoriaMetrics' own separate vmbackup tool, which this option
      does not wire up.
    '';
  };
};
```

`metrics.nix`/`logs.nix`/`traces.nix` (or the shared `storage-common.nix`
if Phase 45 item 3 has landed): `-snapshotsMaxAge=${cfg.snapshots.maxAge}`
appended to `ExecStart` when `cfg.snapshots.enable && cfg.snapshots.maxAge
!= null`. New `systemd.timers."${name}-snapshot"` + a oneshot
`systemd.services."${name}-snapshot"` (`ExecStart = curl -sf -X POST
http://${cfg.listenAddress}/snapshot/create` or equivalent, via the
service's own loopback address -- no credential needed, same trust
boundary as every other loopback-only internal call in this module),
`OnCalendar = cfg.snapshots.schedule`, gated on `cfg.snapshots.enable`.

**Tests:** `tests/storage.nix`.
- Eval-only: `snapshots.enable = false` (default) -> no new timer/service
  exists at all, `-snapshotsMaxAge` absent from `ExecStart`.
- Eval-only: `snapshots.maxAge = null` with `enable = true` ->
  `-snapshotsMaxAge` still absent (pruning genuinely off), but the
  creation timer still exists.
- Real container-boot: `snapshots.enable = true`, trigger the oneshot
  manually (`systemctl start <name>-snapshot.service`), confirm a real
  snapshot directory appears under `<dataDir>/snapshots/` (query
  `/snapshot/list`, don't just check exit code), confirmed non-empty.
- One per storage service (metrics/logs/traces) -- confirm the API
  genuinely exists and behaves identically on all 3 binaries, not
  assumed shared just because VictoriaMetrics' own docs described it
  (same "confirmed independently" discipline this project has applied
  to retentionPeriod's per-binary defaults).
