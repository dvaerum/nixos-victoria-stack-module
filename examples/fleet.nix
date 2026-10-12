{ ... }:

# A fleet topology: one gateway host running the whole victoriaStack, and
# any number of other hosts running just the collector agent and shipping
# telemetry to it over the network. Contrast with examples/default.nix,
# where one host is both (collecting its own data over loopback).
#
# This file is a function returning { gateway; collector; }, not a module:
# `imports = [ ./fleet.nix ]` fails. Call it (`import ./fleet.nix { }`), then
# import `gateway` on the stack host and `collector { ... }` on every other
# host. Both are plain NixOS modules, not a nixosTest -- tests/collector.nix
# is where the fleet is exercised for real (and evaluates this file, so it
# can't drift).
#
# The gateway sets no read tokens and no admin password, so nobody can query
# it until you add vmauth.readTokensFile and/or vmauth.adminPasswordFile.
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
          # Collectors write to vmauth's own public HTTPS door
          # (docs/decisions/0025). Its internal listener (127.0.0.1:4204)
          # stays loopback-only for nginx and local callers.
          https = {
            enable = true; # 0.0.0.0:8443 by default
            openFirewall = true;
            certFile = "/run/secrets/victoria/gateway-cert.pem";
            keyFile = "/run/secrets/victoria/gateway-key.pem";
            # Or reuse an ACME certificate NixOS already manages:
            # acmeCertName = "victoria-gateway.example.internal";
          };

          # One bearer token per collector host (a YAML `tokens:` list), so
          # one host's token can be revoked without touching the others.
          writeTokensFile = "/run/secrets/victoria/collector-write-tokens.yaml";
        };
      };
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

        # The gateway's HTTPS write door: host and port, no path.
        writeEndpoint = "https://victoria-gateway.example.internal:8443";

        inherit hostType writeTokenFile;
      };
    };
}
