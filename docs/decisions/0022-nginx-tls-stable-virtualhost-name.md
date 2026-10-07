# 0022: nginx TLS is an operator concern against a stable virtualHost name

## Status

Still true for nginx. vmauth's own public HTTPS door ([0025](./0025-vmauth-public-write-doors.md))
is a separate, deliberate exception: it takes a cert/key (or an existing
ACME cert name) because collectors' writes bypass nginx entirely.

## Decision

This module adds no TLS/ACME option of its own for the `nginx` reverse
proxy (`nginxCfg.enable`'s `virtualHosts."victoria-stack"`). Instead, the
virtualHost name `"victoria-stack"` is now a **stable, documented,
intentional public extension point**: an operator who wants HTTPS
configures NixOS's own real nginx/ACME options directly on that same
name --

```nix
services.nginx.virtualHosts."victoria-stack" = {
  forceSSL = true;   # or addSSL = true for both plain HTTP and HTTPS
  enableACME = true; # or sslCertificate/sslCertificateKey/useACMEHost
};
```

NixOS's module system merges that operator-supplied config with
everything this module itself defines on the same attribute name --
same philosophy as ADR 0010's Grafana integration (this module
provisions *into* an already-configured Grafana, it never calls
`services.grafana.enable` itself). Renaming `"victoria-stack"` in a
future version is a breaking change for any such operator config, the
same severity as renaming an option.

## Why

`options.nix` already states this module "deliberately has no ACME/TLS
opinion" -- confirmed true, this module has zero server-side HTTPS
termination anywhere. The two real deployments this project generalizes
from both confirm this is the right boundary, not a gap:

- One deployment serves plain HTTP directly (no TLS at all, trusted
  network boundary).
- The other sits behind Tailscale, which terminates TLS in front of it;
  nginx itself still only ever speaks plain HTTP.

Neither deployment needed this module to have its own TLS option. But
before this ADR, an operator who *did* want nginx-terminated TLS had no
clearly-documented path to add it -- the virtualHost name was an
undocumented implementation detail, not a contract. A consumer
patching it in via `lib.mkForce` or guessing at the generated name was
the only option, with no guarantee the name wouldn't change in a future
version. NixOS's real nginx module already has first-class, widely
understood options for this exact job (`forceSSL`/`addSSL`,
`enableACME`, `sslCertificate`/`sslCertificateKey`, `useACMEHost`) --
building a parallel, narrower option surface in this module would be
reinventing something NixOS already does well, the opposite of this
project's stated preference for declarative composition over bespoke
wrappers.

## Test coverage

`tests/nginx.nix`'s `virtual-host-name-is-the-stable-victoria-stack-key`
pins the literal attribute name via eval, so a future accidental rename
is caught immediately. `nginx-http-and-https-coexist-on-the-stable-name`
is a real container-boot test: a throwaway self-signed certificate
(mirroring `victoriaCollector/config.nix`'s existing `dummyClientCert`
pattern) layered onto `virtualHosts."victoria-stack"` via `addSSL`,
operator-style, exactly as the snippet above shows -- both
`curl http://127.0.0.1:80/victoria/...` and
`curl --cacert <fixture> https://127.0.0.1:443/victoria/...` succeed
against the same backend, proving the composition genuinely works end
to end, not just that it evaluates.
