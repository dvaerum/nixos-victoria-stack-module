# 0023: MCP's trust boundary extends ADR 0010's reasoning

Status: the Grafana half of this reasoning is superseded by
[0029](./0029-grafana-datasources-through-vmauth-read-tier.md); the MCP
decision stands.

## Decision

The three MCP servers (`mcp-victoriametrics`, `mcp-victorialogs`,
`mcp-victoriatraces`) carry no credential logic of their own. Each talks
straight to its co-located backend over loopback; any authentication
happens in vmauth's `/mcp/*` routing in front of it, or not at all when
`vmauth.enable = false` and the MCP `listenAddress` is left on loopback.

## Why

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

This previously lived only as a code comment in `mcp.nix`; it is an ADR
now because it is a real design decision with the same weight as 0010.
