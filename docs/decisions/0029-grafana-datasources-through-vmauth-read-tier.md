# 0029: Grafana's datasources go through vmauth's read tier

Amends [0010](./0010-grafana-direct-loopback-own-auth.md) and
[0023](./0023-mcp-trust-boundary-extends-grafana.md).

## Decision

`services.victoriaStack.grafana.enable` provisions each datasource with the
URL of vmauth's internal data listener (`vmauth.listenAddress`, dialled on
loopback when it is a wildcard address) plus the backend's read prefix:
`/metrics`, `/logs`, `/traces/select/jaeger`. Every datasource sends
`Authorization: Bearer <token>` (`jsonData.httpHeaderName1` plus
`secureJsonData.httpHeaderValue1`, a Grafana datasource feature, not a plugin
one). The token comes from a file the operator provides,
`grafana.readTokenFile`:

- a plain-string path (0008), never a Nix path literal;
- delivered to Grafana's unit with `LoadCredential=`, so the file need not be
  readable by the `grafana` user. An `ExecStartPre=` writes `Bearer <token>`
  to `/run/grafana/vmauth-authorization`, and the provisioning file holds only
  `$__file{/run/grafana/vmauth-authorization}`, so no secret is in the store.
  The header value is one whole `$__file{}` reference because nixpkgs warns
  about any other `secureJsonData` value (its check rejects a `Bearer `
  prefix) although `$__file{}` expands anywhere in the string;
- watched like vmauth's secret files: replacing it try-restarts Grafana, which
  reads it only at start.

The token must also be an entry of `vmauth.readTokensFile`. The module does not
add it there. A mismatch makes vmauth answer 401 to every datasource query:
visible and closed, never open. Adding the entry automatically would need a
third credential source in vmauth's render script and would hide that Grafana
is one more holder of a read credential; the operator-lists design adds no
vmauth code.

Eval-time assertions (only when a backend is enabled, since nothing is
provisioned otherwise): `vmauth.enable`, `grafana.readTokenFile` and
`vmauth.readTokensFile` must all be set. With `vmauth.enable = false` there is
no safe URL to give Grafana, so the combination is rejected instead of falling
back to the raw backends.

## Why

0010 reasoned that a datasource credential stops nobody because Grafana shares a
host with the backends. That holds for same-host code execution; it ignores
Grafana's own users. Grafana's datasource proxy forwards any method and path to
the datasource URL for every user with `datasources:query`, which every Viewer
has, and the VictoriaMetrics plugins ship no route restrictions. Measured
against the real plugins with a Viewer-role user and the old direct URLs:

| request through `/api/datasources/proxy/uid/<ds>/...` | result |
|---|---|
| `POST /api/v1/import/prometheus` | 204, data written |
| `POST /api/v1/admin/tsdb/delete_series?match[]=...` | 204, data deleted |
| `GET /snapshot/create`, `GET /flags` | 200 |
| VictoriaLogs `POST /insert/jsonline` | 200, line written |

This reopened exactly the read-tier to write/delete escalation that 0021 closed
in vmauth. Routing through vmauth's read tier reuses that allow-list: the same
requests now get `400 missing route` from vmauth, and the backends are
unchanged afterwards. Reads keep working through the proxy (series, labels,
LogsQL query).

0023's argument for the MCP servers is not affected: they are not reachable by
any user who can log in somewhere, and vmauth already gates the MCP routes. Only
the Grafana half of its reasoning ("Grafana is inside the backend's trust
boundary") was wrong, because Grafana users are not same-host code.

## Consequences

- The nginx `/grafana/` location is unchanged: it proxies to Grafana, and
  Grafana's own login still decides who may use it. A Grafana login is now read
  access only, as bounded by the read allow-list.
- `grafana.enable` now needs `readTokenFile` and the matching vmauth entry; the
  shipped example sets both. Existing configurations fail evaluation with a
  message naming the missing piece.
- An endpoint a plugin needs that is not on the read allow-list is rejected
  until it is added to 0021's list or to `vmauth.extraReadUrlMap`.
- Anyone who can edit a datasource as a Grafana Editor/Admin can still point it
  elsewhere; provisioned datasources are `editable = false`, but Grafana
  Admin can create new ones. That is Grafana's own trust model.
