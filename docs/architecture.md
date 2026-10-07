# Default wiring and network topology

This page exists because "what's actually reachable from where, by
default" is the one piece of the design that can't be read off any single
option's own description — it's a property of how the pieces combine.
See the individual ADRs (`docs/decisions/`) for the reasoning behind each
component's own choices; this page is purely the connective picture.

## Default bind addresses — everything is loopback-only except nginx

```
┌────────────────────────────┬───────────────────┬──────────────────────┐
│ Service                     │ Default bind       │ Externally reachable │
│                              │                     │ out of the box?       │
├────────────────────────────┼───────────────────┼──────────────────────┤
│ services.victoriaStack       │                     │                        │
│   .metrics                   │ 127.0.0.1:4201      │ No                     │
│   .logs                      │ 127.0.0.1:4202      │ No                     │
│   .traces                     │ 127.0.0.1:4203      │ No                     │
│   .vmauth                     │ 127.0.0.1:4204      │ No -- see note below   │
│   .vmauth.https (opt-in)      │ 0.0.0.0:8443        │ YES once enabled --    │
│                                │                     │ the collectors' write  │
│                                │                     │ door (ADR 0025)        │
│   .vmauth.http (opt-in)       │ 0.0.0.0:8080        │ As configured: open,   │
│                                │ (or 127.0.0.1)      │ or loopback for        │
│                                │                     │ `tailscale serve`      │
│   .metrics.mcp                │ 127.0.0.1:4205      │ No                     │
│   .logs.mcp                   │ 127.0.0.1:4206      │ No                     │
│   .traces.mcp                 │ 127.0.0.1:4207      │ No                     │
│   .nginx                      │ nixpkgs' own        │ YES, by design --      │
│                                │ default (all        │ nginx's entire reason │
│                                │ interfaces, :80)    │ to exist here is      │
│                                │                     │ being the public       │
│                                │                     │ front door             │
│   .grafana (datasource         │ (no bind of its      │ N/A -- provisions      │
│    provisioning only)          │ own)                 │ datasources into an    │
│                                │                     │ already-running Grafana│
│ services.grafana (consumer's   │ 127.0.0.1:3000       │ No (nixpkgs' own      │
│  own config, not this module)  │ (nixpkgs default)    │ default)               │
│ services.victoriaCollector      │                     │                        │
│   alloy's local OTLP receiver   │ 127.0.0.1:4317/4318  │ No -- local-apps-only │
│                                │                     │ by design, see         │
│                                │                     │ config.alloy.nix        │
└────────────────────────────┴───────────────────┴──────────────────────┘
```

**Writes and reads use different doors** (docs/decisions/0025): collectors
write to vmauth's own `https` (:8443) / `http` (:8080) listeners; nginx
(:80/:443) fronts reads and Grafana only, and answers 404 to any write path
under `/victoria/`. vmauth's listeners share one routing config, so the
public doors also accept (credentialed) reads.

**Important note on vmauth's default:** vmauth is the one service in
`victoriaStack` whose entire *purpose* is accepting traffic from other
hosts (fleet collectors, external Grafana/MCP clients) — but its default
`listenAddress` is loopback-only, same as everything else, consistent
with this project's "opt-in, nothing reachable until you say so"
philosophy (ADR 0002). **A real multi-host deployment must explicitly
override `services.victoriaStack.vmauth.listenAddress`** (e.g. to a
tailnet address, or `0.0.0.0:4204` behind your own firewall) — nothing
about vmauth being "the gateway" makes this happen automatically.

## Connection topology

```
                                    ┌─────────────────────────┐
                                    │   external / fleet       │
                                    │   collector hosts         │
                                    └───────────┬───────────────┘
                                                │ (only if vmauth's
                                                │  listenAddress is
                                                │  explicitly exposed)
                                                ▼
┌───────────────────────────────────────────────────────────────────┐
│ this host                                                            │
│                                                                      │
│   ┌──────────┐       ┌───────────────────────────────────────┐      │
│   │  nginx    │──────▶│              vmauth                    │      │
│   │ (:80,     │ /victoria/                                     │      │
│   │  public)  │       │  readUrlMap / openIngestPaths /         │      │
│   │           │       │  writeUrlMap (docs/decisions/0014)       │      │
│   │           │       └──┬──────┬──────┬──────┬──────┬──────┬───┘      │
│   │           │          │      │      │      │      │      │          │
│   │           │ /grafana/│      │      │      │      │      │          │
│   │           │──────────┼──────┼──────┼──────┼──────┼──────┼──┐       │
│   └──────────┘          │      │      │      │      │      │  │       │
│                          ▼      ▼      ▼      ▼      ▼      ▼  │       │
│                       metrics logs  traces mcp-×3 (each       │       │
│                       :4201  :4202  :4203  proxies to its own  │       │
│                                            co-located backend) │       │
│                                                                 ▼       │
│                                                             Grafana     │
│                                                          (:3000, direct │
│                                                           loopback,     │
│                                                           own auth --   │
│                                                           NEVER through │
│                                                           vmauth, ADR   │
│                                                           0010)         │
│                                                                      │
│   ┌──────────────────────────────────────────────────────┐          │
│   │ victoriaCollector (can be this SAME host, self-         │          │
│   │ monitoring -- or any other host on the fleet)           │          │
│   │                                                          │          │
│   │  systemd-journal-upload ───────────────────────────────┼──▶ vmauth's open/write-tier
│   │  (logs, bypasses Alloy entirely -- ADR 0005)            │          │   ingest routes, via
│   │                                                          │          │   writeEndpoint
│   │  Alloy (metrics + traces, OTLP) ────────────────────────┼──▶ (same path)
│   │   └─ local OTLP receiver :4317/4318, loopback-only,     │          │
│   │      for apps ALREADY on this host that speak OTLP      │          │
│   │      themselves (no network exposure, by design)        │          │
│   └──────────────────────────────────────────────────────┘          │
└───────────────────────────────────────────────────────────────────┘
```

## Client addresses behind a reverse proxy

**Warning:** with a reverse proxy in front of vmauth (the bundled nginx, or
any other), vmauth sees the proxy's address as the client, not the real one.
vmauth's setting for trusting a forwarded-address header
(`-httpRealIPHeader`) exists only in VictoriaMetrics' Enterprise edition, so
it is not available in the open-source build this module uses.

```
client 203.0.113.5 ──> nginx ──> vmauth      vmauth sees nginx's address
client 203.0.113.5 ──────────> vmauth :8443  vmauth sees 203.0.113.5   (not affected)
```

What you still have behind a proxy:
- the proxy's own log records the real client (nginx does by default);
- vmauth appends the `X-Forwarded-For` text to the log lines it writes for
  failed requests -- only the LAST entry, the one your proxy added, can be
  trusted, because a client can put anything before it.

Collectors that write straight to vmauth's own doors
(`vmauth.https` / `vmauth.http`, docs/decisions/0025) are not affected.

## Key properties this diagram makes explicit

- **Grafana is never reached through vmauth**, in either direction —
  nginx's `/grafana/` location and vmauth's `/metrics/`, `/logs/`,
  `/traces/` routes are structurally separate paths to separate backends
  (ADR 0010).
- **vmauth is the only thing every storage backend's own native API
  goes through** when reached from outside this host — metrics/logs/
  traces/mcp×3 all bind loopback-only and have no other sanctioned way
  out.
- **The collector's local OTLP receiver has no relationship to vmauth at
  all** — it's a separate, loopback-only endpoint for host-local
  OTLP-speaking applications, unrelated to the fleet-shipping path the
  same Alloy instance also runs.
- **Nothing in this topology is reachable from another host until you
  explicitly widen a `listenAddress`** (vmauth's, mcp's, or a storage
  service's directly) — the single documented exception is nginx, whose
  entire purpose is being the externally-reachable front door, and even
  that requires `services.victoriaStack.nginx.enable = true` to exist at
  all.
- **nginx speaks plain HTTP only, by design** — `services.nginx.
  virtualHosts."victoria-stack"` is a stable extension point (ADR 0022)
  an operator adds `forceSSL`/`enableACME` (or any other real nginx TLS
  option) to directly; this module itself never does. The one TLS this
  module does configure is vmauth's own opt-in write door (`vmauth.https`,
  ADR 0025), which takes a cert/key pair or an existing ACME cert name.
