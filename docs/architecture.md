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
