# 0027: vmauth's own pages live on a loopback-only internal listener

## Decision

vmauth is started with `-httpInternalListenAddr=<vmauth.internalListenAddress>`
(default `127.0.0.1:4208`). Per vmauth's own help, once that flag is set it
"no longer serves internal API at -httpListenAddr": `/health`, `/metrics`,
`/flags`, `/debug/pprof/` and `/-/reload` move off every data listener (the
internal 4204 and the public `https`/`http` doors, ADR 0025) onto this one.

```
data listeners   4204 / 8443 / 8080     data routes only, credentials required
internal pages   127.0.0.1:4208         /health /metrics /flags /debug/pprof /-/reload
```

## Why

All of vmauth's listeners share one handler, so before this the public write
doors answered those pages to anyone, with no login: per-user hash labels in
`/metrics`, the startup flags (including the config path), a profiler anyone
could hammer, and a config reload. Nobody needs them on a public port. The
alternative -- generated auth keys (`-metricsAuthKey` and friends) -- adds a
secret to generate, store and read for pages nobody uses; moving the pages
adds nothing to protect.

## Consequences

- The module's own consumers do not use these pages: the readiness probe is a
  TCP check on 4204, self-monitoring pushes from inside the process.
- nginx's `/victoria/metrics` is an ordinary unrouted read path, not vmauth's
  statistics page.
- The internal listener reads the same `-tls`/`-tlsCertFile`/`-tlsKeyFile`
  array slot as the first `-httpListenAddr`, so those arrays are always
  emitted explicitly with a plain first entry (a test pins this).
- Pointing `internalListenAddress` at a non-loopback address exposes the pages
  again; the option text says so.
