{ ... }:

# Devices that only speak syslog, one tenant per address. Syslog has no
# authentication and bypasses vmauth, so the listener a packet reaches is the
# only thing that decides its tenant: keep each team's devices on their own
# address (firewall or VLAN) and give that address its own listener.
#
# A module, not a function of a fleet like fleet.nix: import it next to
# nixosModules.victoriaStack. tests/syslog-listeners.nix evaluates it so it
# cannot drift from the option set. docs/decisions/0036.
#
# Addresses are documentation placeholders (RFC 5737); secret file paths are
# placeholders too (docs/decisions/0008).
{
  imports = [ ]; # nixosModules.victoriaStack, wired in by the consuming flake.nix

  services.victoriaStack = {
    logs.enable = true;

    # The number is the permanent key of the stored data.
    tenants = {
      team-a.accountId = 7;
      team-b.accountId = 8;
    };

    logs.syslog.listeners = {
      team-a-udp = {
        transport = "udp";
        ipAddress = "192.0.2.10";
        tenant = "team-a";
      };
      team-a-tcp = {
        transport = "tcp";
        ipAddress = "192.0.2.10";
        port = 1514;
        tenant = "team-a";
      };

      team-b-udp = {
        transport = "udp";
        ipAddress = "192.0.2.11";
        tenant = "team-b";
      };
      team-b-tls = {
        transport = "tls";
        ipAddress = "192.0.2.11";
        tenant = "team-b";
        certFile = "/run/secrets/syslog-team-b.pem";
        keyFile = "/run/secrets/syslog-team-b.key";
      };

      # No tenant: the rows land in tenant 0:0, labelled `source=edge`.
      edge-udp = {
        transport = "udp";
        ipAddress = "192.0.2.12";
        extraFields.source = "edge";
      };
    };

    # Each team reads only its own rows, with a token that names its tenant:
    #
    #   tokens:
    #     - token: <random secret for team-a>
    #       tenant: team-a
    #     - token: <random secret for team-b>
    #       tenant: team-b
    vmauth.readTokensFile = "/run/secrets/victoria/vmauth-read-tokens.yaml";
  };
}
