{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkAssertionFiresCheck mkNoAssertionsFireCheck;

  # Same throwaway fixture tests/grafana.nix uses -- nixpkgs' grafana
  # module requires a real secret_key file-provider, no silent default.
  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";
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

  # The logs/traces copies of the same assertion
  # (nixosModule/victoriaStack/assertions.nix) had zero coverage -- only
  # the metrics variant was ever tested, even though all 3 are
  # structurally identical (copy-pasted) per-service assertions.
  logs-mcp-requires-own-backend = mkAssertionFiresCheck {
    name = "logs-mcp-requires-own-backend";
    expectMessageSubstring = "mcp";
    module = {
      services.victoriaStack.logs = {
        enable = false;
        mcp.enable = true;
      };
    };
  };

  traces-mcp-requires-own-backend = mkAssertionFiresCheck {
    name = "traces-mcp-requires-own-backend";
    expectMessageSubstring = "mcp";
    module = {
      services.victoriaStack.traces = {
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

  grafana-requires-grafana-service = mkAssertionFiresCheck {
    name = "grafana-requires-grafana-service";
    expectMessageSubstring = "services.grafana.enable";
    module = {
      services.victoriaStack.grafana.enable = true;
      # services.grafana.enable deliberately left at its default (false)
      # -- this module only provisions datasources, never enables Grafana
      # itself (docs/decisions/0010).
    };
  };

  # Control: victoriaStack.grafana.enable with services.grafana.enable
  # both on -- no assertion should fire.
  grafana-with-grafana-service-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "grafana-with-grafana-service-is-not-an-assertion-failure";
    module = {
      services.victoriaStack.grafana.enable = true;
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };
  };
}
