# 0010: Grafana stays on its own auth, direct loopback, never through vmauth

## Decision

`services.victoriaStack.grafana.enable` only provisions datasources pointing
directly at whichever of metrics/logs/traces is enabled, over loopback, with
no credential. `services.grafana.*` itself (admin password, users, etc.) is
left alone apart from one default: `server.root_url` for the `/grafana/`
sub-path when nginx fronts it (`lib.mkDefault`, so the consumer's value wins).
This module adds no new Grafana auth layer, and never routes Grafana's own
traffic through vmauth.

## Why

vmauth's entire purpose is gating *remote/cross-host* access — fleet
collectors, AI/MCP callers, anything reachable via nginx. Grafana in this
module's design always runs on the *same host* as the backends it reads from
— the identical trust boundary as the backend process itself. A credential
whose only job is "let the thing next to me on the same filesystem read my
data" is a secret to generate, store, and rotate that stops nobody: anyone
with same-host code-execution could already read the credential file
directly. `deployment-a` — confirmed to be the more mature, bug-fixed of the
two real deployments this module generalizes from — already makes this exact
call (direct loopback, no vmauth hop for Grafana's datasources).

## Consequence

Grafana's datasources carry no credential, so anyone who can log in to Grafana
reads every enabled backend regardless of any vmauth token scoping (ADR 0021).
Grafana's own users and roles are the only gate; treat a Grafana login as full
read access to metrics, logs and traces.
