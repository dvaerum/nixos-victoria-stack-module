{ ... }:

# A fleet whose hosts belong to different tenants (examples/fleet.nix is the
# single-tenant version). A collector host's tenant is simply the write token
# it uses: the gateway's write token entry for that host carries `tenant:
# <name>`, and vmauth stamps that tenant on everything the host ships. The
# collector needs no tenant option of its own.
#
# Like fleet.nix this is a function returning { gateway; collector; }, not a
# module. tests/collector.nix evaluates it and runs the two-collector
# end-to-end case (victoria-collector-tenant-write-token-lands-logs-in-that-tenant).
#
# Secret file paths are placeholders; docs/decisions/0008.
{
  gateway =
    { ... }:
    {
      imports = [ ]; # nixosModules.victoriaStack, wired in by the consuming flake.nix

      services.victoriaStack = {
        logs.enable = true;
        traces.enable = true;

        # The number is the permanent key of the stored data: changing it
        # later orphans what was written under the old one.
        tenants = {
          acme.accountId = 1;
          globex.accountId = 2;
        };

        vmauth = {
          https = {
            enable = true;
            openFirewall = true;
            certFile = "/run/secrets/victoria/gateway-cert.pem";
            keyFile = "/run/secrets/victoria/gateway-key.pem";
          };

          # One token per collector host. The file is YAML (put it in your
          # secrets store, not here):
          #
          #   tokens:
          #     - token: <random secret for acme-web-01>
          #       tenant: acme
          #     - token: <random secret for globex-db-01>
          #       tenant: globex
          #
          # A write entry may only carry `tenant:` (one name); an entry
          # without it writes to the default tenant 0:0.
          writeTokensFile = "/run/secrets/victoria/collector-write-tokens.yaml";

          # Reading a tenant's data takes a read token with the same
          # `tenant:` key.
          readTokensFile = "/run/secrets/victoria/vmauth-read-tokens.yaml";
        };
      };
    };

  # One call per fleet host: its label, the token the gateway maps to that
  # host's tenant, and whether it also ships traces.
  collector =
    {
      hostType,
      writeTokenFile,
      traces ? false,
    }:
    { ... }:
    {
      imports = [ ]; # nixosModules.victoriaCollector, wired in by the consuming flake.nix

      services.victoriaCollector = {
        logs.enable = true;
        traces.enable = traces;

        # A tenant write token carries metrics into the tenant too; this
        # example ships logs and traces only.
        metrics.enable = false;

        writeEndpoint = "https://victoria-gateway.example.internal:8443";

        inherit hostType writeTokenFile;
      };
    };
}
