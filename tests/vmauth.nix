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
    otlpMetricGenerator
    otlpTestPython
    ;
  otlpMetric = "${otlpMetricGenerator}/bin/gen-otlp-metric";

  # Plain test fixtures -- not sops-rendered (this module's own options are
  # secrets-backend-agnostic, see docs/decisions/0008; sops-nix integration
  # is a consumer concern, not something to bring into the test harness).
  writeTokensFixture = pkgs.writeText "write-tokens.yaml" ''
    tokens:
      - token: write-token-one # collector-host-a
      - token: write-token-two # collector-host-b
  '';

  readTokensFixture = pkgs.writeText "read-tokens.yaml" ''
    tokens:
      - token: read-token-one # ai-client-a
  '';

  adminPasswordFixture = pkgs.writeText "admin-password" "admin-password-value";

  # Per-token scoping: a token may carry `backends`, restricting it to those
  # backends' own routes (raw API + that signal's MCP route for the read
  # tier; the signal's ingest door for the write tier).
  scopedReadTokensFixture = pkgs.writeText "scoped-read-tokens.yaml" ''
    tokens:
      - token: scoped-read-traces-only
        backends: ["traces"]
      - token: unscoped-read-token
  '';
  scopedWriteTokensFixture = pkgs.writeText "scoped-write-tokens.yaml" ''
    tokens:
      - token: scoped-write-metrics-only
        backends: ["metrics"]
      - token: unscoped-write-token
  '';

  # One container-boot test per malformed token file: vmauth must fail
  # closed with a message naming the file and what was wrong.
  mkBadTokensFileTest =
    {
      name,
      tier, # "read" | "write"
      yaml,
      expectInJournal,
      # Secrets must never reach the journal: the file holds them.
      expectNotInJournal ? null,
      # Content for the OTHER tier's file, for cross-file checks.
      otherYaml ? null,
      backends ? {
        metrics.enable = true;
      },
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-vmauth-${name}";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack = backends // {
          vmauth = {
            "${tier}TokensFile" = "${pkgs.writeText "bad-${tier}-tokens.yaml" yaml}";
          }
          // lib.optionalAttrs (otherYaml != null) {
            "${if tier == "read" then "write" else "read"}TokensFile" =
              "${pkgs.writeText "other-tokens.yaml" otherYaml}";
          };
        };
      };

      testScript = ''
        start_all()
        machine.fail("systemctl is-active vmauth.service")
        machine.succeed(
            "journalctl -u vmauth.service --no-pager | grep -qF ${lib.escapeShellArg expectInJournal}"
        )
        ${lib.optionalString (expectNotInJournal != null) ''
          machine.fail(
              "journalctl -u vmauth.service --no-pager | grep -qF ${lib.escapeShellArg expectNotInJournal}"
          )
        ''}
      '';
    };

  # Throwaway server cert for vmauth's own TLS listener (same shape as
  # tests/nginx.nix's selfSignedCert): the SAN must cover the address
  # curl dials or verification fails closed.
  selfSignedCert =
    pkgs.runCommand "vmauth-test-self-signed-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
          -subj "/CN=vmauth-test" -addext "subjectAltName=IP:127.0.0.1" \
          -keyout $out/key.pem -out $out/cert.pem
      '';

  # One of the 3 url_map JSON files vmauth's unit points at via its
  # Environment (READ_URL_MAP_FILE / WRITE_URL_MAP_FILE /
  # OPEN_INGEST_PATHS_FILE), parsed.
  urlMapFile =
    prefix: evaluated:
    let
      v =
        lib.findFirst (lib.hasPrefix "${prefix}=") null
          evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
    in
    builtins.fromJSON (builtins.readFile (lib.removePrefix "${prefix}=" v));
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
        "ProtectSystem" = (sc.ProtectSystem or null) == "strict";
        "CapabilityBoundingSet" = (sc.CapabilityBoundingSet or null) == "";
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

  # idleConnTimeout always renders (it has a non-null default, unlike the
  # inert-unless-configured options above) -- the gap was never testing
  # that an override actually reaches ExecStart, only that the default
  # propagates to nginx (tests/nginx.nix).
  idle-conn-timeout-override-reaches-execstart =
    pkgs.runCommand "vmauth-idle-conn-timeout-override-reaches-execstart" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth.idleConnTimeout = "45s";
            };
          };
          execStart = evaluated.config.systemd.services.vmauth.serviceConfig.ExecStart;
        in
        if lib.hasInfix "-http.idleConnTimeout=45s" execStart then
          "echo OK > $out"
        else
          throw "vmauth's idleConnTimeout override did not reach ExecStart: ${execStart}"
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
            "caFile references %d (LoadCredential), not a literal path" =
              lib.hasInfix "-backend.tlsCAFile=%d/backend-tls-ca" execStartSet;
            "caFile staged via LoadCredential" = lib.any (lib.hasPrefix "backend-tls-ca:") loadCredentialSet;
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
          # Every url_map file the module builds must carry the headers --
          # including a user-overridden openIngestPaths, which used to
          # bypass withExtraHeaders (it was only applied to the default).
          fileVar =
            prefix: evaluated:
            let
              v =
                lib.findFirst (lib.hasPrefix "${prefix}=") null
                  evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
            in
            builtins.fromJSON (builtins.readFile (lib.removePrefix "${prefix}=" v));
          withHeaders = lib.all (
            e:
            (e.headers or [ ]) == [
              "Authorization:"
              "TenantID: foobar"
            ]
            && (e.response_headers or [ ]) == [ "Server:" ]
          );
          overridden = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              logs.enable = true;
              vmauth = {
                extraRequestHeaders = [ "TenantID: foobar" ];
                extraResponseHeaders = [ "Server:" ];
                openIngestPaths = [
                  {
                    src_paths = [ "/opentelemetry.*" ];
                    url_prefix = "http://127.0.0.1:8428/";
                  }
                ];
              };
            };
          };
          checks = {
            "headers present in WRITE_URL_MAP_FILE when set" =
              fileVar "WRITE_URL_MAP_FILE" set != [ ] && withHeaders (fileVar "WRITE_URL_MAP_FILE" set);
            "headers present in default OPEN_INGEST_PATHS_FILE (not duplicated by double-wrapping)" =
              fileVar "OPEN_INGEST_PATHS_FILE" set != [ ] && withHeaders (fileVar "OPEN_INGEST_PATHS_FILE" set);
            "headers present in an overridden OPEN_INGEST_PATHS_FILE" =
              builtins.length (fileVar "OPEN_INGEST_PATHS_FILE" overridden) == 1
              && withHeaders (fileVar "OPEN_INGEST_PATHS_FILE" overridden);
            "only the Authorization strip when nothing is configured" = lib.all (
              e: (e.headers or [ ]) == [ "Authorization:" ] && !(e ? response_headers)
            ) unsetMap;
            "headers key present on every entry when set" =
              setMap != [ ]
              && lib.all (
                e:
                (e.headers or [ ]) == [
                  "Authorization:"
                  "TenantID: foobar"
                ]
                && (e.response_headers or [ ]) == [ "Server:" ]
              ) setMap;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraRequestHeaders/extraResponseHeaders broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # extraReadUrlMap (the escape hatch for arbitrary extra read routes)
  # had zero test coverage at all -- confirmed via grep before writing
  # this. Covers both: the route itself reaches READ_URL_MAP_FILE, and
  # (the actual regression this fixes) a route-specific `headers` entry
  # survives combination with a module-wide extraRequestHeaders default
  # instead of being silently overwritten by `//` (an earlier version of
  # withExtraHeaders did exactly that).
  extra-read-url-map-entry-headers-combine-with-module-default =
    pkgs.runCommand "vmauth-extra-read-url-map-headers-combine" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth = {
                extraRequestHeaders = [ "TenantID: global-default" ];
                extraReadUrlMap = [
                  {
                    src_paths = [ "/custom-route/.*" ];
                    url_prefix = "http://127.0.0.1:9999/";
                    headers = [ "X-Custom-Route: yes" ];
                  }
                ];
              };
            };
          };
          readUrlMapVar =
            lib.findFirst (lib.hasPrefix "READ_URL_MAP_FILE=") null
              evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
          readUrlMap = builtins.fromJSON (
            builtins.readFile (lib.removePrefix "READ_URL_MAP_FILE=" readUrlMapVar)
          );
          customEntry = lib.findFirst (e: e.src_paths == [ "/custom-route/.*" ]) null readUrlMap;
          checks = {
            "custom route reaches READ_URL_MAP_FILE at all" = customEntry != null;
            "custom route's own header survives" = lib.elem "X-Custom-Route: yes" (customEntry.headers or [ ]);
            "module-wide default header is also present (combined, not replaced)" =
              lib.elem "TenantID: global-default"
                (customEntry.headers or [ ]);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraReadUrlMap header combination broken: ${builtins.toJSON (builtins.attrNames failed)}"
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
      machine.wait_for_open_port(4201)

      # Open write path -- no credential at all, confirming
      # requireAuthForWrites = false genuinely leaves it unauthenticated.
      # Real OTLP protobuf, not plaintext: VictoriaMetrics' actual
      # /opentelemetry/v1/metrics handler rejects both a bare
      # "/opentelemetry" path and non-protobuf bodies (confirmed directly
      # against a real instance -- see otlpMetricGenerator's own comment
      # in tests/lib.nix). wait_until_succeeds, not succeed: VictoriaMetrics'
      # own -search.latencyOffset keeps freshly-ingested data invisible to
      # "now"-relative instant queries for ~30s by default.
      machine.succeed(
          "${otlpMetric} victoria_stack_vmauth_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' "
          "--data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_vmauth_test_metric' "
          "| grep -q victoria_stack_vmauth_test_metric"
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
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      code, body = otlp_status(machine, "http://127.0.0.1:4204/opentelemetry/v1/metrics")
      assert code == "401" and "missing 'Authorization'" in body, (code, body)
      # vmauth must not even have an unauthenticated user configured: an
      # empty one answers 400 "missing route" instead and hides a regression.
      import json
      cfg = json.loads(machine.succeed("cat /run/vmauth/config.json"))
      assert "unauthorized_user" not in cfg, cfg
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
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      # No credential: the write path must now reject the request (default
      # requireAuthForWrites = true).
      code, body = otlp_status(machine, "http://127.0.0.1:4204/opentelemetry/v1/metrics")
      assert code == "401" and "missing 'Authorization'" in body, (code, body)

      # With a valid write-tier bearer token: must succeed.
      machine.succeed(
          "${otlpMetric} victoria_stack_vmauth_write_token_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_vmauth_write_token_metric' "
          "| grep -q victoria_stack_vmauth_write_token_metric"
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
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )

      # A read-tier token must succeed on the same read path.
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "  # gitleaks:allow
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
          "curl -sf 'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"  # gitleaks:allow
      )

      # Basic Auth with the admin password: must succeed.
      machine.succeed(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
    '';
  };

  # Credentials are staged copies and config.json is rendered once at start, so
  # without help a replaced token file changes nothing until vmauth restarts
  # (verified: old token kept working after an in-place write and after a rename).
  # The module therefore watches each secret file and restarts vmauth. Covers an
  # in-place write and the write-new-then-rename that sops-nix does.
  token-file-replacement-restarts-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-token-rotation-restarts";

    containers.machine = {
      imports = [ module ];
      # A runtime path (not a store path) so the test can replace it.
      systemd.tmpfiles.rules = [
        "d /var/lib/rotation 0700 root root -"
        "f /var/lib/rotation/read.yaml 0600 root root - tokens:\\n  - token: token-generation-one\\n"
      ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.readTokensFile = "/var/lib/rotation/read.yaml";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_unit("vmauth-secret-watch-read-tokens.path")

      def status(token):
          return machine.succeed(
              "curl -s -o /dev/null -w '%{http_code}' "
              f"-H 'Authorization: Bearer {token}' "
              "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
          ).strip()

      def serves(token):
          # vmauth restarts asynchronously after the file changes.
          machine.wait_until_succeeds(
              "curl -s -o /dev/null -w '%{http_code}' "
              f"-H 'Authorization: Bearer {token}' "
              "'http://127.0.0.1:4204/metrics/api/v1/query?query=up' | grep -qx 200",
              timeout=60,
          )

      assert status("token-generation-one") == "200"

      # In-place rewrite.
      machine.succeed("printf 'tokens:\\n  - token: token-generation-two\\n' > /var/lib/rotation/read.yaml")
      serves("token-generation-two")
      assert status("token-generation-one") == "401"

      # Atomic rename into place.
      machine.succeed(
          "printf 'tokens:\\n  - token: token-generation-three\\n' > /var/lib/rotation/read.yaml.new"
          " && mv /var/lib/rotation/read.yaml.new /var/lib/rotation/read.yaml"
      )
      serves("token-generation-three")
      assert status("token-generation-two") == "401"
    '';
  };

  # Reverse of write_token_cannot_read above, and the admin-password
  # equivalent of both -- renderConfig only ever gives the admin user
  # READ_URL_MAP_FILE (nixosModule/victoriaStack/vmauth.nix), so neither
  # a read-tier token nor the admin Basic Auth credential should be able
  # to reach a write path. Previously only the write->read direction was
  # tested, not read->write or admin->write.
  read-token-and-admin-password-cannot-write = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-read-and-admin-cannot-write";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
        };
      };
    };

    testScript = ''
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      # A valid credential of the wrong tier has no write route at all: vmauth
      # itself answers "missing route" (a junk body would be rejected by the
      # backend even if it did have one).
      for auth in [
          "-H 'Authorization: Bearer read-token-one'",  # gitleaks:allow
          "-u admin:admin-password-value",  # gitleaks:allow
      ]:
          code, body = otlp_status(machine, "http://127.0.0.1:4204/opentelemetry/v1/metrics", auth)
          assert code == "400" and "missing route" in body, (auth, code, body)

      # Confirm both credentials still work on their actual intended
      # (read) path -- the write rejection above isn't masking a config
      # that broke reads entirely.
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
      machine.succeed(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
    '';
  };

  # All 3 credential tiers configured simultaneously -- each individual
  # tier is tested in isolation elsewhere, but never together in one
  # config, which is the realistic production shape (docs/decisions/0003
  # describes exactly this 3-tier setup).
  all-three-credential-tiers-coexist = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-all-three-tiers-coexist";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
          writeTokensFile = "${writeTokensFixture}";
        };
      };
    };

    testScript = ''
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      # Each tier's own route succeeds...
      machine.succeed(
          "curl -sf -u admin:admin-password-value "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
      machine.succeed(
          "${otlpMetric} victoria_stack_vmauth_all_tiers_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "-X POST -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_vmauth_all_tiers_test_metric' "
          "| grep -q victoria_stack_vmauth_all_tiers_test_metric"
      )

      # ...and no tier can reach outside its own scope, confirming the 3
      # tiers don't interfere with or widen each other when all present
      # at once.
      for auth in [
          "-u admin:admin-password-value",  # gitleaks:allow
          "-H 'Authorization: Bearer read-token-one'",  # gitleaks:allow
      ]:
          code, body = otlp_status(machine, "http://127.0.0.1:4204/opentelemetry/v1/metrics", auth)
          assert code == "400" and "missing route" in body, (auth, code, body)
      # config.json holds every token and the admin password in cleartext:
      # it must stay owner-only (UMask 0177).
      mode = machine.succeed("stat -c %a /run/vmauth/config.json").strip()
      assert mode == "600", f"config.json mode is {mode}, expected 600"
      machine.fail(
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
    '';
  };

  # Every other test in this file exercises one option/feature at a time
  # in isolation. This is the one real container-boot test combining
  # everything vmauth has a knob for simultaneously -- 3 credential
  # tiers, extraReadUrlMap (the escape hatch route), and
  # extraHeaders/extraResponseHeaders -- confirming they genuinely
  # compose rather than silently interfering with each other.
  # backendTls is deliberately NOT included here: exercising it for real
  # would require fabricating an HTTPS-speaking stand-in backend that
  # doesn't otherwise exist in this stack, which wouldn't verify anything
  # the module actually does in production -- it stays covered by its own
  # eval-only test (vmauth.nix's backendTls-options-reach-ExecStart,
  # addressed elsewhere in this file).
  full-combination-all-tiers-plus-extra-routes-plus-headers = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-full-combination";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        metrics.mcp.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
          writeTokensFile = "${writeTokensFixture}";
          extraRequestHeaders = [ "X-Full-Combo-Test: yes" ];
          extraResponseHeaders = [ "X-Full-Combo-Response: yes" ];
          extraReadUrlMap = [
            {
              src_paths = [ "/custom-escape-hatch" ];
              drop_src_path_prefix_parts = 1;
              url_prefix = [ "http://127.0.0.1:4201/api/v1/query" ];
            }
          ];
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      # All 3 tiers still independently work with every other feature
      # configured at once.
      machine.succeed(
          "curl -sf -u admin:admin-password-value "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer read-token-one' "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=up'"
      )
      machine.succeed(
          "${otlpMetric} victoria_stack_vmauth_full_combo_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "-X POST -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_vmauth_full_combo_test_metric' "
          "| grep -q victoria_stack_vmauth_full_combo_test_metric"
      )

      # extraReadUrlMap's custom route is reachable, requires a real
      # credential same as the built-in routes, and the response carries
      # both the custom route's own header behavior and the
      # module-wide extraResponseHeaders.
      machine.succeed(
          "curl -sf -u admin:admin-password-value "  # gitleaks:allow
          "'http://127.0.0.1:4204/custom-escape-hatch?query=up'"
      )
      machine.fail("curl -sf 'http://127.0.0.1:4204/custom-escape-hatch?query=up'")  # gitleaks:allow
      machine.succeed(
          "curl -sfD - -u admin:admin-password-value "
          "'http://127.0.0.1:4204/custom-escape-hatch?query=up' "
          "| grep -qi '^X-Full-Combo-Response: yes'"
      )
      # MCP stays reachable with the admin credential alongside everything
      # above, still behind auth, and still carries the module-wide
      # response header.
      mcp_init = (
          "-X POST 'http://127.0.0.1:4204/mcp/metrics' "
          "-H 'Content-Type: application/json' "
          "-H 'Accept: application/json, text/event-stream' "
          "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
          "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
          "\"clientInfo\":{\"name\":\"combo-test\",\"version\":\"1\"}}}'"
      )
      machine.succeed(
          f"curl -sfD - -o /dev/null -u admin:admin-password-value {mcp_init} "  # gitleaks:allow
          "| grep -qi '^X-Full-Combo-Response: yes'"
      )
      machine.fail(f"curl -sf {mcp_init}")

      # extraRequestHeaders reaching the real outbound backend request
      # (not just the generated config) isn't independently observable
      # here -- VictoriaMetrics' own log doesn't surface custom request
      # headers (confirmed empirically, not assumed). That it genuinely
      # merges into the config is already covered by this file's
      # extra-headers-are-inert-unless-configured eval-only check; this
      # test's job is confirming the setting doesn't break anything when
      # combined with everything else above, which it hasn't.
    '';
  };

  # requireAuthForWrites = true is the default, and vmauth auto-enables
  # the moment any backend is enabled -- so "backend enabled, nothing
  # else configured" (no writeTokensFile at all) is the single most
  # common shape a new user hits, not an edge case. Confirms the write
  # path genuinely, consistently rejects every request in that default
  # state (never silently falls back to open) -- the counterpart to
  # write-paths-require-write-token-by-default above, which always
  # configured a writeTokensFile; this is the "never configured one"
  # case, deliberately left unwarned (docs/decisions/0020 -- too many
  # legitimate setups write directly to the backend, bypassing vmauth
  # entirely, for this to be a safe-to-assume mistake).
  write-paths-reject-everything-when-no-write-tokens-file-configured = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-no-write-tokens-file-rejects-all-writes";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        # requireAuthForWrites left at its true default; writeTokensFile
        # deliberately left unset.
      };
    };

    testScript = ''
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      code, body = otlp_status(machine, "http://127.0.0.1:4204/opentelemetry/v1/metrics")
      assert code == "401" and "missing 'Authorization'" in body, (code, body)
      # Confirms there is no credential of any form (correctly-shaped or
      # not) that could open the write path in this state.
      code, body = otlp_status(
          machine,
          "http://127.0.0.1:4204/opentelemetry/v1/metrics",
          "-H 'Authorization: Bearer anything-at-all'",  # gitleaks:allow
      )
      assert code == "401" and "Unauthorized" in body, (code, body)
    '';
  };

  # vmauth builds symmetric url_map entries for all 3 signal types
  # (nixosModule/victoriaStack/vmauth.nix), but every other container
  # test in this file -- and the only real HTTP assertions in
  # tests/full.nix -- exclusively exercise the metrics route. A regex
  # typo or wrong drop_src_path_prefix_parts specific to logs or traces
  # routing would pass every existing test while being completely broken
  # for 2 of the 3 signal types in production. This test genuinely
  # exercises all 3 through vmauth's actual routing+auth, not just
  # metrics.
  all-three-signal-types-reachable-end-to-end-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-all-signal-types-end-to-end";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          requireAuthForWrites = false;
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4204)

      # Metrics: write via the auto-open ingest door, read via the
      # /metrics/ prefix with the admin credential.
      machine.succeed(
          "${otlpMetric} victoria_stack_vmauth_e2e_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' "  # gitleaks:allow
          "--data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=victoria_stack_vmauth_e2e_metric' "
          "| grep -q victoria_stack_vmauth_e2e_metric"
      )

      # Logs: written directly against the backend's own port, bypassing
      # vmauth entirely -- vmauth's only real supported write path for
      # logs is systemd-journal-upload's own wire format (exercised by
      # the dedicated collector cross-container tests elsewhere); the
      # read tier's own url_map is a closed allow-list under /select/*
      # only (docs/decisions/0021) and genuinely cannot reach
      # /insert/jsonline -- confirmed by
      # read-tier-is-genuinely-read-only above. This test's own goal is
      # proving vmauth's READ routing works for all 3 signals, not
      # re-proving every possible write path.
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_vmauth_e2e_log\"}"
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "  # gitleaks:allow
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/logs/select/logsql/query' -d 'query=victoria_stack_vmauth_e2e_log' "
          "| grep -q victoria_stack_vmauth_e2e_log"
      )

      # Traces: write via the auto-open OTLP ingest door, read via the
      # /traces/ prefix (Jaeger API) with the admin credential.
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_vmauth_e2e_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000003\","
          "\"spanId\":\"0000000000000003\","
          "\"name\":\"victoria_stack_vmauth_e2e_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "  # gitleaks:allow
          "'http://127.0.0.1:4204/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf -u admin:admin-password-value "
          "'http://127.0.0.1:4204/traces/select/jaeger/api/services' "
          "| grep -q victoria_stack_vmauth_e2e_service"
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

  # vmauth.package is the only one of the 4 independent .package options
  # (metrics/logs/traces/vmauth, ADR 0007) that had never been confirmed
  # to actually reach ExecStart, nor had its nontrivial conditional
  # default (mkDefault, tracking metrics' own package when metrics is
  # enabled, falling back to pkgs.victoriametrics otherwise) been tested
  # in either branch.
  #
  # lib.hasPrefix, not lib.hasInfix: a regex needle carrying store-path
  # context makes builtins.match refuse to compile ("is not allowed to
  # refer to a store path") -- confirmed by hitting it directly. ExecStart
  # always starts with "${package}/bin/vmauth ...", so a prefix check
  # (plain string-length comparison, no regex) is both sufficient and safe.
  package-override-takes-effect = pkgs.runCommand "vmauth-package-override-takes-effect" { } (
    let
      overridePackage = pkgs.hello; # any derivation with a /bin -- content irrelevant, only the store path is checked
      evaluated = evalWith {
        services.victoriaStack = {
          metrics.enable = true;
          vmauth.package = overridePackage;
        };
      };
      execStart = evaluated.config.systemd.services.vmauth.serviceConfig.ExecStart;
    in
    if lib.hasPrefix "${overridePackage}/bin/vmauth" execStart then
      "echo OK > $out"
    else
      throw "vmauth's ExecStart did not resolve through the overridden package: ${execStart}"
  );

  package-default-falls-back-to-upstream-victoriametrics-without-metrics-enabled =
    pkgs.runCommand "vmauth-package-default-fallback" { }
      (
        let
          # metrics disabled, logs enabled instead -- exercises the
          # "else pkgs.victoriametrics" branch of vmauth's own package
          # default, never exercised by any other test (every other test
          # enables metrics, which always takes the "if" branch).
          evaluated = evalWith { services.victoriaStack.logs.enable = true; };
          execStart = evaluated.config.systemd.services.vmauth.serviceConfig.ExecStart;
        in
        if lib.hasPrefix "${pkgs.victoriametrics}/bin/vmauth" execStart then
          "echo OK > $out"
        else
          throw "vmauth's package fallback (no metrics enabled) did not resolve to pkgs.victoriametrics: ${execStart}"
      );

  # docs/decisions/0021 -- the read tier (readTokensFile/adminPasswordFile)
  # was a blanket passthrough to each backend's ENTIRE native HTTP API, not
  # a read-only route set. Verified live before this fix: a read-token
  # could POST to /api/v1/import (write arbitrary data) and
  # /api/v1/admin/tsdb/delete_series (permanently delete data) through
  # vmauth's own "read" credential. This is the regression guard: confirms
  # the read tier can reach real read endpoints but NOT real write/
  # destructive ones, for all 3 backends, with both credential types
  # (admin password and read token) that share the exact same url_map.
  read-tier-is-genuinely-read-only = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-read-tier-is-genuinely-read-only";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
          requireAuthForWrites = false; # only to seed real data directly against each backend below, not exercised through the read tier itself
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)
      machine.wait_for_open_port(4202)
      machine.wait_for_open_port(4203)

      # Seed real data directly against each backend (bypassing vmauth
      # entirely -- this test is about vmauth's own routing restrictions,
      # not re-proving each backend's own ingest API).
      machine.succeed(
          "curl -sf -X POST --data-binary "
          "'victoria_stack_readonly_probe_metric 1' "
          "'http://127.0.0.1:4201/api/v1/import/prometheus'"
      )
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_readonly_probe_log\"}"
          ",\"date\":\"0\",\"stream\":\"roundtrip\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )

      for cred in ["-u admin:admin-password-value", "-H 'Authorization: Bearer read-token-one'"]:
          # --- metrics: real read endpoints still work ---
          machine.wait_until_succeeds(
              f"curl -sf {cred} 'http://127.0.0.1:4204/metrics/api/v1/query"
              "?query=victoria_stack_readonly_probe_metric' "
              "| grep -q victoria_stack_readonly_probe_metric"
          )
          machine.succeed(
              f"curl -sf {cred} -d 'match[]=victoria_stack_readonly_probe_metric' "
              "'http://127.0.0.1:4204/metrics/api/v1/series'"
          )
          machine.succeed(
              f"curl -sf {cred} 'http://127.0.0.1:4204/metrics/api/v1/labels'"
          )
          # --- metrics: real write/destructive endpoints are rejected ---
          machine.fail(
              f"curl -sf {cred} -X POST --data-binary "
              "'{\"metric\":{\"__name__\":\"victoria_stack_should_never_land\"},"
              "\"values\":[1],\"timestamps\":[0]}' "
              "'http://127.0.0.1:4204/metrics/api/v1/import'"
          )
          machine.fail(
              f"curl -sf {cred} -X POST --data-binary "
              "'match[]=victoria_stack_readonly_probe_metric' "
              "'http://127.0.0.1:4204/metrics/api/v1/admin/tsdb/delete_series'"
          )

          # --- logs: real read endpoint still works ---
          machine.wait_until_succeeds(
              f"curl -sf {cred} 'http://127.0.0.1:4204/logs/select/logsql/query' "
              "-d 'query=victoria_stack_readonly_probe_log' "
              "| grep -q victoria_stack_readonly_probe_log"
          )
          # --- logs: real write endpoint is rejected ---
          machine.fail(
              f"curl -sf {cred} -X POST -H 'Content-Type: application/stream+json' "
              "--data-binary '{\"log\":{\"level\":\"info\",\"message\":\"x\"},"
              "\"date\":\"0\",\"stream\":\"x\"}' "
              "'http://127.0.0.1:4204/logs/insert/jsonline"
              "?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
          )

          # --- traces: real read endpoint still works ---
          machine.succeed(
              f"curl -sf {cred} 'http://127.0.0.1:4204/traces/select/jaeger/api/services'"
          )
          # --- traces: real write endpoint is rejected ---
          machine.fail(
              f"curl -sf {cred} -X POST -H 'Content-Type: application/json' "
              "--data-binary '{{}}' "
              "'http://127.0.0.1:4204/traces/insert/opentelemetry/v1/traces'"
          )
    '';
  };

  # Closed-world assertion: pins the literal src_paths list for each
  # backend's read-tier route, so a future accidental widening back
  # toward a wildcard (e.g. "/metrics/.*") is caught immediately, not
  # just "still passes because the specific endpoints above still work".
  read-tier-url-map-is-a-closed-allow-list-not-a-wildcard =
    pkgs.runCommand "vmauth-read-tier-closed-allow-list" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              logs.enable = true;
              traces.enable = true;
            };
          };
          readUrlMapVar =
            lib.findFirst (lib.hasPrefix "READ_URL_MAP_FILE=") null
              evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
          readUrlMap = builtins.fromJSON (
            builtins.readFile (lib.removePrefix "READ_URL_MAP_FILE=" readUrlMapVar)
          );
          wildcardEntries = lib.filter (
            e:
            lib.any (
              p: lib.hasSuffix ".*" p && !(lib.hasInfix "/select/" p) && !(lib.hasInfix "/export" p)
            ) e.src_paths
          ) readUrlMap;
        in
        if wildcardEntries == [ ] then
          "echo OK > $out"
        else
          throw ''
            Expected every metrics read-tier src_paths entry to be a closed
            allow-list (specific endpoints), not a broad wildcard -- found:
            ${builtins.toJSON wildcardEntries}
          ''
      );

  # yq parses a `tokens:` key that's absent or not a list without ever
  # failing (exit 0, JSON `null` or a bare string) -- jq's own downstream
  # failure on that shape ("Cannot iterate over null (null)") names
  # neither the file nor the expected shape. Confirmed this crashes
  # illegibly before vmauth-render-config's validate_tokens_shape guard
  # was added; this test pins the NEW, legible failure mode.
  malformed-read-tokens-file-fails-with-a-legible-error = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-malformed-read-tokens-legible-error";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.readTokensFile = "${pkgs.writeText "malformed-read-tokens.yaml" ''
          not_tokens:
            - this-key-is-wrong
        ''}";
      };
    };

    testScript = ''
      start_all()
      # The service must still fail closed (a typo must not silently serve
      # zero tokens) -- but legibly now, naming the file and expected shape.
      machine.fail("systemctl is-active vmauth.service")
      machine.succeed(
          "journalctl -u vmauth.service --no-pager "
          "| grep -q \"readTokensFile must contain a top-level 'tokens:' key\""
      )
    '';
  };

  # Mirror of the read-tier test above for writeTokensFile -- the two
  # share validate_tokens_shape but are separate branches in the script.
  malformed-write-tokens-file-fails-with-a-legible-error = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-malformed-write-tokens-legible-error";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = "${pkgs.writeText "malformed-write-tokens.yaml" ''
          not_tokens:
            - this-key-is-wrong
        ''}";
      };
    };

    testScript = ''
      start_all()
      machine.fail("systemctl is-active vmauth.service")
      machine.succeed(
          "journalctl -u vmauth.service --no-pager "
          "| grep -q \"writeTokensFile must contain a top-level 'tokens:' key\""
      )
    '';
  };

  # No /mcp/* route may exist anywhere unless that service's own MCP is on.
  mcp-url-map-entries-absent-when-mcp-disabled =
    pkgs.runCommand "vmauth-no-mcp-routes-when-mcp-disabled" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              logs.enable = true;
              traces.enable = true;
              # every *.mcp.enable left at its false default
            };
          };
          mentionsMcp = e: lib.any (lib.hasPrefix "/mcp") (e.src_paths or [ ]);
        in
        if !(lib.any mentionsMcp (urlMapFile "READ_URL_MAP_FILE" evaluated)) then
          "echo OK > $out"
        else
          throw "found an /mcp route in the read url_map with every mcp.enable = false"
      );

  # The vmauth side of the effectiveUrl seam (docs/decisions/0019): every
  # url_prefix this module builds for a backend derives from effectiveUrl.
  vmauth-url-prefixes-use-effective-url =
    pkgs.runCommand "vmauth-url-prefixes-use-effective-url" { }
      (
        let
          fake = n: "http://${n}.example.invalid:9999";
          evaluated = evalWith {
            services.victoriaStack = {
              metrics = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "m");
              };
              logs = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "l");
              };
              traces = {
                enable = true;
                effectiveUrl = lib.mkForce (fake "t");
              };
            };
          };
          prefixes = file: map (e: e.url_prefix) (urlMapFile file evaluated);
          expected = [
            "${fake "m"}/"
            "${fake "l"}/"
            "${fake "t"}/"
          ];
          checks = {
            "read url_map" = prefixes "READ_URL_MAP_FILE" == expected;
            "write url_map" = prefixes "WRITE_URL_MAP_FILE" == expected;
            "open ingest paths" = prefixes "OPEN_INGEST_PATHS_FILE" == expected;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "url_prefix did not track effectiveUrl for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # openIngestPaths overridden to exactly ONE entry (metrics' own door)
  # while logs and traces are also enabled: only metrics' unauthenticated
  # door opens; logs'/traces' stay closed to anonymous callers -- yet a
  # write-tier token still reaches them (docs/decisions/0014: the write
  # tier never follows the open-door override).
  open-ingest-paths-genuine-partial-override = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-open-ingest-paths-partial-override";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        vmauth = {
          requireAuthForWrites = false;
          writeTokensFile = "${writeTokensFixture}";
          openIngestPaths = [
            {
              src_paths = [ "/opentelemetry.*" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      machine.succeed(
          "${otlpMetric} victoria_stack_partial_override_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )

      def status(extra, path):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' -X POST {extra} --data-binary '{{}}' "
              f"'http://127.0.0.1:4204{path}'"
          )

      for path in ["/insert/journald/upload", "/insert/opentelemetry/v1/traces"]:
          anon = status("", path)
          assert anon == "401", f"anonymous POST to {path} should be rejected (401), got {anon}"
          authed = status("-H 'Authorization: Bearer write-token-one'", path)  # gitleaks:allow
          assert authed != "401", f"write-tier token must still reach {path}, got {authed}"
    '';
  };

  # vmauth.extraFlags is the generic pass-through, same as the storage
  # services' extraFlags: reaches ExecStart verbatim, and last.
  vmauth-extra-flags-reach-execstart-verbatim =
    pkgs.runCommand "vmauth-extra-flags-reach-execstart" { }
      (
        let
          execStart = m: (evalWith m).config.systemd.services.vmauth.serviceConfig.ExecStart;
          # ExecStart is shell-escaped: strip the quotes to compare flags as text.
          unq = lib.replaceStrings [ "'" ] [ "" ];
          unset = execStart { services.victoriaStack.metrics.enable = true; };
          set = execStart {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth.extraFlags = [
                "-tlsCertFile=/foo"
                "-tlsKeyFile=/bar"
              ];
            };
          };
          checks = {
            "absent by default" = !(lib.hasInfix "-tlsCertFile" unset);
            "flags present verbatim" = lib.hasInfix "-tlsCertFile=/foo -tlsKeyFile=/bar" (unq set);
            "flags are last" = lib.hasSuffix "-tlsCertFile=/foo -tlsKeyFile=/bar" (unq set);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "vmauth.extraFlags broken: ${builtins.toJSON (builtins.attrNames failed)}\n${set}"
      );

  # extraFlags used for something real: vmauth's own TLS listener, reached
  # directly (no nginx in front).
  vmauth-serves-https-via-extra-flags = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-https-via-extra-flags";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          extraFlags = [
            "-tls"
            "-tlsCertFile=${selfSignedCert}/cert.pem"
            "-tlsKeyFile=${selfSignedCert}/key.pem"
          ];
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      url = "https://127.0.0.1:4204/metrics/api/v1/labels"
      machine.succeed(
          "curl -sf --cacert ${selfSignedCert}/cert.pem -u admin:admin-password-value '" + url + "'"  # gitleaks:allow
      )
      # Plain HTTP on the TLS listener must not work, and verification
      # must fail closed without the CA.
      machine.fail("curl -sf --max-time 5 -u admin:admin-password-value 'http://127.0.0.1:4204/metrics/api/v1/labels'")  # gitleaks:allow
      machine.fail("curl -sf --max-time 5 -u admin:admin-password-value '" + url + "'")  # gitleaks:allow
    '';
  };

  # --- extraWriteUrlMap ---

  extra-write-url-map-reaches-only-the-write-tier-file =
    pkgs.runCommand "vmauth-extra-write-url-map-write-tier-only" { }
      (
        let
          entry = {
            src_paths = [ "/write" ];
            url_prefix = "http://127.0.0.1:4201/";
          };
          evaluated = evalWith {
            services.victoriaStack = {
              metrics.enable = true;
              vmauth = {
                extraWriteUrlMap = [ entry ];
                extraRequestHeaders = [ "X-Extra-Write: yes" ];
              };
            };
          };
          has = file: lib.any (e: e.src_paths == entry.src_paths) (urlMapFile file evaluated);
          written = lib.findFirst (e: e.src_paths == entry.src_paths) null (
            urlMapFile "WRITE_URL_MAP_FILE" evaluated
          );
          checks = {
            "in the write-tier url_map" = has "WRITE_URL_MAP_FILE";
            "NOT in the read-tier url_map" = !(has "READ_URL_MAP_FILE");
            "NOT in the open (unauthenticated) ingest paths" = !(has "OPEN_INGEST_PATHS_FILE");
            "module-wide headers apply" =
              written != null
              &&
                written.headers == [
                  "Authorization:"
                  "X-Extra-Write: yes"
                ];
            "auto-derived write routes still present" = lib.any (e: e.src_paths == [ "/opentelemetry.*" ]) (
              urlMapFile "WRITE_URL_MAP_FILE" evaluated
            );
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "extraWriteUrlMap wiring broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # The escape hatch is the operator's own responsibility (no allow-list
  # enforced, ADR 0021 covers only the built-in routes) -- but a pattern
  # that matches EVERY path is almost certainly a mistake, so it warns.
  extra-url-map-match-everything-pattern-warns = mkWarningFiresCheck {
    name = "extra-url-map-match-everything-pattern-warns";
    expectMessageSubstring = "matches every path";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.extraWriteUrlMap = [
          {
            src_paths = [ "/.*" ];
            url_prefix = "http://127.0.0.1:4201/";
          }
        ];
      };
    };
  };

  extra-read-url-map-match-everything-pattern-warns = mkWarningFiresCheck {
    name = "extra-read-url-map-match-everything-pattern-warns";
    expectMessageSubstring = "matches every path";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.extraReadUrlMap = [
          {
            src_paths = [ ".*" ];
            url_prefix = "http://127.0.0.1:4201/";
          }
        ];
      };
    };
  };

  extra-url-map-narrow-patterns-do-not-warn = mkNoWarningsCheck {
    name = "extra-url-map-narrow-patterns-do-not-warn";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          extraWriteUrlMap = [
            {
              src_paths = [ "/write" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
            {
              src_paths = [ "/api/v1/write.*" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
          extraReadUrlMap = [
            {
              src_paths = [ "/custom/.*" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
        };
      };
    };
  };

  # A real InfluxDB-line-protocol write through the escape hatch lands, and
  # the read tier cannot reach the same path (the property ADR 0021 exists
  # to guarantee, re-confirmed for the new escape hatch).
  extra-write-url-map-lands-data-and-stays-closed-to-the-read-tier = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-extra-write-url-map";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
          writeTokensFile = "${writeTokensFixture}";
          extraWriteUrlMap = [
            {
              src_paths = [ "/write" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
        };
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      line = "influx_extra_write_test,host=a value=42"
      machine.succeed(
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          f"-X POST --data-binary '{line}' 'http://127.0.0.1:4204/write'"
      )
      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=influx_extra_write_test_value' "
          "| grep -q '\"value\"'"
      )

      def status(auth):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' {auth} -X POST "
              f"--data-binary '{line}' 'http://127.0.0.1:4204/write'"
          )

      for name, auth in [
          ("read-tier token", "-H 'Authorization: Bearer read-token-one'"),  # gitleaks:allow
          ("admin", "-u admin:admin-password-value"),  # gitleaks:allow
          ("anonymous", ""),
      ]:
          code = status(auth)
          assert code in ("400", "401", "403"), f"{name} must not reach /write, got {code}"
    '';
  };

  # --- per-token scoping ---

  scoped-read-token-reaches-only-its-backends = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-scoped-read-token";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        logs = {
          enable = true;
          mcp.enable = true;
        };
        traces = {
          enable = true;
          mcp.enable = true;
        };
        vmauth.readTokensFile = "${scopedReadTokensFixture}";
      };
    };

    testScript = ''
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      for unit in ["mcp-victoriametrics", "mcp-victorialogs", "mcp-victoriatraces"]:
          machine.wait_for_unit(f"{unit}.service")
      machine.wait_for_open_port(4204)

      scoped = "-H 'Authorization: Bearer scoped-read-traces-only'"  # gitleaks:allow
      unscoped = "-H 'Authorization: Bearer unscoped-read-token'"  # gitleaks:allow
      init = (
          "-X POST -H 'Content-Type: application/json' "
          "-H 'Accept: application/json, text/event-stream' "
          "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
          "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
          "\"clientInfo\":{\"name\":\"scope-test\",\"version\":\"1\"}}}'"
      )

      def code(auth, path, extra=""):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' {auth} {extra} 'http://127.0.0.1:4204{path}'"
          )

      # The scoped token reaches its own backend: raw API and MCP route.
      assert code(scoped, "/traces/select/jaeger/api/services") == "200"
      assert code(scoped, "/mcp/traces", init) == "200"

      # ...and nothing else, on either surface.
      # A valid-but-unrouted request is vmauth's own 400 "missing route"; any
      # other status would mean the request reached a backend.
      for path in ["/metrics/api/v1/labels", "/logs/select/logsql/query?query=*"]:
          c = code(scoped, path)
          assert c == "400", f"scoped token reached {path}: {c}"
      for path in ["/mcp/metrics", "/mcp/logs"]:
          c = code(scoped, path, init)
          assert c == "400", f"scoped token reached {path}: {c}"

      # An unscoped token still reaches everything (backward compatible).
      assert code(unscoped, "/metrics/api/v1/labels") == "200"
      # (the /logs probe above needs this control: without it a 400 could be a
      # backend rejecting the query rather than vmauth having no route)
      assert code(unscoped, "/logs/select/logsql/query?query=*") == "200"
      assert code(unscoped, "/traces/select/jaeger/api/services") == "200"
      assert code(unscoped, "/mcp/logs", init) == "200"

      # Backward-compat guarantee at the config level: an unscoped token's
      # url_map is exactly the full read url_map; a scoped one is a strict
      # subset.
      users = json.loads(machine.succeed("cat /run/vmauth/config.json"))["users"]
      by_token = {u["bearer_token"]: u["url_map"] for u in users}
      full = by_token["unscoped-read-token"]
      scoped_map = by_token["scoped-read-traces-only"]
      assert len(scoped_map) < len(full), (scoped_map, full)
      assert all(e in full for e in scoped_map)
    '';
  };

  scoped-write-token-reaches-only-its-backends = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-scoped-write-token";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        vmauth.writeTokensFile = "${scopedWriteTokensFixture}";
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(4201)

      scoped = "-H 'Authorization: Bearer scoped-write-metrics-only'"  # gitleaks:allow
      unscoped = "-H 'Authorization: Bearer unscoped-write-token'"  # gitleaks:allow

      # A bare status can't tell "vmauth has no route" from "the backend
      # rejected my dummy payload" (VictoriaLogs answers 400 to a bogus
      # journald upload) -- vmauth's own unrouted response says
      # "missing route", so that is what's asserted on.
      def body(auth, path):
          return machine.succeed(
              f"curl -s {auth} -X POST --data-binary '{{}}' 'http://127.0.0.1:4204{path}'"
          )

      machine.succeed(
          "${otlpMetric} victoria_stack_scoped_write_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          f"curl -sf {scoped} -X POST -H 'Content-Type: application/x-protobuf' "
          "--data-binary @/tmp/otlp.bin 'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      for path in ["/insert/journald/upload", "/insert/opentelemetry/v1/traces"]:
          assert "missing route" in body(scoped, path), f"metrics-scoped write token reached {path}"
          # The unscoped write token still has a route to every ingest door.
          assert "missing route" not in body(unscoped, path), f"unscoped write token has no route to {path}"
    '';
  };

  old-bare-string-token-format-gives-a-migration-error = mkBadTokensFileTest {
    name = "old-bare-string-token-format";
    tier = "read";
    yaml = ''
      tokens:
        - an-old-style-bare-string-token
    '';
    expectInJournal = "bare strings";
  };

  token-entry-without-a-token-key-is-a-legible-error = mkBadTokensFileTest {
    name = "token-entry-without-token-key";
    tier = "write";
    yaml = ''
      tokens:
        - backends: ["metrics"]
    '';
    expectInJournal = "a string `token` key";
  };

  unknown-backend-name-in-a-token-is-a-legible-error = mkBadTokensFileTest {
    name = "unknown-backend-name";
    tier = "read";
    yaml = ''
      tokens:
        - token: some-token
          backends: ["metricz"]
    '';
    expectInJournal = "unknown backend";
  };

  token-scoped-only-to-a-disabled-backend-is-a-legible-error = mkBadTokensFileTest {
    name = "scoped-to-disabled-backend";
    tier = "read";
    yaml = ''
      tokens:
        - token: some-token
          backends: ["traces"]
    '';
    expectInJournal = "none of its backends is enabled";
    # traces deliberately NOT enabled.
    backends = {
      metrics.enable = true;
    };
  };

  # --- public write doors (vmauth.https / vmauth.http) ---

  write-doors-listener-flags-are-aligned-for-every-mode =
    pkgs.runCommand "vmauth-write-doors-listener-flags" { }
      (
        let
          eval =
            vmauth:
            evalWith {
              services.victoriaStack = {
                metrics.enable = true;
                inherit vmauth;
              };
            };
          execStart = e: e.config.systemd.services.vmauth.serviceConfig.ExecStart;
          # ExecStart is shell-escaped (every flag containing `=` is single-quoted);
          # strip the quotes so adjacent flags compare as one string.
          has = needle: e: lib.hasInfix needle (lib.replaceStrings [ "'" ] [ "" ] (execStart e));
          certs = {
            certFile = "/run/secrets/door.pem";
            keyFile = "/run/secrets/door.key";
          };
          none = eval { };
          httpsOnly = eval {
            https = {
              enable = true;
            }
            // certs;
          };
          both = eval {
            https = {
              enable = true;
            }
            // certs;
            http = {
              enable = true;
              ipAddress = "127.0.0.1";
            };
          };
          v6 = eval {
            https = {
              enable = true;
              ipAddress = "::";
              port = 9443;
            }
            // certs;
          };
          httpOnly = eval { http.enable = true; };
          lc = e: e.config.systemd.services.vmauth.serviceConfig.LoadCredential;
          checks = {
            "default: exactly one listener, no -tls flags (unchanged from before)" =
              has "-httpListenAddr=127.0.0.1:4204" none && !(has "-tls" none) && !(has "https-cert" none);
            "https only: internal + https listeners, arrays aligned" =
              has "-httpListenAddr=127.0.0.1:4204 -httpListenAddr=0.0.0.0:8443" httpsOnly
              && has "-tls=false -tls=true" httpsOnly
              && has "-tlsCertFile= -tlsCertFile=%d/https-cert" httpsOnly
              && has "-tlsKeyFile= -tlsKeyFile=%d/https-key" httpsOnly;
            "https only: cert and key staged as credentials, not store paths" =
              lib.elem "https-cert:/run/secrets/door.pem" (lc httpsOnly)
              && lib.elem "https-key:/run/secrets/door.key" (lc httpsOnly);
            "https + loopback http: three aligned listeners" =
              has "-httpListenAddr=127.0.0.1:4204 -httpListenAddr=0.0.0.0:8443 -httpListenAddr=127.0.0.1:8080" both
              && has "-tls=false -tls=true -tls=false" both
              && has "-tlsCertFile= -tlsCertFile=%d/https-cert -tlsCertFile=" both
              && has "-tlsKeyFile= -tlsKeyFile=%d/https-key -tlsKeyFile=" both;
            "http only: plain second listener, no TLS flags needed" =
              has "-httpListenAddr=127.0.0.1:4204 -httpListenAddr=0.0.0.0:8080" httpOnly
              && !(has "-tls" httpOnly);
            "IPv6 address is bracketed" = has "-httpListenAddr=[::]:9443" v6;
            "an already-bracketed IPv6 address is not bracketed twice" =
              has "-httpListenAddr=[::1]:8443" (eval {
                https = {
                  enable = true;
                  ipAddress = "[::1]";
                }
                // certs;
              })
              && !(has "[[" (eval {
                https = {
                  enable = true;
                  ipAddress = "[::1]";
                }
                // certs;
              }));
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "write-door flags broken: ${builtins.toJSON (builtins.attrNames failed)}\n${execStart both}"
      );

  write-doors-assertions = pkgs.runCommand "vmauth-write-doors-assertions" { } (
    let
      # Own messages only: the bare eval harness never satisfies the
      # unrelated base-NixOS assertions (root fs, bootloader).
      failedFor =
        vmauth:
        lib.filter (lib.hasInfix "services.victoriaStack") (
          map (a: a.message) (
            builtins.filter (a: !a.assertion)
              (evalWith {
                services.victoriaStack = {
                  metrics.enable = true;
                  inherit vmauth;
                };
              }).config.assertions
          )
        );
      fires = sub: vmauth: lib.any (lib.hasInfix sub) (failedFor vmauth);
      certs = {
        certFile = "/run/secrets/door.pem";
        keyFile = "/run/secrets/door.key";
      };
      checks = {
        "https without any certificate" = fires "vmauth.https" { https.enable = true; };
        "certFile without keyFile" = fires "vmauth.https" {
          https = {
            enable = true;
            certFile = "/run/secrets/door.pem";
          };
        };
        "both files AND an ACME name" = fires "vmauth.https" {
          https = {
            enable = true;
            acmeCertName = "example.test";
          }
          // certs;
        };
        "ACME name that the operator never defined" = fires "example.test" {
          https = {
            enable = true;
            acmeCertName = "example.test";
          };
        };
        "http and https on the same ip:port" = fires "same listenAddress" {
          https = {
            enable = true;
            port = 8080;
          }
          // certs;
          http = {
            enable = true;
            ipAddress = "0.0.0.0";
          };
        };
        "a valid https door raises nothing" =
          failedFor {
            https = {
              enable = true;
            }
            // certs;
          } == [ ];
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "write-door assertions broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # Both doors for real: HTTPS on 8443 with an operator-supplied cert (this
  # also proves the positional -tls array with empty slots parses), plain
  # HTTP on loopback 8080 (the tailscale-serve shape), and the internal
  # 4204 listener still plain.
  write-doors-https-and-loopback-http-boot = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-doors";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          writeTokensFile = "${writeTokensFixture}";
          https = {
            enable = true;
            certFile = "${selfSignedCert}/cert.pem";
            keyFile = "${selfSignedCert}/key.pem";
          };
          http = {
            enable = true;
            ipAddress = "127.0.0.1";
          };
        };
      };
    };

    testScript = ''
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(8443)
      machine.wait_for_open_port(8080)
      machine.wait_for_open_port(4201)

      machine.succeed("${otlpMetric} victoria_stack_write_doors_metric 1 > /tmp/otlp.bin")
      post = (
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "-X POST -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
      )
      path = "/opentelemetry/v1/metrics"

      # HTTPS door: verified against the CA, and refused without credentials.
      machine.succeed(post + "--cacert ${selfSignedCert}/cert.pem 'https://127.0.0.1:8443" + path + "'")
      # (Without --cacert such a probe would fail on certificate verification and
      # prove nothing about credentials, so it carries the CA.)
      code, body = otlp_status(
          machine, "https://127.0.0.1:8443" + path, "--cacert ${selfSignedCert}/cert.pem"
      )
      assert code == "401" and "missing 'Authorization'" in body, (code, body)
      machine.fail(post + "--max-time 5 'https://127.0.0.1:8443" + path + "'")  # no CA -> verification fails

      # Plain loopback HTTP door and the unchanged internal listener.
      machine.succeed(post + "'http://127.0.0.1:8080" + path + "'")
      machine.succeed(post + "'http://127.0.0.1:4204" + path + "'")
      # TLS is per listener: the internal one must NOT speak TLS.
      machine.fail("curl -sf --max-time 5 --cacert ${selfSignedCert}/cert.pem 'https://127.0.0.1:4204/'")

      # Reachability matches the config: 8443 on every interface, 8080 only on loopback.
      listeners = machine.succeed("ss -Hltn")
      assert "0.0.0.0:8443" in listeners or "*:8443" in listeners, listeners
      assert "127.0.0.1:8080" in listeners, listeners
      assert "0.0.0.0:8080" not in listeners and "*:8080" not in listeners, listeners

      machine.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=victoria_stack_write_doors_metric' | grep -q '\"value\"'"
      )
    '';
  };

  write-door-http-open-on-all-interfaces = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-write-door-http-open";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          writeTokensFile = "${writeTokensFixture}";
          http.enable = true; # 0.0.0.0:8080
        };
      };
    };

    testScript = ''
      ${otlpTestPython}
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(8080)
      listeners = machine.succeed("ss -Hltn")
      assert "0.0.0.0:8080" in listeners or "*:8080" in listeners, listeners
      assert "8443" not in listeners, listeners
      code, body = otlp_status(machine, "http://127.0.0.1:8080/opentelemetry/v1/metrics")
      assert code == "401" and "missing 'Authorization'" in body, (code, body)
    '';
  };

  # --- accessLog (per-request log lines for credentialed users) ---

  access-log-is-off-by-default-and-renders-nothing = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-access-log-default-off";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          readTokensFile = "${readTokensFixture}";
          writeTokensFile = "${writeTokensFixture}";
        };
      };
    };

    testScript = ''
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      users = json.loads(machine.succeed("cat /run/vmauth/config.json"))["users"]
      assert users and all("access_log" not in u for u in users), users
    '';
  };

  # With accessLog on, a SUCCESSFUL write from another machine leaves a log
  # line carrying that machine's real address (without it, only failures do).
  access-log-records-the-source-of-successful-writes = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-access-log-on";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          writeTokensFile = "${writeTokensFixture}";
          accessLog = true;
          http.enable = true; # 0.0.0.0:8080
        };
      };
      networking.firewall.allowedTCPPorts = [ 8080 ];
    };

    containers.client = {
      virtualisation.vlans = [ 1 ];
      environment.systemPackages = [ pkgs.curl ];
    };

    testScript = ''
      import json

      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_open_port(8080)
      stack.wait_for_open_port(4201)
      for m in (stack, client):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")

      users = json.loads(stack.succeed("cat /run/vmauth/config.json"))["users"]
      assert users and all("access_log" in u for u in users), users

      client_ip = client.succeed(
          "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1"
      ).strip()

      client.succeed("${otlpMetric} victoria_stack_access_log_metric 1 > /tmp/otlp.bin")
      client.succeed(
          "curl -sf -H 'Authorization: Bearer write-token-one' "  # gitleaks:allow
          "-X POST -H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://stack:8080/opentelemetry/v1/metrics'"
      )
      journal = stack.succeed("journalctl -u vmauth.service --no-pager -o cat")
      lines = [l for l in journal.splitlines() if client_ip in l and "opentelemetry/v1/metrics" in l]
      assert lines, f"no access-log line for the successful write from {client_ip}:\n{journal}"
    '';
  };

  # The anonymous write door must stay closed whenever requireAuthForWrites is
  # true (the default), on the internal listener AND the public http door. A
  # mutation that always rendered the unauthenticated user survived every other
  # test, because the old controls posted junk the backend rejected anyway.
  anonymous-write-door-stays-closed-when-auth-is-required = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-anonymous-write-door-closed";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          writeTokensFile = "${writeTokensFixture}";
          http.enable = true; # 0.0.0.0:8080
        };
      };
    };

    testScript = ''
      ${otlpTestPython}
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)
      machine.wait_for_open_port(8080)
      machine.wait_for_open_port(4201)

      for port in ("4204", "8080"):
          code, body = otlp_status(machine, f"http://127.0.0.1:{port}/opentelemetry/v1/metrics")
          assert code == "401" and "missing 'Authorization'" in body, (port, code, body)

      cfg = json.loads(machine.succeed("cat /run/vmauth/config.json"))
      assert "unauthorized_user" not in cfg, cfg
    '';
  };

  # acmeCertName is the one door option with no boot test (a real ACME issuance
  # is impossible in the sandbox): pin its wiring instead.
  secret-watchers-cover-exactly-the-configured-secret-files =
    pkgs.runCommand "vmauth-secret-watchers" { }
      (
        let
          watchers =
            extra:
            let
              e = evalWith {
                services.victoriaStack = lib.recursiveUpdate {
                  metrics.enable = true;
                } extra;
              };
            in
            lib.filterAttrs (n: _: lib.hasPrefix "vmauth-secret-watch-" n) e.config.systemd.paths;
          names = extra: lib.sort (a: b: a < b) (lib.attrNames (watchers extra));
          pathOf = extra: n: (watchers extra).${n}.pathConfig.PathChanged;
          all = {
            vmauth = {
              adminPasswordFile = "/run/s/admin";
              readTokensFile = "/run/s/read";
              writeTokensFile = "/run/s/write";
              https = {
                enable = true;
                certFile = "/run/s/cert";
                keyFile = "/run/s/key";
              };
            };
          };
          checks = {
            "none configured, none watched" = names { } == [ ];
            "every operator secret is watched" =
              names all == [
                "vmauth-secret-watch-admin-password"
                "vmauth-secret-watch-https-cert"
                "vmauth-secret-watch-https-key"
                "vmauth-secret-watch-read-tokens"
                "vmauth-secret-watch-write-tokens"
              ];
            "each watcher points at its own file" =
              pathOf all "vmauth-secret-watch-read-tokens" == "/run/s/read"
              && pathOf all "vmauth-secret-watch-https-key" == "/run/s/key";
            "cert files of a disabled https door are not watched" =
              names {
                vmauth.https = {
                  enable = false;
                  certFile = "/run/s/cert";
                  keyFile = "/run/s/key";
                };
              } == [ ];
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "secret watchers wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  acme-cert-name-is-wired-into-the-unit = pkgs.runCommand "vmauth-acme-cert-name-wiring" { } (
    let
      eval =
        reload:
        evalWith {
          security.acme = {
            acceptTerms = true;
            defaults.email = "test@example.invalid";
            certs."example.test" = {
              reloadServices = lib.optional reload "vmauth.service";
            };
          };
          services.victoriaStack = {
            metrics.enable = true;
            vmauth.https = {
              enable = true;
              acmeCertName = "example.test";
            };
          };
        };
      withReload = eval true;
      withoutReload = eval false;
      unit = e: e.config.systemd.services.vmauth;
      acmeWarns = e: lib.any (lib.hasInfix "reloadServices") e.config.warnings;
      checks = {
        "cert and key staged as credentials from the ACME directory" =
          lib.elem "https-cert:/var/lib/acme/example.test/fullchain.pem" (unit withReload)
          .serviceConfig.LoadCredential
          && lib.elem "https-key:/var/lib/acme/example.test/key.pem" (unit withReload)
          .serviceConfig.LoadCredential;
        "ordered after the ACME unit" = lib.elem "acme-example.test.service" (unit withReload).after;
        "pulls the ACME unit in" = lib.elem "acme-example.test.service" (unit withReload).wants;
        "warns when reloadServices lacks vmauth.service" = acmeWarns withoutReload;
        "no warning when reloadServices has vmauth.service" = !(acmeWarns withReload);
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "acmeCertName wiring broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # http.port customisation and its collision with the internal listener.
  http-door-port-customisation-reaches-the-unit = pkgs.runCommand "vmauth-http-door-port" { } (
    let
      e = evalWith {
        services.victoriaStack = {
          metrics.enable = true;
          vmauth.http = {
            enable = true;
            ipAddress = "127.0.0.1";
            port = 8085;
          };
        };
      };
      execStart = e.config.systemd.services.vmauth.serviceConfig.ExecStart;
    in
    if lib.hasInfix "-httpListenAddr=127.0.0.1:8085" execStart then
      "echo OK > $out"
    else
      throw "http.port did not reach ExecStart: ${execStart}"
  );

  # vmauth's own diagnostic pages (/health, /metrics, /flags, /debug/pprof,
  # /-/reload) used to be served on every listener, so the public write doors
  # exposed them to anyone. They now live on one loopback-only internal
  # listener (-httpInternalListenAddr) and no data listener serves them.
  builtin-pages-live-only-on-the-internal-listener = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-builtin-pages-internal-only";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          writeTokensFile = "${writeTokensFixture}";
          https = {
            enable = true;
            certFile = "${selfSignedCert}/cert.pem";
            keyFile = "${selfSignedCert}/key.pem";
          };
          http = {
            enable = true;
            ipAddress = "127.0.0.1";
          };
        };
        nginx.enable = true;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("vmauth.service")
      for port in (4204, 8443, 8080, 4208):
          machine.wait_for_open_port(port)
      machine.wait_for_unit("nginx.service")
      machine.wait_for_open_port(80)

      pages = ["/health", "/metrics", "/flags", "/debug/pprof/", "/-/reload"]

      def code(url, extra=""):
          return machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' {extra} '{url}'"
          ).strip()

      # No data listener serves any of them, with or without credentials: the
      # request is just another unrouted request there.
      data_listeners = {
          "4204": "http://127.0.0.1:4204",
          "8080": "http://127.0.0.1:8080",
          "8443": "https://127.0.0.1:8443",
      }
      for name, base in data_listeners.items():
          tls = "--cacert ${selfSignedCert}/cert.pem" if name == "8443" else ""
          for page in pages:
              anon = code(base + page, tls)
              assert anon != "200", f"{name}{page} answered 200 anonymously"
              authed = code(base + page, tls + " -u admin:admin-password-value")  # gitleaks:allow
              assert authed != "200", f"{name}{page} answered 200 for admin"

      # They are all on the internal listener (plain HTTP, loopback only).
      for page in pages:
          assert code("http://127.0.0.1:4208" + page) == "200", page
      listeners = machine.succeed("ss -Hltn")
      assert "127.0.0.1:4208" in listeners, listeners
      assert "0.0.0.0:4208" not in listeners and "*:4208" not in listeners, listeners

      # Through nginx, /victoria/metrics is an ordinary unrouted read path, not
      # vmauth's own metrics page.
      body = machine.succeed(
          "curl -s -u admin:admin-password-value 'http://127.0.0.1:80/victoria/metrics'"  # gitleaks:allow
      )
      assert "vmauth_" not in body and "go_goroutines" not in body, body[:200]
    '';
  };

  internal-listener-address-reaches-the-unit-and-collides-like-any-other =
    pkgs.runCommand "vmauth-internal-listener-eval" { }
      (
        let
          execStart =
            m:
            (evalWith {
              services.victoriaStack = {
                metrics.enable = true;
              }
              // m;
            }).config.systemd.services.vmauth.serviceConfig.ExecStart;
          failedFor =
            m:
            lib.filter (lib.hasInfix "same listenAddress") (
              map (a: a.message) (
                builtins.filter (a: !a.assertion)
                  (evalWith {
                    services.victoriaStack = {
                      metrics.enable = true;
                    }
                    // m;
                  }).config.assertions
              )
            );
          checks = {
            "default internal address" = lib.hasInfix "-httpInternalListenAddr=127.0.0.1:4208" (execStart { });
            "custom internal address" = lib.hasInfix "-httpInternalListenAddr=127.0.0.1:4299" (execStart {
              vmauth.internalListenAddress = "127.0.0.1:4299";
            });
            "colliding with a data listener is rejected" =
              failedFor { vmauth.internalListenAddress = "127.0.0.1:4204"; } != [ ];
            "the default does not collide" = failedFor { } == [ ];
            # The internal listener reads the SAME -tls array slot as listener 0, so
            # the array must stay explicit with a plain first entry.
            "TLS array keeps the internal slot plain when the https door is on" =
              lib.hasInfix "-tls=false -tls=true"
                (
                  lib.replaceStrings [ "'" ] [ "" ] (execStart {
                    vmauth.https = {
                      enable = true;
                      certFile = "/run/secrets/c.pem";
                      keyFile = "/run/secrets/k.pem";
                    };
                  })
                );
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "internal listener wiring broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # --- token validation (every message names the OPTION and entry numbers, never
  # a token value or the name of a mistyped key, which can itself be a token) ---

  empty-token-is-a-legible-error = mkBadTokensFileTest {
    name = "empty-token";
    tier = "read";
    yaml = ''
      tokens:
        - token: ""
    '';
    expectInJournal = "readTokensFile entry #1 has an empty token";
  };

  duplicate-token-within-a-file-is-a-legible-error = mkBadTokensFileTest {
    name = "duplicate-token-in-file";
    tier = "read";
    yaml = ''
      tokens:
        - token: dup-token-value
        - token: other-token-value
        - token: dup-token-value
    '';
    expectInJournal = "readTokensFile lists the same token more than once (entries #1 and #3)";
    # vmauth's own fatal for a duplicate prints the token itself.
    expectNotInJournal = "dup-token-value";
  };

  duplicate-token-across-read-and-write-files-is-a-legible-error = mkBadTokensFileTest {
    name = "duplicate-token-across-files";
    tier = "read";
    yaml = ''
      tokens:
        - token: shared-token-value
    '';
    otherYaml = ''
      tokens:
        - token: shared-token-value
    '';
    expectInJournal = "the same token is in readTokensFile (entry #1) and writeTokensFile (entry #1)";
    expectNotInJournal = "shared-token-value";
  };

  unknown-key-in-a-token-entry-is-a-legible-error = mkBadTokensFileTest {
    name = "unknown-token-key";
    tier = "read";
    # `backend` (singular) used to render as a fully UNSCOPED token.
    yaml = ''
      tokens:
        - token: some-token-value
          backend: ["metrics"]
    '';
    # (no apostrophes here: the expected text is embedded in a quoted shell command)
    expectInJournal = "readTokensFile entry #1 has an unknown key";
    expectNotInJournal = "some-token-value";
  };

  empty-admin-password-file-is-a-legible-error = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-empty-admin-password";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        # An empty file used to render an admin user with an EMPTY password
        # (`curl -u admin:` was accepted).
        vmauth.adminPasswordFile = "${pkgs.writeText "empty-admin-password" ""}";
      };
    };

    testScript = ''
      start_all()
      machine.fail("systemctl is-active vmauth.service")
      machine.succeed(
          "journalctl -u vmauth.service --no-pager | grep -qF 'adminPasswordFile is empty'"
      )
    '';
  };

  # A source guard: the render script handles every token and the admin password
  # in cleartext, so none of it may be passed as a jq argument, where any local
  # user could read /proc/<pid>/cmdline while the script runs. (The exposure
  # itself is a race with no stable runtime test; this pins the cause.)
  render-script-keeps-secrets-off-the-command-line =
    let
      script =
        (evalWith { services.victoriaStack.metrics.enable = true; })
        .config.systemd.services.vmauth.serviceConfig.ExecStartPre;
    in
    pkgs.runCommand "vmauth-render-script-no-secret-argv" { } ''
      if grep -nE -- '--arg(json)? ' ${script}; then
        echo "the render script passes data to jq as command-line arguments (visible in /proc/<pid>/cmdline)" >&2
        exit 1
      fi
      echo OK > $out
    '';

  # Scoping used to keep a WHOLE extra url_map entry if ANY of its paths matched
  # the token's prefix (so a metrics-scoped token got the logs and traces paths
  # of a multi-path entry), matched with a plain startswith (so /metricsX looked
  # like /metrics), and aborted the render on an entry with no src_paths.
  scoped-token-filters-extra-url-map-paths-individually = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-scoped-extra-url-map";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        logs.enable = true;
        vmauth = {
          readTokensFile = "${pkgs.writeText "scoped-extra-read-tokens.yaml" ''
            tokens:
              - token: scoped-extra-metrics-only
                backends: ["metrics"]
              - token: unscoped-extra-read
          ''}";
          writeTokensFile = "${pkgs.writeText "scoped-extra-write-tokens.yaml" ''
            tokens:
              - token: scoped-extra-write-metrics-only
                backends: ["metrics"]
              - token: unscoped-extra-write
          ''}";
          extraReadUrlMap = [
            {
              # One entry, paths under two different backends.
              src_paths = [
                "/metrics/api/v1/status/tsdb"
                "/logs/select/extra"
              ];
              url_prefix = "http://127.0.0.1:4201/";
            }
            {
              # Merely STARTS with a backend prefix.
              src_paths = [ "/metricsX/foo" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
          extraWriteUrlMap = [
            {
              src_paths = [
                "/opentelemetry/extra"
                "/insert/journald/extra"
              ];
              url_prefix = "http://127.0.0.1:4201/";
            }
            {
              src_paths = [ "/opentelemetryX/foo" ];
              url_prefix = "http://127.0.0.1:4201/";
            }
          ];
        };
      };
    };

    testScript = ''
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      users = {u["bearer_token"]: u["url_map"] for u in json.loads(machine.succeed("cat /run/vmauth/config.json"))["users"]}

      def paths(token):
          return [p for e in users[token] for p in e.get("src_paths", [])]

      # Scoped read token: only its own backend's path of the multi-path entry,
      # as an entry holding ONLY that path; none of the look-alikes.
      scoped = paths("scoped-extra-metrics-only")
      assert "/metrics/api/v1/status/tsdb" in scoped, scoped
      for leaked in ("/logs/select/extra", "/metricsX/foo"):
          assert leaked not in scoped, (leaked, scoped)
      assert not any("src_paths" not in e for e in users["scoped-extra-metrics-only"]), users["scoped-extra-metrics-only"]
      assert all(len(e["src_paths"]) == 1 for e in users["scoped-extra-metrics-only"] if "tsdb" in e["src_paths"][0]), users["scoped-extra-metrics-only"]

      # Unscoped token: the full map, extra entries byte-for-byte intact.
      full = users["unscoped-extra-read"]
      def has(entries, src_paths):
          return any(e["src_paths"] == src_paths and e["url_prefix"] == "http://127.0.0.1:4201/" for e in entries)

      assert has(full, ["/metrics/api/v1/status/tsdb", "/logs/select/extra"]), full
      assert len(full) > len(users["scoped-extra-metrics-only"])

      # Same for the write tier.
      wscoped = paths("scoped-extra-write-metrics-only")
      assert "/opentelemetry/extra" in wscoped, wscoped
      for leaked in ("/insert/journald/extra", "/opentelemetryX/foo"):
          assert leaked not in wscoped, (leaked, wscoped)
      assert has(users["unscoped-extra-write"], ["/opentelemetry/extra", "/insert/journald/extra"])
    '';
  };

  # An extra entry with no src_paths is rejected by vmauth itself for any user
  # that receives it, but a scoped token has nothing to match it against and
  # must simply not get it (it used to abort the whole render with a jq error).
  scoped-token-ignores-extra-entries-without-src-paths = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-scoped-no-src-paths";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          readTokensFile = "${pkgs.writeText "scoped-only-read-tokens.yaml" ''
            tokens:
              - token: scoped-only-metrics
                backends: ["metrics"]
          ''}";
          extraReadUrlMap = [ { url_prefix = "http://127.0.0.1:4201/"; } ];
        };
      };
    };

    testScript = ''
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      users = json.loads(machine.succeed("cat /run/vmauth/config.json"))["users"]
      assert len(users) == 1 and all("src_paths" in e for e in users[0]["url_map"]), users
    '';
  };

  # --- the caller's credential is not forwarded to backends ---
  #
  # vmauth proxies the Authorization header onward by default (its docs say so, and
  # how to strip it: an empty `Authorization:` in `headers`). The built-in backends
  # sit on loopback and ignore it, but an extra route to another host would receive
  # every token and admin password that passes through it.

  authorization-is-stripped-on-every-module-built-route =
    pkgs.runCommand "vmauth-authorization-stripped" { }
      (
        let
          evaluated = evalWith {
            services.victoriaStack = {
              metrics = {
                enable = true;
                mcp.enable = true;
              };
              logs.enable = true;
              traces.enable = true;
              vmauth.extraRequestHeaders = [ "X-Test: 1" ];
            };
          };
          files = [
            "READ_URL_MAP_FILE"
            "WRITE_URL_MAP_FILE"
            "OPEN_INGEST_PATHS_FILE"
          ];
          strips =
            file: lib.all (e: lib.head (e.headers or [ "" ]) == "Authorization:") (urlMapFile file evaluated);
          checks = lib.genAttrs files (f: urlMapFile f evaluated != [ ] && strips f) // {
            "the operator's own headers follow the strip" = lib.all (
              e:
              e.headers == [
                "Authorization:"
                "X-Test: 1"
              ]
            ) (urlMapFile "READ_URL_MAP_FILE" evaluated);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "Authorization is not stripped everywhere: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # For real: a tiny backend that echoes the headers it receives sits behind two
  # extra routes; the caller's Authorization must not arrive, and a header the
  # operator sets on an entry still wins.
  authorization-does-not-reach-an-extra-route-backend = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-authorization-not-forwarded";

    containers.machine = {
      imports = [ module ];

      systemd.services.echo-headers = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = lib.getExe (
          pkgs.writers.writePython3Bin "echo-headers" { flakeIgnore = [ "E501" ]; } ''
            import json
            from http.server import BaseHTTPRequestHandler, HTTPServer


            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    body = json.dumps({k.lower(): v for k, v in self.headers.items()}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *args):
                    pass


            HTTPServer(("127.0.0.1", 4299), Handler).serve_forever()
          ''
        );
      };

      services.victoriaStack = {
        metrics.enable = true;
        vmauth = {
          adminPasswordFile = "${adminPasswordFixture}";
          extraReadUrlMap = [
            {
              src_paths = [ "/echo" ];
              url_prefix = "http://127.0.0.1:4299/";
            }
            {
              src_paths = [ "/echo-entry" ];
              url_prefix = "http://127.0.0.1:4299/";
              headers = [ "Authorization: Bearer from-the-entry" ];
            }
          ];
        };
      };
    };

    testScript = ''
      import json

      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_unit("echo-headers.service")
      machine.wait_for_open_port(4299)
      machine.wait_for_open_port(4204)

      def echoed(path):
          return json.loads(
              machine.succeed(f"curl -sf -u admin:admin-password-value 'http://127.0.0.1:4204{path}'")  # gitleaks:allow
          )

      plain = echoed("/echo")
      assert "authorization" not in plain, plain

      overridden = echoed("/echo-entry")
      assert overridden.get("authorization") == "Bearer from-the-entry", overridden
    '';
  };

  # The "matches every path" warning for the extra url maps recognised only a
  # literal `.*` first; these spellings route everything just as well.
  extra-url-map-match-everything-variants-warn =
    pkgs.runCommand "vmauth-match-everything-variants" { }
      (
        let
          warnsFor =
            option: path:
            lib.any (lib.hasInfix "matches every path") (
              (evalWith {
                services.victoriaStack = {
                  metrics.enable = true;
                  vmauth.${option} = [
                    {
                      src_paths = [ path ];
                      url_prefix = "http://127.0.0.1:4201/";
                    }
                  ];
                };
              }).config.warnings
            );
          broad = [
            ".*"
            "/.*"
            ".+"
            "/.+"
            "/(.*)"
            "/(?:.*)"
            "^/.*"
            "(.*)"
          ];
          narrow = [
            "/metrics/.*"
            "/foo(.*)"
            "/x.+"
            "/custom-route"
          ];
          checks = lib.listToAttrs (
            lib.concatMap
              (
                option:
                map (p: lib.nameValuePair "${option} warns for ${p}" (warnsFor option p)) broad
                ++ map (p: lib.nameValuePair "${option} does NOT warn for ${p}" (!(warnsFor option p))) narrow
              )
              [
                "extraReadUrlMap"
                "extraWriteUrlMap"
              ]
          );
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "match-everything warning wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # vmauth.extraFlags is escaped like the storage services' extraFlags: one list
  # element is exactly one argument (it used to be a plain space-join, so
  # "-x=a b" became two arguments).
  vmauth-extra-flags-stay-one-argument-each = pkgs.runCommand "vmauth-extra-flags-escaping" { } (
    let
      execStart =
        m:
        (evalWith {
          services.victoriaStack = {
            metrics.enable = true;
          }
          // m;
        }).config.systemd.services.vmauth.serviceConfig.ExecStart;
      withSpaces = execStart { vmauth.extraFlags = [ "-x=a b" ]; };
      checks = {
        "a value with a space stays one quoted argument" = lib.hasInfix "'-x=a b'" withSpaces;
        # The credential specifier must still reach systemd intact.
        "the https door's %d credential flags survive" = lib.hasInfix "%d/https-cert" (execStart {
          vmauth.https = {
            enable = true;
            certFile = "/run/secrets/c.pem";
            keyFile = "/run/secrets/k.pem";
          };
        });
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "vmauth extraFlags escaping wrong: ${builtins.toJSON (builtins.attrNames failed)}\n${withSpaces}"
  );

  # vmauth.idleConnTimeout is mirrored into nginx's proxy_*_timeout (ADR 0016), so
  # it must be a form BOTH accept: nginx rejects Go-style fractions like 1.5m.
  idle-conn-timeout-accepts-only-forms-nginx-also-understands =
    let
      t = (evalWith { }).options.services.victoriaStack.vmauth.idleConnTimeout.type;
    in
    pkgs.runCommand "idle-conn-timeout-format" { } (
      let
        checks = {
          "30s" = t.check "30s";
          "5m" = t.check "5m";
          "1h" = t.check "1h";
          "1.5m rejected" = !(t.check "1.5m");
          "a bare number rejected (unit ambiguity)" = !(t.check "300");
          "garbage rejected" = !(t.check "five minutes");
        };
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "idleConnTimeout format wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );
}
