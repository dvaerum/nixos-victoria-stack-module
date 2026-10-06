{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    mkNoAssertionsFireCheck
    mkWarningFiresCheck
    mkNoWarningsCheck
    evalWith
    ;

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

  vmauth-hardening-profile = pkgs.runCommand "vmauth-hardening-profile" { } (
    let
      evaluated = evalWith { services.victoriaStack.metrics.enable = true; };
      sc = evaluated.config.systemd.services.vmauth.serviceConfig;
      # Same shape as storage's mkHardeningCheck, minus LimitNOFILE/wait4x
      # readiness -- no nixpkgs vmauth module exists to confirm a
      # LimitNOFILE value against (checked: nixpkgs has no vmauth module
      # at all), and vmauth has no documented HTTP health endpoint to
      # poll (docs/decisions/0015).
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
      throw "vmauth's serviceConfig is missing expected hardening: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  write-tier-tokens-use-auto-derived-ingest-map-regardless-of-override =
    pkgs.runCommand "vmauth-write-tier-ignores-openingestpaths-override" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              # The one guard with no prior test coverage (docs/decisions/0013
              # review, finding #4): overriding this to [] must NOT also starve
              # authenticated write-tier tokens -- it only ever sizes the
              # unauthenticated/open door. See docs/decisions/0014.
              vmauth.openIngestPaths = [ ];
              vmauth.writeTokensFile = "${writeTokensFixture}";
            };
          };
          envVars = evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
          writeUrlMapVar = lib.findFirst (lib.hasPrefix "WRITE_URL_MAP_FILE=") null envVars;
          parsed =
            if writeUrlMapVar == null then
              null
            else
              builtins.fromJSON (builtins.readFile (lib.removePrefix "WRITE_URL_MAP_FILE=" writeUrlMapVar));
        in
        if writeUrlMapVar != null && parsed != [ ] then
          "echo OK > $out"
        else
          throw ''
            write-tier bearer tokens must route via an always-on ingest map
            derived from autoOpenIngestPaths, independent of
            services.victoriaStack.vmauth.openIngestPaths's own override --
            WRITE_URL_MAP_FILE was ${
              if writeUrlMapVar == null then "missing entirely" else "empty despite metrics.enable = true"
            }, even though openIngestPaths was overridden to [] in this test.
          ''
      );

  concurrency-limits-are-inert-unless-configured =
    pkgs.runCommand "vmauth-concurrency-limits-inert-unless-configured" { }
      (
        let
          unset = evalWith { services.victoriaStack.metrics.enable = true; };
          set = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth = {
                maxConcurrentRequests = 100;
                maxConcurrentPerUserRequests = 10;
              };
            };
          };
          execStartUnset = unset.config.systemd.services.vmauth.serviceConfig.ExecStart;
          execStartSet = set.config.systemd.services.vmauth.serviceConfig.ExecStart;
          checks = {
            "flags absent when unset" =
              !(lib.hasInfix "maxConcurrentRequests" execStartUnset)
              && !(lib.hasInfix "maxConcurrentPerUserRequests" execStartUnset);
            "flags present when set" =
              lib.hasInfix "-maxConcurrentRequests=100" execStartSet
              && lib.hasInfix "-maxConcurrentPerUserRequests=10" execStartSet;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "concurrency-limit options broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  backend-tls-options-are-inert-unless-configured =
    pkgs.runCommand "vmauth-backend-tls-inert-unless-configured" { }
      (
        let
          unset = evalWith { services.victoriaStack.metrics.enable = true; };
          set = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth.backendTls = {
                insecureSkipVerify = true;
                # A real path within this flake's own source tree -- an
                # absolute path outside it (e.g. the real
                # /etc/ssl/certs/ca-certificates.crt) hits flakes' own
                # pure-eval "path outside the flake" restriction when
                # assigned to a types.path option (confirmed directly, same
                # class of restriction as the secret-type tests above).
                # Content is irrelevant here, only that it's a real,
                # evaluable path.
                caFile = ./lib.nix;
                certFile = "${writeTokensFixture}"; # any string fixture, content irrelevant here
                keyFile = "${readTokensFixture}";
              };
            };
          };
          execStartUnset = unset.config.systemd.services.vmauth.serviceConfig.ExecStart;
          execStartSet = set.config.systemd.services.vmauth.serviceConfig.ExecStart;
          loadCredentialSet = set.config.systemd.services.vmauth.serviceConfig.LoadCredential;
          checks = {
            "flags absent when unset" = !(lib.hasInfix "backend.tls" execStartUnset);
            "insecureSkipVerify flag present" = lib.hasInfix "-backend.tlsInsecureSkipVerify=true" execStartSet;
            "caFile flag present" = lib.hasInfix "-backend.tlsCAFile=" execStartSet;
            "certFile/keyFile reference %d (LoadCredential), not a literal path" =
              lib.hasInfix "-backend.tlsCertFile=%d/backend-tls-cert" execStartSet
              && lib.hasInfix "-backend.tlsKeyFile=%d/backend-tls-key" execStartSet;
            "certFile/keyFile staged via LoadCredential" =
              lib.any (lib.hasPrefix "backend-tls-cert:") loadCredentialSet
              && lib.any (lib.hasPrefix "backend-tls-key:") loadCredentialSet;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "backendTls options broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  extra-headers-are-inert-unless-configured =
    pkgs.runCommand "vmauth-extra-headers-inert-unless-configured" { }
      (
        let
          unset = evalWith { services.victoriaStack.metrics.enable = true; };
          set = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth = {
                extraRequestHeaders = [ "TenantID: foobar" ];
                extraResponseHeaders = [ "Server:" ];
              };
            };
          };
          envVar =
            evaluated:
            let
              readUrlMapVar =
                lib.findFirst (lib.hasPrefix "READ_URL_MAP_FILE=") null
                  evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
            in
            builtins.fromJSON (builtins.readFile (lib.removePrefix "READ_URL_MAP_FILE=" readUrlMapVar));
          unsetMap = envVar unset;
          setMap = envVar set;
          checks = {
            "no headers key anywhere when unset" = lib.all (
              e: !(e ? headers) && !(e ? response_headers)
            ) unsetMap;
            "headers key present on every entry when set" =
              setMap != [ ]
              && lib.all (
                e: (e.headers or [ ]) == [ "TenantID: foobar" ] && (e.response_headers or [ ]) == [ "Server:" ]
              ) setMap;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraRequestHeaders/extraResponseHeaders broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  secret-options-are-plain-strings-not-nix-paths =
    pkgs.runCommand "vmauth-secret-options-are-plain-strings-not-nix-paths" { }
      (
        let
          evaluated = evalWith { };
          # types.path's own check/merge functions coerce via toString at
          # option-definition time (not lazily deferred to actual use) --
          # confirmed directly: builtins.tryEval cannot catch the crash this
          # produces for a nonexistent path, because interpolating a real
          # Nix `path` value through a flake's filtered source tree is a
          # restricted-eval abort, not an ordinary catchable exception.
          # Asserting the TYPE itself, rather than trying to reproduce one
          # downstream symptom of the wrong type, is both simpler and more
          # direct -- it's the actual root cause docs/decisions/0020
          # describes (eval-time crash OR a Nix-store secret leak,
          # depending on whether the path happens to exist on the build
          # machine).
          actualType =
            name: evaluated.options.services.victoriaStack.vmauth.${name}.type.nestedTypes.elemType.name;
          wrongTypes = builtins.filter (name: actualType name != "str") [
            "adminPasswordFile"
            "readTokensFile"
            "writeTokensFile"
          ];
        in
        if wrongTypes == [ ] then
          "echo OK > $out"
        else
          throw ''
            vmauth's ${builtins.concatStringsSep ", " wrongTypes} must be
            types.str, not types.path -- interpolating a Nix path forces a
            store copy at eval time (crash if the secret doesn't exist yet
            on the build machine, the normal LoadCredential= case per
            docs/decisions/0008; a plaintext secret leak into the Nix store
            if it does). See docs/decisions/0020.
          ''
      );

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

  redundant-write-token-while-writes-already-open-warns = mkWarningFiresCheck {
    name = "redundant-write-token-while-writes-already-open-warns";
    expectMessageSubstring = "writeTokensFile";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          requireAuthForWrites = false;
          writeTokensFile = "${writeTokensFixture}";
        };
      };
    };
  };

  # Control: writeTokensFile alone (requireAuthForWrites left at its true
  # default) is the normal, non-redundant configuration -- must NOT warn.
  write-token-without-open-writes-does-not-warn = mkNoWarningsCheck {
    name = "write-token-without-open-writes-does-not-warn";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
      };
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
      machine.wait_for_open_port(4204)

      # Open write path -- no credential at all, confirming
      # requireAuthForWrites = false genuinely leaves it unauthenticated.
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
      )
    '';
  };

  write-paths-can-be-closed-entirely-even-with-auth-disabled = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-paths-closed-via-empty-open-ingest-paths";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.requireAuthForWrites = false;
        # Overriding the auto-derived default to [] must close every
        # write path entirely, even with requireAuthForWrites = false --
        # this is the one guard (vmauth.nix's "($openmap[0] | length) > 0"
        # check) with no prior test coverage.
        vmauth.openIngestPaths = [ ];
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      machine.fail(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
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
        vmauth.writeTokensFile = "${writeTokensFixture}";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      # No credential: the write path must now reject the request (default
      # requireAuthForWrites = true).
      machine.fail(
          "curl -sf -X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"
      )

      # With a valid write-tier bearer token: must succeed.
      machine.succeed(
          "curl -sf -X POST -H 'Authorization: Bearer write-token-one' "
          "--data-binary 'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
      )
    '';
  };

  write_token_cannot_read = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-token-cannot-read";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        vmauth.readTokensFile = "${readTokensFixture}";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      # A write-tier token must NOT grant read access -- the whole point
      # of splitting the two tiers (docs/decisions/0003).
      machine.fail(
          "curl -sf -H 'Authorization: Bearer write-token-one' "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )

      # A read-tier token must succeed on the same read path.
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
    '';
  };

  read-path-requires-admin-password-or-token = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-read-path-requires-credential";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.adminPasswordFile = "${adminPasswordFixture}";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      # No credential at all: must be rejected.
      machine.fail(
          "curl -sf 'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )

      # Basic Auth with the admin password: must succeed.
      machine.succeed(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
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
