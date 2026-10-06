# nixos-victoria-stack-module

A NixOS module providing a from-scratch VictoriaMetrics/VictoriaLogs/
VictoriaTraces stack with an auth gateway (vmauth), optional Grafana
datasource wiring, optional nginx reverse-proxy, optional MCP servers, and a
separate fleet-wide collector agent (`victoriaCollector`).

See [`PLAN.md`](./PLAN.md) for the full design and task list, and
[`docs/decisions/`](./docs/decisions/) for the ADRs behind each real design
decision.

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

## Secrets

Every credential option is a plain file-path (`...File`) option -- this
module has no opinion about how the file got there. It composes cleanly with
sops-nix's own native "one encrypted file, many individually-addressed
secrets" support (`sops.secrets."group/key".path`), or agenix, or anything
else -- see `docs/decisions/0008-agnostic-secrets-file-options.md`.

## License

MIT, see [`LICENSE`](./LICENSE).
