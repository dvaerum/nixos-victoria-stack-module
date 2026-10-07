{ ... }:

# A fleet topology: one gateway host running the whole victoriaStack, and
# any number of other hosts running just the collector agent and shipping
# telemetry to it over the network. Contrast with examples/default.nix,
# where one host is both (collecting its own data over loopback).
#
# Returns two plain NixOS modules, not a nixosTest -- tests/collector.nix
# is where the fleet is exercised for real (and evaluates this file, so it
# can't drift). Import `gateway` on the stack host and
# `collector { ... }` on every other host.
#
# Secret file paths are placeholders; docs/decisions/0008 -- this module
# doesn't care how they get there.
{
  gateway =
    { ... }:
    {
      imports = [ ]; # nixosModules.victoriaStack, wired in by the consuming flake.nix

      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;

        vmauth = {
          # Collectors are remote, so vmauth must listen on a reachable
          # address -- its loopback default is a deliberate security
          # default (docs/architecture.md), and nothing here changes it
          # silently.
          listenAddress = "0.0.0.0:4204";

          # One bearer token per collector host (a YAML `tokens:` list), so
          # one host's token can be revoked without touching the others.
          writeTokensFile = "/run/secrets/victoria/collector-write-tokens.yaml";
        };
      };

      # This module never opens firewall ports itself (infrastructure-
      # agnostic); the gateway's operator does.
      networking.firewall.allowedTCPPorts = [ 4204 ];
    };

  # One call per fleet host: its own label and its own token file.
  collector =
    {
      hostType,
      writeTokenFile,
    }:
    { ... }:
    {
      imports = [ ]; # nixosModules.victoriaCollector, wired in by the consuming flake.nix

      services.victoriaCollector = {
        metrics.enable = true;
        logs.enable = true;

        # The gateway's real network address, not loopback. For HTTPS put
        # nginx in front of the gateway (docs/decisions/0022) and use an
        # https:// endpoint with an explicit port.
        writeEndpoint = "http://victoria-gateway.example.internal:4204";

        inherit hostType writeTokenFile;
      };
    };
}
