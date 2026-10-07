{ ... }:

# A complete, realistic single-host configuration -- metrics + logs +
# traces + vmauth (both credential tiers) + Grafana + nginx + MCP, plus
# the host collecting its own data (self-monitoring, matching
# deployment-a's real pattern: the same host that runs the stack also
# runs victoriaCollector against its own vmauth gateway over loopback).
#
# Secret file paths below are placeholders -- replace with wherever your
# own secrets mechanism (sops-nix, agenix, a manually-placed file, this
# module doesn't care -- docs/decisions/0008) actually puts them. This is
# also literally the config tests/full.nix exercises (one source of
# truth, not a docs example that quietly drifts from what's tested) --
# that test just overrides these placeholder paths with its own throwaway
# fixtures.
{
  imports = [ ]; # nixosModules.default (both victoriaStack + victoriaCollector) -- the consuming flake.nix wires this in

  services.victoriaStack = {
    metrics = {
      enable = true;
      mcp.enable = true;
      retentionPeriod = "30d";
    };
    logs = {
      enable = true;
      mcp.enable = true;
    };
    traces = {
      enable = true;
      mcp.enable = true;
      retentionPeriod = "30d";
    };

    vmauth = {
      # enable = true; -- auto-enabled (mkDefault) since a backend is on.
      adminPasswordFile = "/run/secrets/victoria/vmauth-admin-password";
      readTokensFile = "/run/secrets/victoria/vmauth-read-tokens.yaml";
      writeTokensFile = "/run/secrets/victoria/vmauth-write-tokens.yaml";
    };

    grafana.enable = true;

    nginx = {
      enable = true;
      # domain = "victoria-stack.example.com"; -- optional, left unset
      # here (plain IP/hostname); this module has no ACME/TLS opinion
      # either way (docs/decisions/0022-nginx-tls-stable-virtualhost-name.md).
    };
  };

  services.grafana = {
    enable = true;
    settings.security.secret_key = "$__file{/run/secrets/victoria/grafana-secret-key}";
    settings.security.admin_password = "$__file{/run/secrets/victoria/grafana-admin-password}";
  };

  # Self-monitoring: this host collects its own metrics/logs/traces the
  # same way every other fleet host would, just over loopback to its own
  # vmauth instead of a remote one.
  services.victoriaCollector = {
    metrics.enable = true;
    logs.enable = true;
    traces.enable = true;
    writeEndpoint = "http://127.0.0.1:4204"; # vmauth's default port, docs/decisions/0017
    writeTokenFile = "/run/secrets/victoria/collector-write-token";
    hostType = "server";
  };
}
