# 0010: Grafana stays on its own auth, direct loopback, never through vmauth

## Decision

`services.victoriaStack.grafana.enable` only provisions datasources pointing
directly at whichever of metrics/logs/traces is enabled, over loopback, with
no credential. `services.grafana.*` itself (admin password, users, etc.) is
left entirely alone — this module adds no new Grafana auth layer, and never
routes Grafana's own traffic through vmauth.

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
