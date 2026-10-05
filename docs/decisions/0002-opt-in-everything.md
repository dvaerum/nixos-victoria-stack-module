# 0002: Opt-in everything, with two assertions

## Decision

Every feature layer (`vmauth`, `grafana`, `nginx`, each service's `mcp`) is
independently toggleable. `services.victoriaStack.metrics.enable = true;`
alone is a complete, valid configuration. Two exceptions are enforced as hard
eval-time assertions, not warnings:

- `nginx.enable -> vmauth.enable` (nginx only ever reverse-proxies to
  vmauth, never directly to a raw backend port — there is no legitimate
  nginx-without-vmauth configuration, since nginx has nothing else to point
  at).
- `<service>.mcp.enable -> <service>.enable` (an MCP server proxies to one
  specific backend instance by construction; if that backend is off there is
  nothing to connect to, not a legitimate "I'll wire it up myself" case).

`vmauth.enable = false` with a backend on, and `<service>.mcp.enable = true`
with `vmauth.enable = false`, are both deliberately NOT assertions — both are
legitimate, informed trade-offs (trusting a network boundary instead of a
credential; exposing an MCP server directly via its own `listenAddress`
instead of through vmauth) that real deployments already make today.

## Why

The distinction is "is there anything to connect to" vs. "is this the only
way I'm allowed to reach it". The first is a hard requirement of how the
software works; the second is a security posture choice that belongs to the
operator, not the module.
