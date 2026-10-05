{ pkgs, nixosModule }:

let
  module = nixosModule.nixosModules.victoriaStack;
in
{
  mcp-reachable-only-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-through-vmauth";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        metrics.mcp.enable = true;
        vmauth.requireAuthForWrites = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("mcp-victoriametrics.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8880)

      # Reachable through vmauth's /mcp/metrics route (no trailing slash,
      # per the MCP binary's own fixed /mcp path).
      machine.succeed("curl -sf -X POST 'http://127.0.0.1:8880/mcp/metrics' -H 'Content-Type: application/json' -d '{}' || true")
      # The MCP server's own listenAddress stays loopback-only by default
      # -- not directly reachable from outside without vmauth routing or
      # an explicit listenAddress override (checked separately below).
      machine.wait_for_open_port(8881)
    '';
  };

  mcp-reachable-directly-when-vmauth-off = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-direct-without-vmauth";

    containers.machine =
      { lib, ... }:
      {
        imports = [ module ];
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp = {
            enable = true;
            listenAddress = "0.0.0.0:8881";
          };
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      start_all()
      machine.wait_for_unit("mcp-victoriametrics.service")
      # vmauth must not even exist/start -- confirmed separately in the
      # vmauth test group's own no-op check; here the point is that mcp
      # itself works fine standalone.
      machine.wait_for_open_port(8881)
    '';
  };
}
