{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkNoAssertionsFireCheck;

  # Plain test fixtures -- not sops-rendered (this module's own options are
  # secrets-backend-agnostic, see docs/decisions/0008; sops-nix integration
  # is a consumer concern, not something to bring into the test harness).
  writeTokensFixture = pkgs.writeText "write-tokens.yaml" ''
    tokens:
      - write-token-one # collector-host-a
      - write-token-two # collector-host-b
  '';

  readTokensFixture = pkgs.writeText "read-tokens.yaml" ''
    tokens:
      - read-token-one # ai-client-a
  '';

  adminPasswordFixture = pkgs.writeText "admin-password" "admin-password-value";
in
{
  # --- eval-only ---

  vmauth-auto-enables-when-backend-on = mkNoAssertionsFireCheck {
    name = "vmauth-auto-enables-when-backend-on";
    module = {
      services.victoriaStack.metrics.enable = true;
      # vmauth.enable deliberately left unset -- must auto-default to true
      # via mkDefault (docs/decisions/0002), confirmed by combining this
      # with nginx (which asserts vmauth.enable) in valid-configuration-no-assertions
      # already (tests/assertions.nix), so this check instead confirms the
      # auto-enabled value directly.
    };
  };

  # --- container-boot ---

  write-paths-open-when-auth-disabled = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-paths-open-when-auth-disabled";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.requireAuthForWrites = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8880)

      # Open write path -- no credential at all, confirming
      # requireAuthForWrites = false genuinely leaves it unauthenticated.
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:8880/opentelemetry'"
      )
    '';
  };

  write-paths-require-write-token-by-default = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-paths-require-write-token-by-default";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        # requireAuthForWrites left at its true default.
        vmauth.writeTokensFile = writeTokensFixture;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8880)

      # No credential: the write path must now reject the request (default
      # requireAuthForWrites = true).
      machine.fail(
          "curl -sf -X POST --data-binary 'x 1' 'http://127.0.0.1:8880/opentelemetry'"
      )

      # With a valid write-tier bearer token: must succeed.
      machine.succeed(
          "curl -sf -X POST -H 'Authorization: Bearer write-token-one' "
          "--data-binary 'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:8880/opentelemetry'"
      )
    '';
  };

  write_token_cannot_read = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-token-cannot-read";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = writeTokensFixture;
        vmauth.readTokensFile = readTokensFixture;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8880)

      # A write-tier token must NOT grant read access -- the whole point
      # of splitting the two tiers (docs/decisions/0003).
      machine.fail(
          "curl -sf -H 'Authorization: Bearer write-token-one' "
          "'http://127.0.0.1:8880/metrics/api/v1/query?query=up'"
      )

      # A read-tier token must succeed on the same read path.
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "
          "'http://127.0.0.1:8880/metrics/api/v1/query?query=up'"
      )
    '';
  };

  read-path-requires-admin-password-or-token = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-read-path-requires-credential";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.adminPasswordFile = adminPasswordFixture;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8880)

      # No credential at all: must be rejected.
      machine.fail(
          "curl -sf 'http://127.0.0.1:8880/metrics/api/v1/query?query=up'"
      )

      # Basic Auth with the admin password: must succeed.
      machine.succeed(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:8880/metrics/api/v1/query?query=up'"
      )
    '';
  };

  no-op-without-any-backend-enabled = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-no-op-without-backend";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack.vmauth.enable = true;
      # Deliberately no backend enabled at all.
    };

    testScript = ''
      start_all()
      # vmauth.service must simply not exist / not be wanted -- nothing to
      # front, so it shouldn't even try to start (docs/decisions/0002).
      machine.fail("systemctl status vmauth.service")
    '';
  };
}
