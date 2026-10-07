# Implementation plan: nixos-victoria-stack-module

Source of truth for implementation and for independent review agents (who will
not have the chat history this plan was negotiated in — only this file, the
ADRs in `docs/decisions/`, and the code itself).

## Goal

A flake-based NixOS module providing a from-scratch VictoriaMetrics /
VictoriaLogs / VictoriaTraces stack with an auth gateway (vmauth), optional
Grafana datasource wiring, optional nginx reverse-proxy, optional MCP servers,
and a separate fleet-wide collector agent (`victoriaCollector`). Everything
opt-in except where there is genuinely nothing to opt out of. Fixes the real,
confirmed structural problems in nixpkgs' own `services.victoriametrics` /
`victorialogs` / `victoriatraces` modules (hardcoded `-storageDataPath`,
`DynamicUser` incompatible with a pre-mounted dataset, no `retentionPeriod` on
`victorialogs`) by not wrapping them at all — storage services are written
from scratch directly on `pkgs.victoriametrics`'s binaries.

## Repository layout (original target, historical)

```
flake.nix / flake.lock
LICENSE (MIT)
README.md
docs/options.md                  — generated via generate-doc.nix, CI-committed
docs/decisions/NNNN-*.md         — ADRs, terse, WHY only
.github/workflows/
  ci.yml                          — nix flake check -L
  ci-stable.yml                   — dynamic current-stable nixpkgs override
  update-dependencies.yml         — weekly nixpkgs bump + MCP package bump
                                    (two sequential jobs, docs/decisions/0018)
  update-docs.yml                 — regenerate + commit docs/options.md
nixosModule/
  default.nix                     — nixosModules.default (both trees)
  victoriaStack/{options,config,metrics,logs,traces,vmauth,grafana,nginx,mcp}.nix
  victoriaCollector/{options,config,config.alloy...}.nix
packages/mcp-victoria{metrics,logs,traces}/package.nix
examples/default.nix              — same config the `full` test exercises
tests/{default,lib,assertions,storage,vmauth,grafana,nginx,mcp,collector,full}.nix
```

## Options surface (original sketch, historical)

Superseded: see `docs/options.md` for the real surface (e.g. `extraOptions` is now `extraFlags`; token files are `- token:` objects).

```
services.victoriaStack = {
  metrics = { enable; package; dataDir; dynamicUser; listenAddress;
              retentionPeriod; extraOptions; suppressDynamicUserWarning;
              manageTmpfiles;  # default true; escape hatch, no warning when false
              mcp = { enable; package; listenAddress;
                      logLevel; logFormat; disabledTools; }; };
  logs    = { <same shape>; mcp = { ... }; };
  traces  = { <same shape>; mcp = { ... }; };

  vmauth = {
    enable;              # mkDefault true whenever any backend enabled; no-op w/o one
    package;              # mkDefault metrics.package
    listenAddress; idleConnTimeout;
    requireAuthForWrites;  # default true; single toggle to open ingest paths
    writeTokensFile;       # sops-nix YAML secret, list w/ inline # comments
    readTokensFile;        # SEPARATE sops-nix YAML secret (different blast radius)
    adminPasswordFile;     # plain scalar secret
    openIngestPaths;       # auto-derived list, overridable to [ ]
    extraReadUrlMap;       # escape hatch
    maxConcurrentRequests; maxConcurrentPerUserRequests;  # inert unless set
    backendTls = { insecureSkipVerify; caFile; certFile; keyFile; };  # inert unless set
    extraRequestHeaders; extraResponseHeaders;  # inert unless set
    # IP allow/deny lists and load-balancing/failover were considered and
    # explicitly NOT added -- see ADR 0019's addendum.
  };

  grafana.enable;          # opt-in datasource wiring ONLY; services.grafana.* untouched,
                            # never routed through vmauth, always direct loopback
  nginx = { enable; domain = nullOr str /* default null */; };
    # assertion: nginx.enable -> vmauth.enable
};

services.victoriaCollector = {
  metrics.enable; logs.enable; traces.enable;   # independent, OTLP receiver tied to traces
  writeEndpoint; journaldWriteEndpoint;
  writeTokenFile;
  hostType;                # strMatching "[A-Za-z0-9_.-]+", not free-form
  queue = { maxSizeBytes; directory; };  # default 1GiB / /var/lib/alloy/queue
  alloy.package; alloy.extraFlags;
  alloy.tlsCaFile; alloy.tlsInsecureSkipVerify;  # inert unless set
  alloy.retryOnFailure = { initialInterval; maxInterval; maxElapsedTime; };  # inert unless set
  trustedCertificateFile;
};
```

Assertion: `<service>.mcp.enable -> <service>.enable` (not vmauth — mcp can be
exposed directly via its own `listenAddress` when vmauth is off).

## Key technical decisions (see docs/decisions/ for full WHY)

- VM/VL/VT built from scratch, not wrapping nixpkgs' own modules.
- vmauth two SEPARATE credential-tier secrets (write vs read/admin), both
  YAML format with inline `#` comments, parsed via `yq-go` (not raw `jq -R`
  line-splitting).
- Grafana: own built-in auth only, direct loopback, never through vmauth.
- `dataDir`/`dynamicUser` mismatch -> warning + suppress option, not a hard
  assertion.
- Alloy's write-token: `otelcol.auth.headers` + `sys.env()` + `EnvironmentFile=`
  — token never touches rendered `config.alloy` text.
- journal-upload's write-token: nixpkgs' `services.journald.upload` module
  kept for non-secret settings; a root oneshot renders
  `/run/systemd/journal-upload.conf.d/50-write-token.conf` with just the
  `Header=` line (ADR 0012).
- Every service (metrics/logs/traces/vmauth/all 3 MCP packages) gets its own
  `.package` option; vmauth's defaults from metrics' via `mkDefault`.
- Secrets: fully agnostic `...File` path options everywhere. No sops-nix
  dependency in module code. Composes with sops-nix's native one-key-per-secret
  addressing (documented, not re-implemented).
- Test backend: `containers = {...}` (nspawn) throughout, confirmed via
  nixpkgs' own `nixos/tests/nixos-test-driver/containers.nix` self-test
  (validates container<->container and container<->node networking by
  hostname across vlans) — no QEMU fallback needed anywhere, cross-container
  collector->stack path included.
- MCP servers: real `buildGoModule` packages (not fetchurl prebuilt
  binaries), `nix-update --flake <pkg> --build` compatible, version bumps
  via a dedicated CI job (not folded into the nixpkgs bump job's own
  commit -- these are pre-1.0 and can change runtime behavior on a bump,
  unlike a pinned nixpkgs revision; both jobs share one workflow file
  and schedule, sequenced via `needs:`, docs/decisions/0018).
- `examples/default.nix` IS the `full` test group's config — one source of
  truth, not a docs example that quietly drifts from what's tested.

## Explicitly deferred (not in this plan)

Vendored Grafana dashboards, default alerting rules, migrating
`deployment-a`/`deployment-b` onto the new module.

**External/remote backends** (docs/decisions/0019): `vmauth`/`grafana`/
`nginx` assume every enabled signal's storage service is co-located on
the same host -- there is no way to point any of them at an
externally-hosted Victoria* backend instead. Not ruled out forever;
revisitable if someone needs/commits it. A structural seam
(`effectiveUrl`, docs/decisions/0019) is already in place so adding this
later only touches one definition per service, not every consumer call
site.

**Multi-instance/clustering** (docs/decisions/0019): every storage
service only ever builds single-node CLI flags -- no
`vminsert`/`vmselect`/`vmstorage` cluster-component wiring exists or is
planned. Single-node only, today; not ruled out forever, just not part
of this project's current scope.

## Task list / phase order

- [x] 0. SETUP: this file + ADRs, committed first
- [x] 1. Scaffolding: flake.nix, CI workflows, LICENSE, empty module entrypoints
- [x] 2. `assertions` test group (red first)
- [x] 3. `storage`: metrics (implemented; all checks, including
      container-boot, confirmed genuinely green -- see Phase 34, which
      resolved the uid-range blocker this entry originally noted)
- [x] 4. `storage`: logs (same status as metrics)
- [x] 5. `storage`: traces (same status as metrics)
- [x] 6. `vmauth` (same status -- all 5 container-boot checks confirmed
      green as of Phase 34)
- [x] 7. `grafana` (all 3 container-boot checks confirmed green as of
      Phase 34)
- [x] 8. `nginx` (both container-boot checks confirmed green as of
      Phase 34)
- [x] 9. `mcp`: 3 real buildGoModule packages built + wiring implemented
      (both container-boot checks confirmed green as of Phase 34)
- [x] 10. `victoriaCollector` (including the cross-container
      metrics-roundtrip test; all 3 container-boot checks confirmed
      green as of Phase 34)
- [x] 11. `full` / `examples` assembly (the 1 container-boot check
      confirmed green as of Phase 34)
- [x] 12. docs: `generate-doc.nix` + `docs/options.md`, README
- [x] 13. `update-mcp-packages.yml` workflow
- [x] 14. Two independent fresh-agent critical reviews
- [x] 15. Address review findings, final gate, report completion

## Round 2: deeper critical review (test gaps / missing options / design) + fixes

Four fresh agents (storage; vmauth/grafana/nginx; mcp/collector;
cross-cutting) reviewed again with an explicit brief to find test gaps,
missing configurability, and bad design, not just correctness bugs. Every
real finding was resolved in a `/grill-me` session with the project owner
before any code changed; design decisions are docs/decisions/0014-0019,
indexed by 0020.

- [x] 16. Write ADRs 0014-0020 capturing the grill session (this phase)
- [x] 17. Secret-type fix: vmauth's 3 credential-file options + collector's
      writeTokenFile, `types.path` -> `types.str` (docs/decisions/0020)
- [x] 18. vmauth `openIngestPaths` behavioral fix + redundant-auth warning
      (docs/decisions/0014)
- [x] 19. Storage hardening: nixpkgs profile + `wait4x` readiness +
      `LimitNOFILE` + traces retentionPeriod doc fix + `manageTmpfiles`
      option (docs/decisions/0015, 0020)
- [x] 20. vmauth + mcp hardening pass (docs/decisions/0015)
- [x] 21. Collector fixes: oneshot hardening/de-rooting, `hostType`
      `strMatching`+traces coverage, `queue.directory` `ReadWritePaths`
      (docs/decisions/0015)
- [x] 22. nginx rewrite: mirror vmauth timeouts/body-size, Grafana's
      official sub-path config incl. previously-missing
      `/grafana/api/live/` (docs/decisions/0016); found+fixed a severe
      `//`-clobbering bug in the same pass
- [x] 23. Port renumbering: victoriaStack services 4201-4207
      (docs/decisions/0017)
- [x] 24. `effectiveUrl` structural seam + external-backend/clustering
      scope docs (docs/decisions/0019)
- [x] 25. CI consolidation: single workflow + job dependency,
      `update-docs.yml` permissions fix (docs/decisions/0018)
- [x] 26. New vmauth options: concurrency, backend TLS, custom headers
      (docs/decisions/0020). IP filters and load-balancing/failover
      explicitly NOT added -- IP filters confirmed Enterprise-only
      (would silently no-op on the OSS package); load-balancing requires
      multiple backend instances per signal, same "more than one
      backend" concept already deferred under clustering
      (docs/decisions/0019 addendum)
- [x] 27. New alloy options: OTLP exporter TLS, retry/backoff tuning
      (docs/decisions/0020)
- [x] 28. New mcp options: logLevel/logFormat/disabledTools passthrough
      (docs/decisions/0020)
- [x] 29. Documentation: PLAN.md/README fixes, new architecture wiring
      diagram, escape-hatch notes (docs/decisions/0020)
- [x] 30. Test harness unification: `tests/lib.nix`'s `evalWith`
      generalized for both module trees
- [x] 31. Close remaining test gaps: retentionPeriod/extraOptions/
      listenAddress-override (storage), mcp.package override (mcp),
      idleConnTimeout override (vmauth) -- all eval-only; static-user
      group-ownership + real ingest/query roundtrip (storage), vacuous
      `|| true` MCP-route test fixed with real reachability assertions
      (mcp), read/admin-cannot-write + all-3-tiers-together (vmauth),
      remaining domain x grafana.enable combinations + /grafana/ 404
      when disabled (nginx), logs/traces-only datasource combination
      (grafana), queue-option isolation + traces-exporter coverage
      (collector) -- all container-boot
- [x] 32. Final full `nix flake check -L` gate -- eval-only at the time
      (this environment lacked the `uid-range` Nix system-feature every
      container-boot/nixosTest check needs, so all of them were
      necessarily skipped, not run). See Phase 34 for genuine execution.
- [x] 33. Fresh-agent re-review round 3, triage, final push -- 2
      independent agents, no shared context. Fixed 2 genuine bugs
      (extraReadUrlMap header-clobbering, same `//` class as the nginx
      bug in Phase 22; wait4x's IPv6-wildcard readiness gap), corrected
      ADR 0020's false claims and PLAN.md's stale options-surface block,
      closed 7 test-coverage gaps (vmauth logs/traces end-to-end,
      vmauth.package, manageTmpfiles logs/traces, assertions logs/traces,
      extraReadUrlMap, wildcard-readiness both IPv4/IPv6, journal-upload
      hard dependency), fixed examples/default.nix's missing collector
      traces.enable, added update-docs.yml's missing concurrency group.
      Explicitly reverted one overly-broad fix (a requireAuthForWrites
      warning) after confirming it broke 9+ legitimate existing tests.
- [x] 34. Real end-to-end verification -- every container-boot test in
      this suite had been eval-only its entire history, blocked locally
      by the missing `uid-range` Nix system-feature; enabled it on the
      dev machine (separate commit, work-infrastructure repo:
      auto-allocate-uids + cgroups experimental features, uid-range
      added to system-features) and ran the real suite for the first
      time. Found and fixed 2 genuine production bugs no amount of
      eval-only testing could have caught:
      - vmauth-render-config crash-looped forever whenever zero
        credential options were configured ($CREDENTIALS_DIRECTORY
        unbound under `set -u` -- systemd only exports it when at least
        one LoadCredential= entry exists).
      - Alloy's OTLP write-token auth header was missing the "Bearer "
        prefix vmauth's bearer_token auth requires -- every real
        collector export to a write-token-protected vmauth had been
        silently failing with 401 since this code was written.
      - systemd-journal-upload's rendered Header= drop-in was
        root-600-only, unreadable by the real upstream unit's
        DynamicUser+SupplementaryGroups=systemd-journal; fixed with
        chgrp+640.
      Also fixed ~10 test-methodology bugs the real run surfaced
      (wrong OTLP path/format used by nearly every write-path test;
      `nginx -T` needing -c for the real config; Host-header routing
      for name-based virtualHosts; Grafana/vmauth readiness races with
      no probe of their own; a cross-container test's vmauth left
      loopback-only + firewalled; a wrong assumption about Grafana's
      default-datasource auto-promotion). Confirmed clean: `nix flake
      check -L` reports "all checks passed!" with zero remaining
      failures of any kind.

## Round 3: 4 parallel fresh-agent reviews post-Phase-34 + a full /grill-me
session resolving every finding, then a 9-phase implementation pass
(Phase 35-43)

4 fresh agents (storage/collector; vmauth/nginx; grafana/mcp;
cross-cutting), each told to verify empirically against the real,
now-executable container-boot suite, not just read code. Every real
finding resolved in a `/grill-me` session before any code changed;
design decisions are ADRs 0021/0022.

- [x] 35. **Critical fix**: vmauth's read tier (readTokensFile/
      adminPasswordFile) was a blanket passthrough to each backend's
      ENTIRE native API, not a read-only route set -- a read-token could
      reach `/api/v1/import` (write) and `/api/v1/admin/tsdb/delete_series`
      (permanent delete), verified live before the fix. Rewritten as a
      curated, closed-world allow-list per backend (ADR 0021), not
      vmauth's native `deny_paths` (fails open on a future unknown
      endpoint; an allow-list fails closed -- the opposite failure mode).
- [x] 36. vmauth/nginx structural fixes: `nginx.enable -> vmauth.enable`
      assertion also now requires a real backend enabled (vmauth.enable
      alone was structurally inert with zero backends); new
      `backendTls.certFile`/`keyFile` both-or-neither assertion;
      malformed-YAML validation in vmauth-render-config with a legible
      error (confirmed RED-before-fix); full-combination container-boot
      test (3 tiers + extraReadUrlMap + headers); credentialed write-tier
      cross-container roundtrip tests for logs/traces (mirroring the
      existing metrics one); custom-domain + grafana-disabled nginx
      live-request test (the 4th and last domain x grafana.enable
      combination).
- [x] 37. MCP fixes: `effectiveUrl` seam (docs/decisions/0019) extended to
      mcp.nix's own backend connection, a 4th consumer missed when that
      ADR was written; TCP-then-HTTP wait4x readiness probe on each
      mcp-victoria*.service + vmauth's own `after`/`wants` on all 3;
      `mcp-reachable-only-through-vmauth` was vacuous (every route always
      got vmauth's own 401 with no credential, never reaching the
      backend at all) -- rewritten using a real MCP `initialize` handshake
      + per-backend `serverInfo.name` assertion.
- [x] 38. Grafana: 4 of 7 non-empty backend combinations had no dedicated
      datasource-provisioning test (logs-only, traces-only,
      metrics+logs, metrics+traces); `lib.warnIf` for
      `grafana.enable = true` with zero backends (the only reason to use
      this module's own grafana.enable over plain services.grafana.enable
      is the auto-wiring, which delivers nothing with zero backends).
- [x] 39. Fixed factually-wrong retention-period docs: metrics/logs both
      claimed "effectively unbounded" when the flag is omitted -- false,
      confirmed via each binary's own --help (metrics defaults to 1
      month, logs to 7 days; traces' equivalent claim was already fixed
      in Phase 20/ADR 0020, metrics/logs never were). Added a
      hostType-genuinely-absent-for-logs-only regression test (already
      correct, intentional, just untested).
- [x] 40. journal-upload/Alloy resilience: same-host ordering
      (`after`/`wants` on vmauth.service, safe no-op when victoriaStack
      isn't composed on the host) for both units; cross-host fix
      (`systemd-journal-upload.service`'s `startLimitIntervalSec = 0`,
      disabling the permanent-stop ceiling for an intermittent-network
      host like a laptop -- the existing escalating backoff stays
      untouched).
- [x] 41. nginx TLS: no new TLS/ACME option added -- `"victoria-stack"`
      declared a stable, documented, intentional public extension point
      (new ADR 0022) an operator adds real nginx TLS options
      (forceSSL/addSSL, enableACME, sslCertificate*) to directly, same
      philosophy as ADR 0010's Grafana integration. One real combined
      HTTP+HTTPS container-boot test (throwaway self-signed cert,
      mirroring the collector's existing dummyClientCert pattern).
- [x] 42. Cross-cutting: `concurrency:` groups on
      update-dependencies.yml/ci.yml/ci-stable.yml; this file's own
      stale phase-3-11 checkboxes (fixed, pointing at Phase 34);
      generate-doc.nix's stale usage comment; tests/full.nix expanded to
      genuinely exercise all 3 signal types end to end through vmauth
      (previously metrics-only) plus a real MCP `tools/call`, not just
      the `initialize` handshake.
- [x] 43. Final fresh-agent re-review (4 parallel agents, same scope
      split as Round 3's start) + fix pass. Found and fixed: Alloy's
      explicit `restartTriggers` shadowed nixpkgs' own newer
      `reloadTriggers` for the identical content, forcing a full
      stop+start on every collector config change where nixpkgs' alloy
      module is specifically designed to reload in place (confirmed via
      a real switch-to-configuration test, MainPID changed vs. stayed
      stable); the 3 storage services' wildcard-readiness substitution
      was missing the bare `":<port>"` form the real upstream modules
      already handle (reproduced a genuine 5/5-then-20/20 pass/fail
      flake); nginx had no systemd ordering on vmauth.service or
      grafana.service at all (confirmed via `systemctl show -p After` on
      a live container); vmauth itself got the same TCP-readiness-probe
      treatment MCP already had; mcp-victoriametrics' own
      `disabledTools` silently re-enabled 6 upstream-default-disabled
      tools (including one that WRITES synthetic series) whenever the
      option was set at all -- fixed to union with the upstream default
      set, confirmed live both before and after; Grafana's datasource
      provisioning added `prune: true` per Grafana's own docs, but
      confirmed via a real switch-to-configuration test that it's
      currently a no-op due to a known, previously-filed, only
      very-recently-fixed upstream Grafana bug -- added anyway (correct,
      free once the pinned package catches up) and documented honestly
      rather than asserting a live behavior that's verifiably false
      today; update-dependencies.yml's two-job `needs:` ordering never
      actually protected the second job's push (actions/checkout
      defaults to the run-triggering SHA in every job regardless of
      `needs:`) -- fixed with `git pull --rebase` before each job's own
      push; README.md's fetchTarball snippet pointed at a now-nonexistent
      `master` branch (a Phase 29 fix for a since-resolved local/remote
      mismatch, never reverted).

## Round 4: design-focused critical review (test gaps / missing options / bad
design, explicitly NOT a bug hunt) + grill session for the judgment calls

4 fresh agents (storage/collector; vmauth/nginx; grafana/mcp; cross-cutting),
each told explicitly NOT to re-hunt Phase 43's bug class, but to assess the
test MATRIX for holes, cross-reference real upstream docs for configurability
this module doesn't expose, and flag architectural smells. One correction
surfaced during triage: the collector's host-metrics collection was initially
misread as "only systemd unit-state" -- confirmed live (real stack+collector
boot, queried `/api/v1/label/__name__/values`) that `enable_collectors`
*adds to* node_exporter's own default-enabled set, not replaces it -- the
collector already ships a comprehensive real set (`node_cpu_*`,
`node_memory_*`, `node_disk_*`, `node_filesystem_*`, `node_network_*`,
`node_load*`, `node_zfs_*`, etc.) alongside systemd state. The real gap is
narrower: no option to customize that set further (Phase 44 item below).

Findings sorted into 3 buckets per the project owner's own direction: test
gaps (fix directly, no ambiguity), hardening/obvious improvements (clear
right answer, no real tradeoff -- write into the plan same as test gaps),
and judgment calls (real design tradeoffs or scope questions -- grill
session before any code changes, same discipline as Round 2/Round 3).

- [x] 44. **Test gap fixes** (tracked here, phases TBD once grill session's
      results are folded in -- some test gaps depend on a judgment call
      below, e.g. the vmauth full-combination test can't include MCP until
      the grill session resolves whether MCP gets a dedicated credential
      scope):
      - Alloy TLS/retry options: real container-boot test (self-signed
        cert + CA verification), not eval-only string-matching.
      - `queue.directory` outside StateDirectory: real container-boot test
        confirming write actually succeeds, not just that `ReadWritePaths`
        contains the entry.
      - `hostType` conditional requirement: both the valid omission
        (logs-only) and the (currently ugly) failure mode (metrics/traces
        enabled, `hostType` unset) need their own test -- the latter
        depends on Phase 45's new `victoriaCollector/assertions.nix`
        existing first, so the test asserts the NEW legible message.
      - `manageTmpfiles = false` + default (not custom) `dataDir`.
      - `tests/collector.nix`: a native 3-signals-at-once test, not just
        indirect coverage via `tests/full.nix`'s shared example config.
      - `nginx`'s ADR-0016 "mirrors what it fronts" check: override
        `idleConnTimeout` to a non-default value in the test fixture so
        the assertion can actually fail.
      - `extraRequestHeaders`/`extraResponseHeaders`: extend the existing
        inert-unless-configured check to also parse `WRITE_URL_MAP_FILE`
        and `OPEN_INGEST_PATHS_FILE` (ties to Phase 45's `openIngestPaths`
        contract fix -- write the test to confirm the FIXED behavicor).
      - `writeTokensFile` malformed-YAML path: mirror the existing
        `readTokensFile` regression test.
      - `vmauth.listenAddress` override + `nginx.enable` together.
      - `openIngestPaths` with a genuine partial/custom override (not just
        the two extremes already tested).
      - `nginx.domain` combined with a credentialed vmauth tier (an auth
        header through a name-based, not catch-all, virtualHost).
      - Eval-only check: MCP `url_map` entries genuinely absent when
        `mcp.enable = false` (mirrors the existing inert-unless-configured
        pattern already used elsewhere).
      - `effectiveUrl` seam: pinning tests for `grafana.nix`'s
        `datasourceSpecs` and `vmauth.nix`'s `readUrlMap`/
        `autoOpenIngestPaths` (only `mcp.nix` has one today).
      - MCP folded into `vmauth.nix`'s own full-combination test (3 tiers +
        extraReadUrlMap + headers + `mcp.enable`), rather than a new,
        separate test.
      - nginx -> vmauth -> `/mcp/*`: one real request through nginx, not
        only direct-to-vmauth.
      - `vmauth.enable = false` + MCP left at its loopback default
        (distinct from the already-tested "explicitly widened" case).
      - Grafana x nginx: confirm the datasource URL stays loopback even
        with nginx/domain also enabled.
      - MCP's own wildcard-listenAddress detection (`[::]:`, bare `:port`):
        eval-only pinning test, mirroring the fix already applied
        project-wide in Phase 43 for the storage services' copy of the
        same logic.
      - Multi-host fleet: 2+ independent collector containers writing to
        the same gateway concurrently (not just 1-collector-1-gateway).
      - The documented `mkForce`-reconstruct Grafana datasource-tuning
        workaround (ADR 0020's own escape-hatch advice): a real test
        proving it works as documented, not just a plausible-sounding
        claim.
      - Cross-service port/listenAddress collision: ties to Phase 45's new
        assertion -- test that it actually fires.
      - Read-tier bearer token reaching an MCP route end-to-end (only the
        admin credential is tested against MCP today).
      - One real, maximal cross-product test (custom domain + TLS + all 3
        credential tiers + all 3 backends + all 3 MCP servers + Grafana +
        a real collector shipping real data, all at once) -- the dimension
        this whole bucket's findings kept surfacing as never-combined.
- [x] 45. **Hardening / obvious improvements** (clear right answer, no
      real tradeoff -- implement directly, no grill needed):
      - Fix `openIngestPaths`: a custom override currently bypasses
        `withExtraHeaders` entirely, breaking the option's own documented
        contract ("headers apply uniformly across every url_map entry...
        read, write, and MCP routes alike") the moment an operator uses
        the escape hatch for its stated purpose.
      - New `victoriaCollector/assertions.nix` (none exists today, unlike
        `victoriaStack`'s) -- at minimum, a legible `hostType` required
        -when-(metrics.enable || traces.enable) message instead of today's
        raw Nix module-system error.
      - Refactor `metrics.nix`/`logs.nix`/`traces.nix` (~95% copy-paste)
        into a shared `mkStorageService` helper, mirroring the
        `mkStorageServiceOptions` (options.nix) / `mkMcpService` (mcp.nix)
        pattern this project already established twice for the identical
        problem shape. No behavior change.
      - `RequiresMountsFor`/`after = ["local-fs.target"]` wired to each
        storage service's own `dataDir`, closing the "custom dataDir on a
        slow-to-mount dataset starts before the mount is ready" gap --
        harmless no-op when `dataDir` sits on the root filesystem already.
      - nginx: `proxy_set_header X-Real-IP $remote_addr;` +
        `X-Forwarded-For $proxy_add_x_forwarded_for;` on both `/victoria/`
        and `/grafana/` locations -- standard reverse-proxy hygiene
        (confirmed against nginx's own docs), zero downside, doesn't
        require vmauth to consume the header to be a net improvement.
      - Cross-service port/listenAddress collision assertion (metrics/
        logs/traces/vmauth/3xMCP all resolve to distinct addresses).
      - `services.victoriaStack.{metrics,logs,traces}.selfScrapeInterval`
        (and vmauth's own equivalent) -- `-selfScrapeInterval`, inert
        unless configured, same shape as `logLevel`/`retentionPeriod`.
      - Disk-usage-based retention options for logs/traces
        (`-retention.maxDiskSpaceUsageBytes`/`-retention.maxDiskUsagePercent`),
        inert unless configured, same shape as `retentionPeriod`.
      - ADR 0002 amendment note: its documented invariant
        (`nginx.enable -> vmauth.enable`) is stale against the actual,
        correctly-fixed assertion (`-> vmauth.enable && anyBackendEnabled`,
        Phase 36) -- give it the same `## Status` treatment ADR 0012 used
        for its own supersession.
      - New short ADR explicitly extending ADR 0010's same-host-trust
        reasoning to MCP's own backend connection (today only argued
        inline in a `mcp.nix` comment, no ADR number).
      - New short ADR documenting this project's current option-stability
        stance (pre-1.0, no versioning promise yet) and committing to
        `lib.mkRenamedOptionModule` for any future option RENAME once it
        does -- non-retroactive, a forward-looking policy only.

## Round 4 continued: grill session results (judgment calls)

9 topics, each with the project owner's own recommended-first-choice
decision, a few genuinely redirected the initial recommendation after
real codebase investigation (confirmed, not assumed) surfaced a fact that
changed the tradeoff -- same discipline as Round 2/3's own grill sessions
(docs/decisions/0014-0020, 0021-0022). New ADRs get written during
implementation, not here -- this section only records the decision.

- [x] 46. **Naming unification**: `extraOptions` (metrics/logs/traces) and
      `extraFlags` (Alloy) are the identical concept under two names --
      unify on `extraFlags` (the more literally accurate term: these are
      real CLI flags, not generic "options") via
      `lib.mkRenamedOptionModule` for the 3 renamed storage options.
- [x] 47. **vmauth's own `extraFlags`**: vmauth has no CLI-passthrough
      escape hatch at all today (confirmed via grep), unlike the other 3
      services -- add `vmauth.extraFlags`, same shape as #46. Covers
      vmauth's own TLS listener (`-tls`/`-tlsCertFile`/`-tlsKeyFile`,
      confirmed real vmauth flags) for operators who bypass nginx
      entirely, plus anything else, without a bespoke option per flag.
- [x] 48. **Multi-host fleet**: a real 2-collector + 1-gateway
      container-boot test (concurrent writers, `hostType` label
      distinctness under real load) AND a documented multi-host example
      (`examples/fleet.nix` or a new README section) showing the actual
      NixOS config shape for N collector hosts -> 1 gateway.
- [x] 49. **`.gitleaksignore` -> inline `gitleaks:allow`**: migrate every
      pinned line-number entry to an inline `# gitleaks:allow` comment on
      the fixture's own line (gitleaks' own first-class, documented
      mechanism for exactly this case -- confirmed via real gitleaks
      docs), then delete `.gitleaksignore` entirely. Survives any future
      edit to the file above/below it; no separate file to keep in sync.
- [-] 50. (DROPPED -- see "Round 4 outcome") **vmauth consumes `X-Forwarded-For` automatically when nginx is
      on**: not a new user-facing option -- `vmauth`'s `-httpRealIPHeader`
      gets set to `X-Forwarded-For` via `lib.mkIf cfg.nginx.enable
      (lib.mkDefault "X-Forwarded-For")`, still overridable. When nginx is
      off (direct-bypass), nothing is set -- same "bypass = your own
      setup" precedent already established elsewhere in this project.
- [x] 51. **`extraWriteUrlMap`**: symmetric with the existing
      `extraReadUrlMap`, scoped to the write-tier credential only. Real
      use case confirmed via upstream docs: VictoriaMetrics' own `/write`
      (InfluxDB line protocol) and `/api/v1/write` (Prometheus
      remote-write) are genuine same-listener HTTP paths this module
      doesn't open a door for today -- e.g. an existing Telegraf fleet
      writing through the same gateway/write-token already issued to
      Alloy-based collectors. Includes a wildcard-pattern guardrail eval
      test (same closed-world-check style ADR 0021 already uses for the
      built-in entries), so a careless `src_paths = [".*"]` in this
      escape hatch gets flagged.
- [x] 52. **Per-token scoping (read AND write tiers)**: `readTokensFile`/
      `writeTokensFile`'s YAML format changes from a bare list of strings
      to a uniform list of `{token, backends}` objects (`backends`
      optional -- omitted means today's behavior, all enabled backends).
      `backends: ["traces"]` automatically includes that signal's own MCP
      route too (`/mcp/traces`, if `traces.mcp.enable`) -- matches the
      project's own test-fixture naming hint ("ai-client-a" read token),
      where MCP access is almost always the actual point of a scoped
      AI-client credential. Filtering reuses the url_map's own existing
      per-backend path-prefix convention (ADR 0021) -- no change to how
      the allow-list itself gets built, only to which subset of it a
      given token's user entry receives. BREAKING YAML format change --
      needs a clear migration note (not Nix-auto-migratable: token file
      content lives in operator-managed secrets, outside this module's
      control per docs/decisions/0008). `validate_tokens_shape` (vmauth.nix)
      needs updating to require the new object shape, with a legible
      error distinguishing "still using the old bare-string format" from
      a genuinely malformed file.
- [x] 53. **Collector metrics customization**: mirrors Alloy's own real
      3-knob `prometheus.exporter.unix` model exactly (confirmed via
      Alloy's own docs) -- `services.victoriaCollector.metrics.{
      extraCollectors, disabledCollectors, scrapeInterval}`.
      `extraCollectors` adds on top of (node_exporter's own defaults +
      `"systemd"`, today's hardcoded set), `disabledCollectors` removes
      specific ones, `scrapeInterval` overrides Alloy's own default
      (confirmed `"60s"`). All null/[]-default, inert unless configured.
      No upstream nixpkgs `services.alloy` option to inherit from
      (confirmed: that module is deliberately generic, only
      `enable`/`package`/`configPath`/`environmentFile`/`extraFlags` --
      this project is the one generating the actual `.alloy` pipeline
      config, so it's the one that has to expose this).
- [x] 54. **On-disk snapshot creation + pruning** (metrics/logs/traces,
      each independently): confirmed via real upstream docs that
      snapshotting is NOT automatic on its own (`/snapshot/create` is a
      pure on-demand HTTP endpoint, nothing inside the binaries schedules
      it) and that a snapshot never leaves the host's own disk (lives
      under `<dataDir>/snapshots/`, hardcoded location, not configurable)
      -- real protection against accidental/logical data loss, NOT disk
      failure; the actual off-host-shipping step needs VictoriaMetrics'
      own separate `vmbackup` tool, explicitly out of scope for this
      phase (a real, separate judgment call of its own -- which
      destinations to support, how to pass credentials -- deferred, not
      forgotten). New `snapshots = { enable (default false, opt-in per
      docs/decisions/0002); schedule (systemd OnCalendar string, default
      "daily"); maxAge (nullable string, default "30d", -snapshotsMaxAge,
      null disables automatic pruning -- confirmed this flag makes the
      binary prune itself, no separate timer needed for that half) }`.
      Snapshot creation needs its own systemd timer + oneshot calling
      `/snapshot/create`; deletion of an individual snapshot (not the
      automatic age-based pruning) must go through `/snapshot/delete`,
      never raw `rm`/`cp`/`rsync` (confirmed: snapshots are hardlinks into
      live data, those commands can silently corrupt them) -- worth a
      code comment at the one place this matters, not a feature, since
      this module never touches snapshot contents directly itself.

## Round 4 outcome (what actually shipped, and where it differed from the plan)

All of Phases 44-54 shipped except 50, each gated with `nix flake check -L`,
committed and pushed separately. Deviations worth knowing:

- **44** -- all 23 test gaps closed. The new tests found two pre-existing
  bugs: `hostType` arrived as the label `host.type` (not the documented
  `host_type`; fixed afterwards, see below) and a collector `writeEndpoint`
  with a path but no port broke systemd-journal-upload (now a warning).
  They also exposed a vacuous nginx assertion ("a different Host is refused"
  -- it is not, with a single virtualHost; the old probe passed on a 401).
- **45** -- item 1 assumed `withExtraHeaders` was idempotent; it
  concatenates, so it is applied once at serialization instead. Item 7
  (`selfScrapeInterval`) was dropped as specified: only victoria-metrics has
  the flag. Replaced by `selfMonitoring` on all four services via the
  `-pushmetrics.*` family they share (ADR 0026), on by default whenever the
  metrics database is enabled, with a warning when it conflicts with the
  operator's own `-pushmetrics.*` flags. Item 8's real flag names are
  `-retention.maxDiskSpaceUsageBytes` / `-retention.maxDiskUsagePercent`
  (logs/traces only).
- **46** -- `extraFlags` rename with a `mkRenamedOptionModule` shim, ADR 0024.
- **47-49, 51, 53** -- as planned. 49 uses inline `gitleaks:allow`; one ADR
  example whose line ends in a shell `\` uses a `$READ_TOKEN` placeholder.
- **50 DROPPED** -- vmauth's `-httpRealIPHeader` is Enterprise-only (absent
  from the open-source binary's `-help` and source). Behind a reverse proxy
  vmauth cannot be told to trust a forwarded address; the real client stays
  readable in the proxy's own log and in vmauth's failure log lines (last
  `X-Forwarded-For` entry). Collectors that write straight to vmauth's own
  doors are unaffected. Documented in docs/architecture.md, "Client
  addresses behind a reverse proxy".
- **52** -- BREAKING token file format (`- token: <value>`, optional
  `backends`); the old bare-string format fails at start with a migration
  message.
- **54** -- the snapshot API differs per binary (metrics: `/snapshot/*`;
  logs/traces: POST-only `/internal/partition/snapshot/*`); `-snapshotsMaxAge`
  exists on all three.

Added during the round, beyond the plan:
- **Phase 55** -- vmauth public write doors `vmauth.https` / `vmauth.http`
  (ipAddress + port, operator cert files or an existing ACME cert name),
  nginx `/victoria/` reads-only (BREAKING for writes through nginx), ADR 0025.
  No redirect option: vmauth cannot redirect.
- `vmauth.accessLog` (default off) so successful writes log their source.
- Every CA bundle (vmauth backend, Alloy, journal-upload) now goes through
  `LoadCredential`, like the other TLS/secret files.
- Collector `host_type` label spelling fixed; a collector warning for a
  journald endpoint with no explicit port (journal-upload would append its
  default 19532).
- A latent race in the alloy-reload test (reload sent before Alloy was
  ready) fixed by waiting for `/-/ready`.

Each phase: gate with `nix flake check -L` (run detached, polled — never a
single tool-call timeout for a full nspawn build) + nixfmt-rfc-style clean,
commit separately, push. Any genuinely open question discovered mid-phase
gets researched (nixpkgs source, sibling repos, upstream docs) and recorded
as a new ADR in the same commit — never guessed past silently.
