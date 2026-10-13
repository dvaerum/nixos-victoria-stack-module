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
`docs/decisions/0001-victoria-stack-built-from-scratch.md`. Switching an
existing host's `dynamicUser` needs a manual data move:
[runbook](./docs/runbooks/dynamicuser-migration.md).

## Quick start

Everything is opt-in except where there's genuinely nothing to opt out of.
The smallest valid configuration:

```nix
{
  imports = [ victoria-stack-module.nixosModules.default ];
  services.victoriaStack.metrics.enable = true;
}
```

That alone gives you a VictoriaMetrics instance listening on loopback, plus
vmauth, which starts by default whenever a backend is on (also on loopback, with
no users configured). No Grafana, no nginx,
no collector. A fuller,
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
{
  # This module provisions datasources into your Grafana; it does not enable one.
  services.grafana = {
    enable = true;
    settings.security.secret_key = "$__file{/run/secrets/grafana-secret-key}";
  };
  services.victoriaStack = {
    metrics.enable = true;   # datasources are provisioned for the enabled backends
    grafana = {
      enable = true;
      readTokenFile = "/run/secrets/grafana-read-token";  # one bearer token, plain text
    };
    vmauth.readTokensFile = "/run/secrets/vmauth-read-tokens.yaml";
    # ...whose `tokens:` list contains an entry with that same token.
  };
}
```

`grafana.readTokenFile` needs a matching token in `vmauth.readTokensFile`
(this module does not add it), and is required only when at least one backend
is enabled. `grafana.enable` also needs `services.grafana.enable` and
`vmauth.enable` (the default whenever a backend is on). With no backend enabled
the module has nothing to provision and only warns.

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

Collectors then use `writeEndpoint = "https://host:8443"`. The module opens no
firewall port by default; set `https.openFirewall = true` (or `http.openFirewall`)
to open exactly the configured port. See
[`docs/decisions/0025`](./docs/decisions/0025-vmauth-public-write-doors.md).

### Syslog from devices

Devices that can only send syslog (routers, switches, appliances) can write to
VictoriaLogs directly. Nothing listens until you name an address:

```nix
services.victoriaStack.logs.syslog = {
  udp = { enable = true; ipAddress = "192.0.2.10"; };   # port 514
  tcp = { enable = true; ipAddress = "192.0.2.10"; };   # port 514
  tls = {                                               # port 6514
    enable = true;
    ipAddress = "192.0.2.10";
    certFile = "/run/secrets/syslog-cert.pem";
    keyFile = "/run/secrets/syslog-key.pem";
  };
  # Every entry gets `source=syslog` unless you set extraFields.
  # Add openFirewall = true to a slot to open its port; the module opens none by default.
};
```

VictoriaLogs' syslog ingestion has **no authentication** (TLS only encrypts):
anyone who can reach a port can write logs and create streams, so bind a
specific address and restrict who can reach it. Evaluation warns about a
listener on a non-loopback address until you set that slot's
`suppressExposureWarning` (a plain udp or tcp listener lets anyone write logs;
the `tls` slot is encrypted but still unauthenticated, so its warning says so).
Ports below 1024 give the
VictoriaLogs unit `CAP_NET_BIND_SERVICE` and nothing else. Anything beyond the
three slots (unix sockets, tenants, stream fields) goes through `logs.extraFlags`;
see [`docs/decisions/0031`](./docs/decisions/0031-victorialogs-syslog-listeners.md).

### Fleet topology

One gateway host running `victoriaStack`, N other hosts running
`victoriaCollector` with their own `hostType` and write token:
[`examples/fleet.nix`](./examples/fleet.nix) (evaluated by
`tests/collector.nix`, so it stays in sync with the real options).

The file is a function returning `{ gateway; collector; }`, not a module, so
`imports = [ ./fleet.nix ]` fails. Import it first and use its parts as modules:

```nix
let fleet = import ./fleet.nix { }; in
{
  # gateway host
  imports = [ fleet.gateway ];
  # every other host: imports = [ (fleet.collector { hostType = "server"; writeTokenFile = "..."; }) ];
}
```

The gateway sets no read tokens and no admin password, so nobody can query it
until you add `vmauth.readTokensFile` and/or `vmauth.adminPasswordFile`.

## Secrets

Every credential option is a plain file-path (`...File`) option -- this
module has no opinion about how the file got there. Secret `*File` options are
plain strings, never Nix path literals: a path literal is copied into the
world-readable Nix store at build time. Public material, such as the CA bundle
`vmauth.backendTls.caFile`, may be a path (see
[`vmauth.writeTokensFile`](./docs/options.md) for the full rule). It composes cleanly with
sops-nix's own native "one encrypted file, many individually-addressed
secrets" support (`sops.secrets."group/key".path`), or agenix, or anything
else -- see `docs/decisions/0008-agnostic-secrets-file-options.md`.

## Coexisting with your own Alloy / journald-upload config

The collector takes over a few things; everything else on those services stays yours.

- **Alloy** (when `metrics` or `traces` is enabled): sets `services.alloy.enable`,
  `package` (default), `extraFlags` (appends to yours) and `environmentFile` (when
  `writeTokenFile` is set). The generated pipeline is written to
  `environment.etc."alloy/config.alloy".text`, a text option whose definitions are
  concatenated with any text you add there. Block labels must be unique across the
  combined file, so a clash (the same `otelcol.*` or `prometheus.*` label in yours and
  ours) is only caught when Alloy loads the config at run time, not at build time.
- **systemd-journal-upload** (when `logs` is enabled): sets
  `services.journald.upload.enable` and `settings.Upload.URL` (plus the three TLS keys
  for an `https://` endpoint), so your own `Upload.URL` conflicts with it. The write token reaches the uploader through the drop-in
  `/run/systemd/journal-upload.conf.d/50-write-token.conf`, rendered at boot.

## Upgrading / breaking changes

What changed incompatibly, and what to do:

- **Ports renumbered** ([0017](./docs/decisions/0017-port-renumbering.md)):
  services now default to `:4201`-`:4207`. Check firewalls and anything that dialled
  `:8428`/`:9428`/`:10428`/`:8880`, or pin the old ports through each `listenAddress`.
- **Writes no longer go through nginx**
  ([0025](./docs/decisions/0025-vmauth-public-write-doors.md)): point collectors'
  `writeEndpoint` at vmauth's own door (`vmauth.https` or `vmauth.http`).
- **Grafana needs a read token**
  ([0029](./docs/decisions/0029-grafana-datasources-through-vmauth-read-tier.md)):
  set `grafana.readTokenFile` and list the same token in `vmauth.readTokensFile`.
- **Entries that grant no access are skipped**
  ([0030](./docs/decisions/0030-vmauth-token-entries-warn-dont-break.md)):
  `backends: []` now means no access (it used to mean all), and an empty or
  whitespace-only token or admin password creates no user. Read the vmauth journal for the warnings.
- **`vmauth.extraFlags` is shell-escaped**
  ([0028](./docs/decisions/0028-vmauth-extra-flags-are-escaped.md)): one list
  element is one argument; remove any extra quoting you added to work around the
  old splitting.

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
  route. A new datasource must not set `isDefault = true` while the module's
  VictoriaMetrics one is also default: Grafana refuses two defaults, and
  evaluation warns naming both.

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
  security.acme = {  # needed by enableACME
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };
  ```

## License

MIT, see [`LICENSE`](./LICENSE).
