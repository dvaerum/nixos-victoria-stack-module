{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkAssertionFiresCheck mkNoAssertionsFireCheck;
in
{
  nginx-requires-vmauth = mkAssertionFiresCheck {
    name = "nginx-requires-vmauth";
    expectMessageSubstring = "vmauth";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        # Forced off: vmauth would otherwise auto-enable (mkDefault true)
        # whenever a backend is on, which is exactly the case this
        # assertion needs to NOT be satisfied by auto-enable alone.
        vmauth.enable = lib.mkForce false;
        nginx.enable = true;
      };
    };
  };

  mcp-requires-own-backend = mkAssertionFiresCheck {
    name = "mcp-requires-own-backend";
    expectMessageSubstring = "mcp";
    module = {
      services.victoriaStack.metrics = {
        enable = false;
        mcp.enable = true;
      };
    };
  };

  # Control: nginx + vmauth both on, mcp + its own backend both on -- no
  # assertion should fire.
  valid-configuration-no-assertions = mkNoAssertionsFireCheck {
    name = "valid-configuration-no-assertions";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        vmauth.enable = true;
        nginx.enable = true;
      };
    };
  };

  # Control: mcp.enable = true with vmauth.enable = false while the mcp's
  # own backend IS enabled -- this is a legitimate, deliberately
  # NOT-asserted-against configuration (see docs/decisions/0002), so it
  # must NOT trip the mcp-requires-own-backend assertion (only the
  # mcp-requires-own-backend one, scoped to the metrics.enable=false case
  # above, should ever fire for mcp).
  mcp-without-vmauth-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "mcp-without-vmauth-is-not-an-assertion-failure";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        mcp.enable = true;
      };
      services.victoriaStack.vmauth.enable = lib.mkForce false;
    };
  };
}
