# 0023: MCP's trust boundary extends ADR 0010's reasoning

Status: the Grafana half of this reasoning is superseded by
[0029](./0029-grafana-datasources-through-vmauth-read-tier.md). For the
metrics and logs MCP servers the "talk straight to the backend" half is
superseded by the section "MCP servers call vmauth's read tier" below; the
traces server still follows the original decision.

## Decision

The three MCP servers (`mcp-victoriametrics`, `mcp-victorialogs`,
`mcp-victoriatraces`) carry no credential of their own and hold no secret.
Any authentication happens in vmauth's `/mcp/*` routing in front of them.

A non-loopback `mcp.listenAddress` bypasses that routing, so it warns at
evaluation (`mcp.suppressExposureWarning` silences it, as for the syslog
listeners, [0031](./0031-victorialogs-syslog-listeners.md)). A port below
1024 is an assertion: the MCP unit has no `CAP_NET_BIND_SERVICE` and would
crash-loop.

## MCP servers call vmauth's read tier (metrics and logs)

The metrics and logs MCP servers do not call their backend. Each runs with
`MCP_PASSTHROUGH_HEADERS=Authorization` and an entrypoint of
`http://<vmauth data listener>/metrics` or `/logs`, so every tool call
reaches vmauth's read tier carrying the CALLER's own token (vmauth's
`/mcp/*` routes keep that header; every other module-built route strips it).
vmauth stays the single authority: the token tier, the backend scope of a
`backends = [...]` token, and the closed endpoint allow-list of
[0021](./0021-vmauth-read-tier-allow-list.md) all apply to what a tool can
reach, and tool arguments cannot steer a request outside that list (a `..`
or percent-encoded name is no allow-listed path: vmauth answers `400 missing
route`).

Consequences:

- `metrics.mcp.enable` and `logs.mcp.enable` require `vmauth.enable` (an
  assertion). The traces MCP server does not, yet.
- The MCP unit orders itself after `vmauth.service` (no `Wants=`: that would
  let an MCP restart cut short vmauth's own restart backoff); vmauth does
  not list these two units in its own `after` (that would be an ordering
  cycle). The MCP binaries do not contact the backend at start.
- Tools whose endpoint is off the read allow-list (`alerts`, `rules`,
  `prettify_query`, `metric_statistics`, a lifted `flags`, ...) fail with
  vmauth's `400 missing route`. Accepted: the read tier is the boundary.
- A request sent straight to the MCP listener without a valid token reaches
  vmauth with no usable credential and fails with its 401 on the tool call.
- The traces MCP binary has no header passthrough yet, so it still talks to
  its backend over loopback, outside the allow-list; the default-disabled
  tools below still matter for it and for nothing else.

## Why (the original reasoning, still the basis for traces)

Same reasoning as [0010](./0010-grafana-direct-loopback-own-auth.md): a
credential whose only job is letting a process on the same host reach a
backend on the same host stops nobody -- anyone with same-host code
execution could read the credential file directly. The MCP servers are
tightly coupled to one co-located backend by construction (the
`mcp.enable -> <service>.enable` assertion, [0002](./0002-opt-in-everything.md)),
so they sit inside the backend's own trust boundary. Anything crossing
the host boundary (an AI client, a remote caller) is gated by vmauth's
credential tiers ([0003](./0003-vmauth-two-credential-tiers.md)), exactly
as for the raw read API.

## Tools disabled by default

Every tool is read-only (`readOnlyHint`), so there is no write path. The
module disables, by default, the tools that go beyond the read allow-list or
show other users' query text (tool names verified by listing the pinned
binaries' tools over MCP JSON-RPC):

| Server | Disabled by default | Why |
| --- | --- | --- |
| logs | `flags` | reads `/flags`, outside `/logs/select/*` |
| metrics | `active_queries`, `top_queries` | other users' query text |
| metrics | `tsdb_status` | reads `/api/v1/status/tsdb`, not on the allow-list |
| traces | none | every tool calls `/select/*` |

mcp-victoriametrics' own defaults (`export`, `flags`, debug tools,
`test_rules`) stay off as before. Left on deliberately: `alerts`/`rules`,
`metric_statistics` and `metrics_metadata` (the first three are off the read
allow-list and answer with vmauth's 400). An operator who wants a disabled
tool back sets `mcp.enabledTools` (for example `[ "flags" ]` on logs); only
these module defaults can be lifted.

The logs and traces tools take a `tenant` argument. It selects the
tenant (`AccountID:ProjectID`) on the same `/select/*` endpoints the read
tier already allows, so it widens nothing; all data is tenant `0:0` today.
The logs MCP binary rejects a `tenant` that is not `<number>:<number>`
before sending anything.

A separate MCP credential tier is not part of this decision.
