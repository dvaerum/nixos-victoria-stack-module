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

  # vmauth.enable = true alone is not sufficient: vmauth.nix's own config
  # block only activates when a backend is also enabled, so this
  # configuration previously passed the (pre-Phase-36) assertion while
  # producing no actual vmauth service for nginx to reverse-proxy to.
  nginx-requires-vmauth-with-a-real-backend = mkAssertionFiresCheck {
    name = "nginx-requires-vmauth-with-a-real-backend";
    expectMessageSubstring = "vmauth";
    module = {
      services.victoriaStack = {
        vmauth.enable = true;
        nginx.enable = true;
        # metrics/logs/traces all left at their default (disabled) --
        # vmauth.enable = true here is structurally inert.
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

  backend-tls-cert-requires-key = mkAssertionFiresCheck {
    name = "backend-tls-cert-requires-key";
    expectMessageSubstring = "certFile and .keyFile";
    module = {
      services.victoriaStack.vmauth.backendTls.certFile = "/run/fake-client-cert.pem";
      # keyFile deliberately left unset -- an incomplete mTLS pair.
    };
  };

  backend-tls-key-requires-cert = mkAssertionFiresCheck {
    name = "backend-tls-key-requires-cert";
    expectMessageSubstring = "certFile and .keyFile";
    module = {
      services.victoriaStack.vmauth.backendTls.keyFile = "/run/fake-client-key.pem";
      # certFile deliberately left unset -- an incomplete mTLS pair.
    };
  };

  # Control: both halves of the mTLS pair set together -- no assertion
  # should fire.
  backend-tls-cert-and-key-together-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "backend-tls-cert-and-key-together-is-not-an-assertion-failure";
    module = {
      services.victoriaStack.vmauth.backendTls = {
        certFile = "/run/fake-client-cert.pem";
        keyFile = "/run/fake-client-key.pem";
      };
    };
  };

  # Control: neither half set (the default) -- no assertion should fire.
  backend-tls-neither-cert-nor-key-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "backend-tls-neither-cert-nor-key-is-not-an-assertion-failure";
    module = { };
  };
}
