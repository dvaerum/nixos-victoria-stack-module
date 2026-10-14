# 0032: Tenants are declared in Nix and chosen in the token files (logs and traces)

## Decision

**The table.** `services.victoriaStack.tenants.<name> = { accountId; projectId = 0; }`
declares the AccountID/ProjectID pairs VictoriaLogs and VictoriaTraces keep data
under. Both numbers are 0 to 4294967295. Build-time assertions reject:

- a name outside 1 to 63 characters of `a-z`, `0-9`, `-` (not starting or ending
  with `-`),
- the name `all` (the keyword of `tenants: all`),
- two tenants with the same pair,
- the pair 0:0. It is the implicit default tenant of tokens without a tenant, so it
  has no name and no alias.

The number lives in Nix and token files only carry the name: the number is the
permanent key of the stored data (changing it orphans the data), so it has one
place, and an unknown name is a visible warning instead of a silent new tenant.

**Token keys** (`vmauth.readTokensFile`, `vmauth.writeTokensFile`; logs and traces):

| Entry | Effect |
|---|---|
| `tenant: a` | vmauth stamps tenant `a` (`AccountID`/`ProjectID` headers); a client-sent header is replaced. Read and write tokens. |
| `tenants: [a, b]` or `tenants: all` | Read tokens only. The client picks with the `AccountID` header, only from the list. A missing or unlisted `AccountID` is vmauth's 400 `missing route`, never a default. |
| none of them | Stamped 0:0 as soon as one tenant is declared, so a client header cannot reach another tenant. With no tenant declared the rendered config is byte-identical to one without tenants. |

- The admin tier is never stamped: the admin password picks any tenant with headers.
- A write entry with `tenants` (or `all`) is a warning and gets no access: choosing
  a tenant is the reader's decision, and a writer stays in exactly one.
- The anonymous write door (`requireAuthForWrites = false`) is stamped 0:0 on logs
  and traces when tenants are declared.
- A tenant token gets no `/mcp/*` routes and no metrics routes (a warning says so
  for metrics), and none of the routes added through `extraReadUrlMap` or
  `extraWriteUrlMap`: those are not tenant-bound.
- `tenant` together with `tenants`, or a value of the wrong type, stops the render
  naming the entry. Undeclared names, two tenants of one account in a list, and
  `tenants: all` with nothing declared warn and drop that access.

**The vmauth pitfall.** `src_headers: ["AccountID: 7"]` matches when ANY value of a
repeated header equals 7, and vmauth forwards all the values. A client sending
`AccountID: 7` and `AccountID: 8` would pass the route of tenant 7 and reach the
backend with both. So the module stamps `AccountID` (and `ProjectID`) on every
route of a list or `all` token too, and vmauth's override leaves one value. The
isolation test `logs-traces` in `tests/tenant-isolation.nix` goes through the real
vmauth, and the render tests (for example
`render-stamps-tenant-routes-per-token-shape`) pin the stamp on each route;
dropping the stamp or the `src_headers` turns them red.

**Syslog.** Each `logs.syslog` slot has `tenant` (a declared name, default null =
0:0), rendered as `-syslog.tenantID.<transport>` ([0031](0031-victorialogs-syslog-listeners.md)).
Syslog bypasses vmauth, so the slot is the only place a device gets its tenant: the
sender cannot choose, and devices of different tenants need their own listener.

**Warn, don't break.** An entry that cannot be honoured loses its access with a
warning naming the entry number (never a token), as in
[0030](0030-vmauth-token-entries-warn-dont-break.md); only a malformed entry
stops the render.

## Why

VictoriaLogs and VictoriaTraces select a tenant with request headers, and vmauth
replaces a header the client sent with the one a route sets. Stamping in the
gateway means the token decides the tenant, not the client or the collector. The
token tiers stay as in [0003](0003-vmauth-two-credential-tiers.md), and the stamped
routes are cut from the closed read allow-list of
[0021](0021-vmauth-read-tier-allow-list.md).

## Consequences

- **Not done (planned stages):**
  - Metrics tenants: single-node VictoriaMetrics has none; they need the cluster
    version. A tenant token reads and writes logs and traces only.
  - Per-tenant MCP: a tenant token gets no MCP route, because the `tenant`
    argument of the logs and traces tools is not bounded by the token
    ([0023](0023-mcp-trust-boundary-extends-grafana.md)).
  - Per-tenant Grafana datasources.
- Changing an `accountId` later orphans the stored data under the old number.
- A tenant host's collector sends logs and traces only (`metrics.enable = false`);
  its tenant is its write token.
