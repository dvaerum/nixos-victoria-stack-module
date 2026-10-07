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
      backends ? {
        metrics.enable = true;
      },
    }:
    pkgs.testers.nixosTest {
      name = "victoria-stack-vmauth-${name}";

      containers.machine = {
        imports = [ module ];
        services.victoriaStack = backends // {
          vmauth."${tier}TokensFile" = "${pkgs.writeText "bad-${tier}-tokens.yaml" yaml}";
        };
      };

      testScript = ''
        start_all()
        machine.fail("systemctl is-active vmauth.service")
        machine.succeed(
            "journalctl -u vmauth.service --no-pager | grep -qF ${lib.escapeShellArg expectInJournal}"
        )
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
            e: (e.headers or [ ]) == [ "TenantID: foobar" ] && (e.response_headers or [ ]) == [ "Server:" ]
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
      machine.wait_for_open_port(4201)

      # No credential: the write path must now reject the request (default
      # requireAuthForWrites = true).
      machine.fail(
          "curl -sf -X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"
      )

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
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      machine.fail(
          "curl -sf -H 'Authorization: Bearer read-token-one' "  # gitleaks:allow
          "-X POST --data-binary 'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
      )
      machine.fail(
          "curl -sf -u admin:admin-password-value "
          "-X POST --data-binary 'victoria_stack_vmauth_test_metric 1' "
          "'http://127.0.0.1:4204/opentelemetry'"
      )

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
      machine.fail(
          "curl -sf -u admin:admin-password-value "  # gitleaks:allow
          "-X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"
      )
      machine.fail(
          "curl -sf -H 'Authorization: Bearer read-token-one' "
          "-X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"
      )
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
      start_all()
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      machine.fail(
          "curl -sf -X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"  # gitleaks:allow
      )
      # Confirms there is no credential of any form (correctly-shaped or
      # not) that could open the write path in this state.
      machine.fail(
          "curl -sf -H 'Authorization: Bearer anything-at-all' "
          "-X POST --data-binary 'x 1' 'http://127.0.0.1:4204/opentelemetry'"
      )
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
          "| grep -q \"read-tokens must contain a top-level 'tokens:' key\""
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
          "| grep -q \"write-tokens must contain a top-level 'tokens:' key\""
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
            "flags present verbatim" = lib.hasInfix "-tlsCertFile=/foo -tlsKeyFile=/bar" set;
            "flags are last" = lib.hasSuffix "-tlsCertFile=/foo -tlsKeyFile=/bar" set;
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
            "module-wide headers apply" = written != null && written.headers == [ "X-Extra-Write: yes" ];
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
      for path in ["/metrics/api/v1/labels", "/logs/select/logsql/query?query=*"]:
          c = code(scoped, path)
          assert c in ("400", "401", "403"), f"scoped token reached {path}: {c}"
      for path in ["/mcp/metrics", "/mcp/logs"]:
          c = code(scoped, path, init)
          assert c in ("400", "401", "403"), f"scoped token reached {path}: {c}"

      # An unscoped token still reaches everything (backward compatible).
      assert code(unscoped, "/metrics/api/v1/labels") == "200"
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
}
