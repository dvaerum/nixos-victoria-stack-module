# 0006: Alloy's write-token via otelcol.auth.headers + sys.env(), not inline

## Decision

The collector's Alloy pipeline (metrics + traces export via
`otelcol.exporter.otlphttp`) attaches its write-bearer-token through an
`otelcol.auth.headers` component whose `value` is `sys.env("VICTORIA_WRITE_TOKEN")`,
with the real value supplied purely via the systemd unit's own
`EnvironmentFile=` (pointed at a `...File`-style secret path). The token
never appears in the rendered `config.alloy` text at all.

## Why

`environment.etc."alloy/config.alloy".text` (how the collector's config
reaches disk, confirmed from the existing implementation) is, like
journal-upload's config, always a Nix-store path. Embedding a real secret in
that text would leak it the same way. Alloy's own `otelcol.auth.headers`
component accepts a `value` of type `string` *or* `secret`, and its own
official documentation's Grafana Cloud example demonstrates exactly this
pattern (`sys.env("OTLP_API_KEY")` for `otelcol.auth.basic`) — a native,
upstream-documented mechanism, not something invented for this project.
`EnvironmentFile=` is itself an ordinary, secrets-backend-agnostic systemd
primitive (sops-nix's `sops.templates.*.path` is designed to be pointed at by
exactly this).
