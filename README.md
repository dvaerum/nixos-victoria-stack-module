# nixos-victoria-stack-module

A NixOS module providing a from-scratch VictoriaMetrics/VictoriaLogs/
VictoriaTraces stack with an auth gateway (vmauth), optional Grafana
datasource wiring, optional nginx reverse-proxy, optional MCP servers, and a
separate fleet-wide collector agent (`victoriaCollector`).

See [`PLAN.md`](./PLAN.md) for the full design and task list,
[`docs/decisions/`](./docs/decisions/) for the ADRs behind each real design
decision, and [`docs/architecture.md`](./docs/architecture.md) for the
default network topology (what's reachable from where, out of the box).

**Documentation:** [options](./docs/options.md)

## Why this exists

nixpkgs' own `services.victoriametrics`/`victorialogs`/`victoriatraces`
modules hardcode their storage path and `DynamicUser`, which conflicts with a
pre-mounted dataset (e.g. ZFS) and has no first-class `retentionPeriod` on
`victorialogs` at all. This module builds each service from scratch instead,
with `dataDir` and `dynamicUser` as real, independent options — see
`docs/decisions/0001-victoria-stack-built-from-scratch.md`.

## Quick start

Everything is opt-in except where there's genuinely nothing to opt out of.
The smallest valid configuration:

```nix
{
  imports = [ victoria-stack-module.nixosModules.default ];
  services.victoriaStack.metrics.enable = true;
}
```

That alone gives you a VictoriaMetrics instance listening on loopback with
no auth gateway, no Grafana, nothing else — "just the backend." A fuller,
realistic single-host setup (metrics + logs + traces + vmauth with both
credential tiers + Grafana + nginx + MCP, plus the host collecting its own
data) is in [`examples/default.nix`](./examples/default.nix) — this is the
exact same configuration `tests/full.nix` exercises, so it's always
up to date with what's actually tested.

In your flake:

```nix
{
  inputs.victoria-stack-module.url = "github:dvaerum/nixos-victoria-stack-module";

  outputs = { nixpkgs, victoria-stack-module, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        victoria-stack-module.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Or without flakes, via a plain import of `nixosModule/` (no flake-specific
code in the module itself):

```nix
{
  imports = [
    (fetchTarball "https://github.com/dvaerum/nixos-victoria-stack-module/archive/main.tar.gz" + "/nixosModule")
  ];
}
```

### Just the fleet collector agent

`services.victoriaCollector` is the agent side -- it runs on every host that
ships telemetry to a `victoriaStack` gateway (including, via loopback, the
gateway host itself -- see `examples/default.nix`'s own self-monitoring
section):

```nix
{
  imports = [ victoria-stack-module.nixosModules.victoriaCollector ];
  services.victoriaCollector = {
    metrics.enable = true;
    logs.enable = true;
    writeEndpoint = "https://victoria-stack.example.com:8443";
    writeTokenFile = "/run/secrets/victoria-collector-write-token";
    hostType = "server";
  };
}
```

### Grafana

Grafana's datasources go through vmauth's read tier, so a Grafana Viewer can
read but not write or delete (ADR 0029). Give Grafana its own read token and
list the same token in vmauth's read tokens:

```nix
services.victoriaStack.grafana = {
  enable = true;
  readTokenFile = "/run/secrets/grafana-read-token";  # one bearer token, plain text
};
services.victoriaStack.vmauth.readTokensFile = "/run/secrets/vmauth-read-tokens.yaml";
# ...whose `tokens:` list contains an entry with that same token.
```

`grafana.enable` needs `vmauth.enable` (the default whenever a backend is on).

### Where collectors write

Collectors write to vmauth's own doors, not through nginx (which is reads
and Grafana only):

```nix
services.victoriaStack.vmauth = {
  https = {                       # 0.0.0.0:8443 by default
    enable = true;
    certFile = "/run/secrets/gateway-cert.pem";   # or acmeCertName = "...";
    keyFile = "/run/secrets/gateway-key.pem";
  };
  http.enable = true;             # optional plain door; ipAddress = "127.0.0.1"
                                  # makes it a target for `tailscale serve`
};
```

Collectors then use `writeEndpoint = "https://host:8443"`. See
[`docs/decisions/0025`](./docs/decisions/0025-vmauth-public-write-doors.md).

### Fleet topology

One gateway host running `victoriaStack`, N other hosts running
`victoriaCollector` with their own `hostType` and write token:
[`examples/fleet.nix`](./examples/fleet.nix) (evaluated by
`tests/collector.nix`, so it stays in sync with the real options).

## Secrets

Every credential option is a plain file-path (`...File`) option -- this
module has no opinion about how the file got there. It composes cleanly with
sops-nix's own native "one encrypted file, many individually-addressed
secrets" support (`sops.secrets."group/key".path`), or agenix, or anything
else -- see `docs/decisions/0008-agnostic-secrets-file-options.md`.

## Escape hatches for things this module deliberately doesn't wrap

Three things found useful in practice have no first-class option here on
purpose -- all three are already fully configurable through the generic NixOS
mechanism that already exists for them, so adding a second, narrower
mechanism here would just be a worse version of something you already have:

- **Systemd resource limits** (`MemoryMax`, `CPUQuota`, etc.) for the
  storage services: `systemd.services.<name>.serviceConfig` already does
  this for every NixOS service. The unit names are a stable contract you
  can target directly: `victoriametrics`, `victorialogs`, `victoriatraces`,
  `vmauth`, `mcp-victoriametrics`, `mcp-victorialogs`, `mcp-victoriatraces`.
  For example:

  ```nix
  systemd.services.victoriametrics.serviceConfig.MemoryMax = "4G";
  ```

- **Grafana datasource tuning** (which datasource is `isDefault`, custom
  `jsonData` like TLS skip-verify or scrape intervals) beyond what
  `services.victoriaStack.grafana.enable` auto-provisions:
  `services.grafana.provision.datasources.settings` is a fully generic,
  already-existing NixOS option tree this module's own datasource wiring
  is a plain (non-`mkForce`) definition against. Adding a *new* datasource
  this way merges cleanly; tweaking one of the *three auto-provisioned*
  entries (VictoriaMetrics/VictoriaLogs/VictoriaTraces) needs
  `lib.mkForce` on the whole `datasources` list, since list-typed options
  don't merge per-entry -- reconstruct all three yourself if you go this
  route.

- **nginx TLS/HTTPS** (`services.victoriaStack.nginx.enable = true`):
  this module has no ACME/TLS option of its own -- `nginx`'s own real
  options already do this job well.
  `services.nginx.virtualHosts."victoria-stack"` is a stable,
  intentional extension point (docs/decisions/0022); add HTTPS directly
  on it:

  ```nix
  services.nginx.virtualHosts."victoria-stack" = {
    forceSSL = true;   # or addSSL = true to keep plain HTTP available too
    enableACME = true; # or sslCertificate/sslCertificateKey/useACMEHost
  };
  ```

## License

MIT, see [`LICENSE`](./LICENSE).
