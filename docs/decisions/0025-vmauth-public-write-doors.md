# 0025: Collectors write to vmauth's own doors; nginx is reads-only

## Decision

```
reads / UI   people, AI tools --> nginx (:80/:443) --> vmauth (127.0.0.1:4204) --> backends
                                              \--> Grafana
writes       collectors --------------------------> vmauth :8443 (HTTPS)  [vmauth.https]
                            \-----------------------> vmauth :8080 (HTTP)   [vmauth.http]
```

- `vmauth.listenAddress` stays the internal plain listener (default
  `127.0.0.1:4204`).
- `vmauth.https` (`ipAddress`, `port`, `certFile`+`keyFile` or `acmeCertName`)
  and `vmauth.http` (`ipAddress`, `port`) add listeners to the same vmauth
  process. `http` can be `0.0.0.0` (open), `127.0.0.1` (a target for
  `tailscale serve`), or off. Collectors use `https://host:8443`.
- nginx's `/victoria/` proxies reads only (`metrics`, `logs`, `traces`,
  `mcp`, plus `nginx.extraReadPaths`); everything else under it is a 404.
  Writing through it no longer works -- a breaking change.

## Why

- Writes need their own address, port and TLS story; folding them into the
  read front door made a path prefix part of the write URL, which breaks
  `systemd-journal-upload` (it appends its default port after the path).
  The collector now asserts an explicit port whenever its endpoint has a path.
- vmauth runs several listeners with per-listener TLS natively (its
  `-httpListenAddr`/`-tls`/`-tlsCertFile`/`-tlsKeyFile` flags are positional
  arrays), so no extra program is needed.

## Consequences

- All of vmauth's listeners share one routing/auth config, so the public
  doors also accept reads (still behind credentials). Restrict reachability
  with a firewall or Tailscale if that matters.
- vmauth cannot redirect (no routing key or code for it), so there is no
  8080-to-8443 redirect; `http` is either open, loopback, or off.
- The certificate is staged by systemd `LoadCredential=` (a copy): replace
  the files and restart vmauth. For ACME, add `vmauth.service` to the cert's
  `reloadServices` (a warning says so when missing).
- On the write doors vmauth sees each collector's real address directly, so
  nothing like `X-Forwarded-For` handling is needed there. Behind a reverse
  proxy it would not (the setting that fixes that is Enterprise-only): see
  docs/architecture.md, "Client addresses behind a reverse proxy".
