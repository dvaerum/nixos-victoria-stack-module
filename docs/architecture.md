# Default wiring and network topology

This page exists because "what's actually reachable from where, by
default" is the one piece of the design that can't be read off any single
option's own description — it's a property of how the pieces combine.
See the individual ADRs (`docs/decisions/`) for the reasoning behind each
component's own choices; this page is purely the connective picture.

## Default bind addresses — everything is loopback-only except nginx, the opt-in vmauth doors and the opt-in syslog slots

```
┌────────────────────────────┬───────────────────┬──────────────────────┐
│ Service                     │ Default bind       │ Externally reachable │
│                              │                     │ out of the box?       │
├────────────────────────────┼───────────────────┼──────────────────────┤
│ services.victoriaStack       │                     │                        │
│   .metrics (vmselect, reads) │ 127.0.0.1:4201      │ No                     │
│   .metrics.insert (vminsert)  │ 127.0.0.1:4209      │ No                     │
│   .metrics.storage (vmstorage)│ 127.0.0.1:4210      │ No -- own HTTP only;   │
│                                │ (RPC 4211/4212)     │ RPC is loopback, fixed │
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
│   .logs.syslog.{udp,tcp,tls,   │ (no listener until   │ YES once an address is │
│    listeners.*} (opt-in)       │ ipAddress is set;    │ set -- unauthenticated,│
│                                │ ports 514/514/6514)  │ TLS only encrypts      │
│                                │                     │ (ADR 0031, 0035)       │
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
│   (traces.enable only)         │                     │ by design, see         │
│                                │                     │ config.alloy.nix        │
└────────────────────────────┴───────────────────┴──────────────────────┘
```

**Writes and reads use different doors** (docs/decisions/0025): collectors
write to vmauth's own `https` / `http` listeners; nginx fronts reads and
Grafana only. The public doors also accept (credentialed) reads.

**Syslog is a third door that bypasses vmauth** (docs/decisions/0031, 0035): devices
that only speak syslog write straight to VictoriaLogs' own listeners, which have
no authentication, so vmauth's per-host tokens do not apply to them. The slots
and the named `listeners` are opt-in, and the module opens no firewall port unless
one sets `openFirewall`. The listener a packet reaches decides its tenant.

**Important note on vmauth's default:** vmauth is the one service in
`victoriaStack` whose entire *purpose* is accepting traffic from other
hosts (fleet collectors, external Grafana/MCP clients) — but its default
`listenAddress` is loopback-only, same as everything else, consistent
with this project's "opt-in, nothing reachable until you say so"
philosophy (ADR 0002). **A real multi-host deployment must explicitly
enable `services.victoriaStack.vmauth.https` and/or `.http`** (ADR 0025) —
extra listeners on the same vmauth; `listenAddress` stays the internal
loopback listener.

## Connection topology

Who talks to whom, by default. "Read tier" and "write tier" are vmauth's two
credential tiers (ADR 0003); the admin password is a read-tier credential.

| Component | Listens on (default) | Reached by | Talks to | Auth (which tier) |
|---|---|---|---|---|
| collector: `systemd-journal-upload` (logs) | nothing | -- | vmauth `https`/`http` door via `writeEndpoint` | write token (write tier) |
| collector: Alloy (metrics, traces) | nothing; with `traces.enable` a local OTLP receiver on `127.0.0.1:4317` (gRPC) / `:4318` (HTTP) | apps on the same host (receiver) | vmauth `https`/`http` door via `writeEndpoint` | write token (write tier); the receiver has none |
| vmauth, public doors (opt-in) | `https` `0.0.0.0:8443`, `http` `0.0.0.0:8080` | collectors; remote Grafana and MCP clients | the same routes as the internal listener | per request: write or read token |
| vmauth, internal listener | `127.0.0.1:4204` (data), `127.0.0.1:4208` (own pages only) | nginx, local Grafana and MCP servers, local callers | vminsert, vmselect, logs, traces, the three MCP servers | per request: write tier (ingest routes) or read tier (read routes and `/mcp/*`) |
| vminsert (metrics writes) | `127.0.0.1:4209` | vmauth; the stack's own self-monitoring pushes | vmstorage (RPC `127.0.0.1:4211`) | none (loopback) |
| vmselect (metrics reads) | `127.0.0.1:4201` | vmauth | vmstorage (RPC `127.0.0.1:4212`) | none (loopback) |
| vmstorage | `127.0.0.1:4210` (own HTTP) | vminsert, vmselect over its RPC ports | disk | none (loopback) |
| VictoriaLogs | `127.0.0.1:4202`; opt-in `syslog` slots on 514 (udp, tcp) / 6514 (tls) | vmauth; syslog devices (slots) | disk | none; the slots take no token and bypass vmauth (ADR 0031) |
| VictoriaTraces | `127.0.0.1:4203` | vmauth | disk | none (loopback) |
| MCP servers (metrics, logs, traces) | `127.0.0.1:4205` / `4206` / `4207` | vmauth, at `/mcp/<service>` | vmauth's read tier (internal listener), with the caller's own token | the caller's read token, checked by vmauth |
| Grafana (consumer's own) | `127.0.0.1:3000` | nginx at `/grafana/`; browsers | vmauth's read tier (internal listener) through the provisioned datasources | Grafana's own login; its datasources use a read token (ADR 0029) |
| nginx (opt-in) | `:80`, all interfaces | browsers and remote clients | vmauth internal listener for `/victoria/{metrics,logs,traces,mcp}` (reads only, other `/victoria/` paths get 404); Grafana for `/grafana/` | none of its own; the read tier at vmauth, Grafana's login for `/grafana/` |

Data flow: collectors send writes to a vmauth public door, and vmauth's write
tier routes them to vminsert, VictoriaLogs and VictoriaTraces. Grafana and the
MCP servers (and anything behind nginx's `/victoria/`) read through vmauth's
read tier, which routes to vmselect, VictoriaLogs and VictoriaTraces.

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

## Key properties this wiring makes explicit

- **Grafana reaches the backends only through vmauth's read tier** (ADR 0029),
  with its own read token; nginx's `/grafana/` location proxies to Grafana
  itself, not through vmauth.
- **vmauth is the only thing every storage backend's own native API
  goes through** when reached from outside this host — metrics/logs/
  traces/mcp×3 all bind loopback-only and have no other sanctioned way
  out, apart from the opt-in doors and slots listed in the "Nothing in this topology"
  bullet below (the `logs.syslog` slots carry no authentication and bypass
  vmauth, ADR 0031).
- **Tenants are decided at the gateway** (ADR 0032): vmauth stamps the tenant of
  a token's entry on its logs and traces routes and sends its metrics to that
  tenant's own cluster path, so the client cannot pick another; the admin tier
  is not stamped. The syslog slots bypass vmauth and carry their own `tenant`.
- **The MCP servers call vmauth's read tier with the caller's own token**
  (`<svc>.mcp.enable` requires `vmauth.enable`), so vmauth alone decides which
  tools work; those outside the read allow-list get vmauth's 400
  (ADR 0023).
- **The collector's local OTLP receiver has no relationship to vmauth at
  all** — it exists only with `traces.enable` (ports
  `traces.receiver.grpcPort`/`httpPort`), a separate, loopback-only endpoint
  for host-local OTLP-speaking applications, unrelated to the fleet-shipping
  path the same Alloy instance also runs.
- **The stack's own services push their metrics straight to the metrics cluster's
  vminsert (`metrics.insert.listenAddress`, loopback by default), bypassing
  vmauth** (`selfMonitoring`, on by default with `metrics.enable`;
  ADR 0026).
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
