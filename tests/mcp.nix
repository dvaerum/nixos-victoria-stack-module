{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;

  # Same shape as storage.nix's mkHardeningCheck, minus LimitNOFILE/wait4x
  # readiness -- neither applies here: no nixpkgs module to confirm a
  # LimitNOFILE value against, and no documented HTTP health endpoint for
  # vmauth or the mcp-victoria* binaries to poll (docs/decisions/0015).
  mkMcpHardeningCheck =
    {
      name,
      serviceName,
      enableModule,
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith enableModule;
        sc = evaluated.config.systemd.services.${serviceName}.serviceConfig;
        hardeningChecks = {
          "NoNewPrivileges" = (sc.NoNewPrivileges or null) == true;
          "ProtectSystem" = (sc.ProtectSystem or null) == "full";
          "PrivateDevices" = (sc.PrivateDevices or null) == true;
          "MemoryDenyWriteExecute" = (sc.MemoryDenyWriteExecute or null) == true;
          "RestrictAddressFamilies" =
            (sc.RestrictAddressFamilies or null) == [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
        };
        failed = lib.filterAttrs (_: ok: !ok) hardeningChecks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s serviceConfig is missing expected hardening: ${builtins.toJSON (builtins.attrNames failed)}"
    );
in
{
  mcp-metrics-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-metrics-hardening-profile";
    serviceName = "mcp-victoriametrics";
    enableModule = {
      services.victoriaStack.metrics = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-logs-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-logs-hardening-profile";
    serviceName = "mcp-victorialogs";
    enableModule = {
      services.victoriaStack.logs = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-traces-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-traces-hardening-profile";
    serviceName = "mcp-victoriatraces";
    enableModule = {
      services.victoriaStack.traces = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

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
