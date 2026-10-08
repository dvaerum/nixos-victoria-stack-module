# Default wiring and network topology

This page exists because "what's actually reachable from where, by
default" is the one piece of the design that can't be read off any single
option's own description — it's a property of how the pieces combine.
See the individual ADRs (`docs/decisions/`) for the reasoning behind each
component's own choices; this page is purely the connective picture.

## Default bind addresses — everything is loopback-only except nginx and the opt-in vmauth doors

```
┌────────────────────────────┬───────────────────┬──────────────────────┐
│ Service                     │ Default bind       │ Externally reachable │
│                              │                     │ out of the box?       │
├────────────────────────────┼───────────────────┼──────────────────────┤
│ services.victoriaStack       │                     │                        │
│   .metrics                   │ 127.0.0.1:4201      │ No                     │
│   .logs                      │ 127.0.0.1:4202      │ No                     │
│   .traces                     │ 127.0.0.1:4203      │ No                     │
│   .vmauth (listenAddress)     │ 127.0.0.1:4204      │ No -- internal data    │
│                                │                     │ listener, see note     │
│                                │                     │ below                  │
│   .vmauth.internalListenAddress│ 127.0.0.1:4208      │ No -- /health /metrics │
│                                │                     │ /flags /debug/pprof    │
│                                │                     │ /-/reload (ADR 0027)   │
│   .vmauth.https (opt-in)      │ 0.0.0.0:8443        │ YES once enabled --    │
│                                │                     │ the collectors' write  │
│                                │                     │ door (ADR 0025)        │
│   .vmauth.http (opt-in)       │ 0.0.0.0:8080        │ As configured: open,   │
│                                │ (or 127.0.0.1)      │ or loopback for        │
│                                │                     │ `tailscale serve`      │
│   .logs.syslog.{udp,tcp,tls}  │ (no listener until   │ YES once an address is │
│    (opt-in)                    │ ipAddress is set;    │ set -- unauthenticated,│
│                                │ ports 514/514/6514)  │ TLS only encrypts      │
│                                │                     │ (ADR 0031)            │
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
write to vmauth's own `https` / `http` listeners; nginx fronts reads and
Grafana only. The public doors also accept (credentialed) reads.

**Syslog is a third door that bypasses vmauth** (docs/decisions/0031): devices
that only speak syslog write straight to VictoriaLogs' own listeners, which have
no authentication, so vmauth's per-host tokens do not apply to them. The slots
are opt-in, and the module opens no firewall port unless a slot sets
`openFirewall`.

**Important note on vmauth's default:** vmauth is the one service in
`victoriaStack` whose entire *purpose* is accepting traffic from other
hosts (fleet collectors, external Grafana/MCP clients) — but its default
`listenAddress` is loopback-only, same as everything else, consistent
with this project's "opt-in, nothing reachable until you say so"
philosophy (ADR 0002). **A real multi-host deployment must explicitly
enable `services.victoriaStack.vmauth.https` and/or `.http`** (ADR 0025) —
extra listeners on the same vmauth; `listenAddress` stays the internal
loopback listener. Nothing about vmauth being "the gateway" makes this
happen automatically.

## Connection topology

```
                                    ┌─────────────────────────┐
                                    │   external / fleet       │
                                    │   collector hosts         │
                                    └───────────┬───────────────┘
                                                │ (only via vmauth.https /
                                                │  vmauth.http, ADR 0025)
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
│                                                          (:3000, own    │
│                                                           auth; its     │
│                                                           datasources   │
│                                                           call vmauth's │
│                                                           read tier,    │
│                                                           ADR 0029)     │
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

## Key properties this diagram makes explicit

- **Grafana reaches the backends only through vmauth's read tier** (ADR 0029),
  with its own read token; nginx's `/grafana/` location proxies to Grafana
  itself, not through vmauth.
- **vmauth is the only thing every storage backend's own native API
  goes through** when reached from outside this host — metrics/logs/
  traces/mcp×3 all bind loopback-only and have no other sanctioned way
  out.
- **The collector's local OTLP receiver has no relationship to vmauth at
  all** — it's a separate, loopback-only endpoint for host-local
  OTLP-speaking applications, unrelated to the fleet-shipping path the
  same Alloy instance also runs.
- **Nothing in this topology is reachable from another host until you
  explicitly widen a `listenAddress`** (mcp's or a storage service's
  directly) — the documented exceptions are nginx, whose entire purpose is
  being the externally-reachable front door (requires
  `services.victoriaStack.nginx.enable = true`), the opt-in
  `vmauth.https` / `vmauth.http` doors (ADR 0025) and the opt-in
  `logs.syslog` slots (ADR 0031).
- **nginx speaks plain HTTP only, by design** — `services.nginx.
  virtualHosts."victoria-stack"` is a stable extension point (ADR 0022)
  an operator adds `forceSSL`/`enableACME` (or any other real nginx TLS
  option) to directly; this module itself never does. The one TLS this
  module does configure is vmauth's own opt-in write door (`vmauth.https`,
  ADR 0025), which takes a cert/key pair or an existing ACME cert name.
