# 0006: Alloy's write-token via otelcol.auth.bearer + sys.env(), not inline

## Decision

The collector's Alloy pipeline (metrics + traces export via
`otelcol.exporter.otlphttp`) attaches its write-bearer-token through an
`otelcol.auth.bearer` component whose `token` is `sys.env("VICTORIA_WRITE_TOKEN")`,
with the real value supplied purely via the systemd unit's own
`EnvironmentFile=` (pointed at a `...File`-style secret path). The token
never appears in the rendered `config.alloy` text at all.

## Why

`environment.etc."alloy/config.alloy".text` (how the collector's config
reaches disk, confirmed from the existing implementation) is, like
journal-upload's config, always a Nix-store path. Embedding a real secret in
that text would leak it the same way. Alloy's `otelcol.auth.bearer`
component's `token` is a `secret`, and Alloy's own
official documentation's Grafana Cloud example demonstrates exactly this
pattern (`sys.env("OTLP_API_KEY")` for `otelcol.auth.basic`) — a native,
upstream-documented mechanism, not something invented for this project.
`EnvironmentFile=` is itself an ordinary, secrets-backend-agnostic systemd
primitive (sops-nix's `sops.templates.*.path` is designed to be pointed at by
exactly this).

`otelcol.auth.headers` was used first and dropped: its `value` is a plain
string, so the Alloy web UI printed `Bearer <token>` to any local user. A
secret is shown as `(secret)`.
