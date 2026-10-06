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

## Repository layout (target)

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
tests/{default,assertions,storage,vmauth,grafana,nginx,mcp,collector,full}.nix
```

## Options surface (agreed)

```
services.victoriaStack = {
  metrics = { enable; package; dataDir; dynamicUser; listenAddress;
              retentionPeriod; extraOptions; suppressDynamicUserWarning;
              mcp = { enable; package; listenAddress; }; };
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
  hostType;                # free-form str, no enum
  queue = { maxSizeBytes; directory; };  # default 1GiB / /var/lib/alloy/queue
  alloy.package; alloy.extraFlags;
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
  kept for non-secret settings; a separate `conf.d/*.conf` drop-in symlinked
  at a `sops.templates.*.path` carries just the `Header=` line. No hand-rolled
  systemd unit for this one.
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
- [~] 3. `storage`: metrics (implemented, eval-only checks green; 3
      container-boot checks implemented but NOT locally verifiable --
      this dev machine's Nix daemon lacks `uid-range` system feature;
      needs `nix.settings.auto-allocate-uids` enabled on the host, or CI
      verification once push access is restored. See
      docs/decisions/0011-local-nspawn-verification-blocker.md)
- [~] 4. `storage`: logs (same status as metrics -- implemented,
      eval-only checks green, container-boot checks pending
      docs/decisions/0011)
- [~] 5. `storage`: traces (same status as metrics -- implemented,
      eval-only checks green, container-boot checks pending
      docs/decisions/0011)
- [~] 6. `vmauth` (same status -- implemented, eval-only check green,
      5 container-boot checks pending docs/decisions/0011)
- [~] 7. `grafana` (implemented, 3 container-boot checks pending
      docs/decisions/0011 -- no eval-only checks in this group, all 3
      confirmed failing only for the known reason)
- [~] 8. `nginx` (implemented, 2 container-boot checks pending
      docs/decisions/0011)
- [~] 9. `mcp`: 3 real buildGoModule packages built + wiring implemented
      (2 container-boot checks pending docs/decisions/0011)
- [~] 10. `victoriaCollector` (implemented, including the cross-container
      metrics-roundtrip test; 3 container-boot checks pending
      docs/decisions/0011)
- [~] 11. `full` / `examples` assembly (implemented, 1 container-boot
      check pending docs/decisions/0011)
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
- [ ] 32. Final full `nix flake check -L` gate
- [ ] 33. Fresh-agent re-review round 3, triage, final push

Each phase: gate with `nix flake check -L` (run detached, polled — never a
single tool-call timeout for a full nspawn build) + nixfmt-rfc-style clean,
commit separately, push. Any genuinely open question discovered mid-phase
gets researched (nixpkgs source, sibling repos, upstream docs) and recorded
as a new ADR in the same commit — never guessed past silently.
