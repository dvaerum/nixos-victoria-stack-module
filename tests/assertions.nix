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

  listen-address-collision-between-two-backends-fires = mkAssertionFiresCheck {
    name = "listen-address-collision-between-two-backends-fires";
    expectMessageSubstring = "same listenAddress";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
        logs = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
      };
    };
  };

  listen-address-collision-between-mcp-and-backend-fires = mkAssertionFiresCheck {
    name = "listen-address-collision-between-mcp-and-backend-fires";
    expectMessageSubstring = "same listenAddress";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        listenAddress = "127.0.0.1:9000";
        mcp = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
      };
    };
  };

  # Control: a DISABLED service never binds, so sharing its address with an
  # enabled one is not a collision.
  listen-address-shared-with-a-disabled-service-is-fine = mkNoAssertionsFireCheck {
    name = "listen-address-shared-with-a-disabled-service-is-fine";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
        logs.listenAddress = "127.0.0.1:9000";
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

  # The datasources send a vmauth read token and go through vmauth
  # (docs/decisions/0029); each missing piece must stop the build instead of
  # leaving Grafana with a way to reach a backend directly or no credential.
  grafana-requires-read-token-file = mkAssertionFiresCheck {
    name = "grafana-requires-read-token-file";
    expectMessageSubstring = "grafana.readTokenFile";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        vmauth.readTokensFile = "/run/fake-read-tokens.yaml";
      };
      services.grafana.enable = true;
    };
  };

  grafana-requires-vmauth = mkAssertionFiresCheck {
    name = "grafana-requires-vmauth";
    expectMessageSubstring = "grafana.enable requires vmauth.enable";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        vmauth.enable = lib.mkForce false;
      };
      services.grafana.enable = true;
    };
  };

  grafana-requires-token-in-vmauth-read-tier = mkAssertionFiresCheck {
    name = "grafana-requires-token-in-vmauth-read-tier";
    expectMessageSubstring = "vmauth.readTokensFile";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        # vmauth.readTokensFile deliberately unset: no token Grafana sends
        # could be accepted.
      };
      services.grafana.enable = true;
    };
  };

  # Control: everything wired -- no assertion should fire.
  grafana-with-grafana-service-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "grafana-with-grafana-service-is-not-an-assertion-failure";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        vmauth.readTokensFile = "/run/fake-read-tokens.yaml";
      };
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
