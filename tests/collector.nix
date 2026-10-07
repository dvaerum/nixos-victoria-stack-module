{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  stackModule = nixosModule.nixosModules.victoriaStack;
  collectorModule = nixosModule.nixosModules.victoriaCollector;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  # Shared with every other test group (Phase 30 unification) -- this
  # file used to roll its own near-identical ad-hoc eval harness here,
  # confirmed real drift from tests/lib.nix's victoriaStack-only
  # evalWith, not hypothetical.
  inherit (testLib) evalWithCollector;

  writeTokensFixture = pkgs.writeText "collector-test-write-tokens.yaml" ''
    tokens:
      - token: collector-test-write-token # test fixture, not real
  '';

  # Own messages only -- the raw list also carries unrelated base-NixOS
  # assertions (root fs, bootloader) the bare eval harness never satisfies.
  ownFailed =
    evaluated:
    lib.filter (lib.hasInfix "services.victoriaCollector") (
      map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
    );

  writeTokenFixture = pkgs.writeText "collector-test-write-token" "collector-test-write-token";

  # Pure eval, no container boot needed: confirms the https:// branch of
  # journaldWriteEndpoint actually renders the client-cert-disabling + CA-bundle
  # settings it's supposed to -- the one branch with no prior coverage
  # at all (the roundtrip test above only ever uses a plain http://
  # writeEndpoint).
  # Fixtures for the cross-container tests below (the older tests in this
  # file inline the equivalent).
  twoWriteTokensFixture = pkgs.writeText "collector-test-two-write-tokens.yaml" ''
    tokens:
      - token: collector-test-write-token-a # test fixture, not real
      - token: collector-test-write-token-b # test fixture, not real
  '';
  writeTokenAFixture = pkgs.writeText "collector-test-write-token-a" "collector-test-write-token-a";
  writeTokenBFixture = pkgs.writeText "collector-test-write-token-b" "collector-test-write-token-b";

  # SAN for the container hostname "stack": Alloy verifies the gateway's
  # certificate against this CA, so the name must match what the collector
  # dials (same lesson as tests/nginx.nix's selfSignedCert -- without a
  # SAN, verification fails closed).
  stackSelfSignedCert =
    pkgs.runCommand "collector-test-stack-self-signed-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
          -subj "/CN=stack" -addext "subjectAltName=DNS:stack" \
          -keyout $out/key.pem -out $out/cert.pem
      '';

  # The stack side every new cross-container test needs: a gateway
  # reachable from the other containers, accepting the write tokens above.
  mkStackContainer =
    {
      services,
      tokensFile ? writeTokensFixture,
      extra ? { },
    }:
    {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = services // {
        vmauth = {
          writeTokensFile = "${tokensFile}";
          listenAddress = "0.0.0.0:4204";
        };
      };
      networking.firewall.allowedTCPPorts = [ 4204 ];
    }
    // extra;

  httpsEvaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit (pkgs) system;
    modules = [
      collectorModule
      {
        system.stateVersion = lib.trivial.release;
        services.victoriaCollector = {
          logs.enable = true;
          journaldWriteEndpoint = "https://victoria-stack.example.invalid:4204";
          hostType = "server";
        };
      }
    ];
  };
in
{
  # The one genuinely novel integration risk this whole project called
  # out explicitly: two separate containers, one shipping real telemetry
  # over the network to the other's vmauth gateway, end to end. Verified
  # for real here -- not assumed to work just because nixpkgs' own
  # containers.nix framework self-test proves container<->container
  # networking in the abstract (docs/decisions/0004).
  metrics-roundtrip-across-containers = pkgs.testers.nixosTest {
    name = "victoria-collector-metrics-roundtrip-across-containers";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        # vmauth's listenAddress defaults to loopback-only (a deliberate
        # security default, docs/architecture.md) -- a genuinely remote
        # collector (this test's whole point: two separate containers)
        # can never reach a loopback-bound vmauth at all, confirmed
        # directly: without this, every export attempt timed out with
        # "context deadline exceeded" even though ICMP/hostname
        # resolution across the vlan worked fine (ping succeeded).
        vmauth.listenAddress = "0.0.0.0:4204";
      };
      # This module never opens any firewall port itself (deliberately
      # infrastructure-agnostic, same reasoning as having no ACME/TLS
      # opinion) -- a real remote-collector deployment needs the
      # operator to open this themselves, so the test needs to too.
      # Confirmed directly: listenAddress alone wasn't enough: still
      # "context deadline exceeded" with 0.0.0.0:4204 and the default
      # firewall still active.
      networking.firewall.allowedTCPPorts = [ 4204 ];
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      collector.wait_for_unit("alloy.service")

      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")

      # Confirm basic reachability first (same pattern nixpkgs' own
      # framework self-test uses: hostname-based ping across containers
      # sharing a vlan).
      collector.succeed("ping -c 1 stack")

      # Alloy's own host-metrics scrape + OTLP export happens on its own
      # schedule (batch processor default interval) -- wait for the
      # collector's own host metric to actually arrive and become
      # queryable on the stack side, rather than assuming a fixed sleep
      # is enough. Queried directly against victoriametrics' own loopback
      # port (no credential needed there -- only vmauth gates access,
      # confirmed already in the vmauth test group; the metric reaching
      # the backend AT ALL through vmauth's authenticated write path is
      # the actual thing this test cares about).
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=alloy_up' | grep -q '\"value\"'",
          timeout=120,
      )
    '';
  };

  # Same cross-container shape as metrics-roundtrip-across-containers,
  # for logs -- systemd-journal-upload (not Alloy) is the real client
  # here, carrying the write token via its own Header= drop-in
  # (config.nix), shipping the native systemd journal export wire
  # format, not jsonline/OTLP.
  logs-roundtrip-across-containers = pkgs.testers.nixosTest {
    name = "victoria-collector-logs-roundtrip-across-containers";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = {
        logs.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        vmauth.listenAddress = "0.0.0.0:4204";
      };
      networking.firewall.allowedTCPPorts = [ 4204 ];
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        logs.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("victorialogs.service")
      collector.wait_for_unit("systemd-journal-upload.service")

      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")

      collector.succeed("ping -c 1 stack")

      # A distinctive marker message, shipped through the real journal
      # (not synthesized at the HTTP layer) -- confirms the whole real
      # path: logger -> journald -> systemd-journal-upload (carrying the
      # write token) -> vmauth -> victorialogs.
      collector.succeed(
          "logger --tag victoria-collector-test 'victoria_stack_collector_logs_roundtrip_marker'"
      )
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' "
          "-d 'query=victoria_stack_collector_logs_roundtrip_marker' "
          "| grep -q victoria_stack_collector_logs_roundtrip_marker",
          timeout=120,
      )
    '';
  };

  # Same cross-container shape again, for traces -- Alloy's own local
  # OTLP receiver (config.alloy.nix, tied to traces.enable) is the real
  # ingress here: a real OTLP/HTTP payload sent to the collector's own
  # receiver port, forwarded by Alloy's configured exporter (carrying the
  # write token) to the stack's vmauth, landing in victoriatraces.
  traces-roundtrip-across-containers = pkgs.testers.nixosTest {
    name = "victoria-collector-traces-roundtrip-across-containers";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = {
        traces.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        vmauth.listenAddress = "0.0.0.0:4204";
      };
      networking.firewall.allowedTCPPorts = [ 4204 ];
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        traces.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("victoriatraces.service")
      collector.wait_for_unit("alloy.service")
      collector.wait_for_open_port(4318)

      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")

      collector.succeed("ping -c 1 stack")

      collector.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_collector_traces_roundtrip_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000004\","
          "\"spanId\":\"0000000000000004\","
          "\"name\":\"victoria_stack_collector_traces_roundtrip_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4318/v1/traces'"
      )
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_collector_traces_roundtrip_service",
          timeout=120,
      )
    '';
  };

  per-signal-toggles-independent = pkgs.testers.nixosTest {
    name = "victoria-collector-per-signal-toggles-independent";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        logs.enable = true;
        # metrics/traces deliberately left disabled.
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("systemd-journal-upload.service")
      # Alloy itself must not even be enabled when only logs is on --
      # confirmed via needsAlloyOtlp = metrics.enable || traces.enable in
      # config.nix.
      collector.fail("systemctl status alloy.service")
    '';
  };

  # needsAlloyOtlp is an OR across metrics/traces -- the check above only
  # exercises the "both off" side. This confirms traces alone is
  # sufficient on its own (not just in combination with metrics, as
  # metrics-roundtrip-across-containers happens to test).
  traces-alone-enables-alloy = pkgs.testers.nixosTest {
    name = "victoria-collector-traces-alone-enables-alloy";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        traces.enable = true;
        # metrics/logs deliberately left disabled.
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      config_text = collector.succeed("cat /etc/alloy/config.alloy")
      assert "otlp" in config_text
      assert "traces" in config_text
    '';
  };

  journal-upload-https-disables-client-cert =
    pkgs.runCommand "journal-upload-https-disables-client-cert" { }
      (
        let
          upload = httpsEvaluated.config.services.journald.upload.settings.Upload;
          checks = [
            (upload.ServerKeyFile == "-")
            (upload.ServerCertificateFile == "-")
            # The CA bundle reaches the DynamicUser unit as a credential,
            # not as a path whose ownership/permissions matter.
            (upload.TrustedCertificateFile == "/run/credentials/systemd-journal-upload.service/trusted-ca")
            (lib.elem "trusted-ca:/etc/ssl/certs/ca-certificates.crt" httpsEvaluated.config.systemd.services.systemd-journal-upload.serviceConfig.LoadCredential)
            (upload.URL == "https://victoria-stack.example.invalid:4204/insert/journald")
          ];
        in
        if builtins.all (x: x) checks then
          "echo OK > $out"
        else
          throw "journal-upload https:// branch did not render the expected settings: ${builtins.toJSON upload}"
      );

  # hostType is only needed where an Alloy pipeline exists to attach the
  # label (metrics/traces) -- logs-only must evaluate with it omitted.
  hostType-may-be-omitted-for-logs-only =
    pkgs.runCommand "hostType-may-be-omitted-for-logs-only" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              logs.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              writeTokenFile = "${writeTokenFixture}";
            };
          };
          failed = ownFailed evaluated;
          # Forcing the unit set proves the module's config evaluates with
          # hostType unset (the toplevel itself can't be forced: the bare
          # harness never satisfies base-NixOS root-fs/bootloader asserts).
          units = builtins.attrNames evaluated.config.systemd.services;
        in
        if failed == [ ] && units != [ ] then
          "echo OK > $out"
        else
          throw "logs-only collector without hostType should evaluate cleanly, got: ${builtins.toJSON failed}"
      );

  hostType-required-assertion-fires-for-metrics-and-traces =
    pkgs.runCommand "hostType-required-assertion-fires" { }
      (
        let
          failedFor =
            signal:
            ownFailed (evalWithCollector {
              services.victoriaCollector = {
                ${signal}.enable = true;
                writeEndpoint = "http://127.0.0.1:4204";
                writeTokenFile = "${writeTokenFixture}";
              };
            });
          fires =
            signal: lib.any (lib.hasInfix "services.victoriaCollector.hostType is required") (failedFor signal);
        in
        if fires "metrics" && fires "traces" then
          "echo OK > $out"
        else
          throw "expected the hostType-required assertion for metrics and traces; metrics=${builtins.toJSON (failedFor "metrics")} traces=${builtins.toJSON (failedFor "traces")}"
      );

  hostType-rejects-a-value-that-would-break-generated-alloy-syntax =
    pkgs.runCommand "hostType-rejects-unsafe-characters" { }
      (
        let
          hostTypeType = httpsEvaluated.options.services.victoriaCollector.hostType.type;
          # A double-quote would break out of the generated Alloy string
          # literal (value = "${cfg.hostType}") -- confirmed as the real,
          # reproduced injection bug in docs/decisions/0020. A plain
          # alphanumeric-ish value must still be accepted.
          rejectsUnsafe = !(hostTypeType.check ''rack-1"infra'');
          acceptsSafe = hostTypeType.check "server";
        in
        if rejectsUnsafe && acceptsSafe then
          "echo OK > $out"
        else
          throw ''
            hostType must reject values containing characters that break
            generated Alloy syntax (e.g. a double-quote) while still
            accepting ordinary labels. rejectsUnsafe=${builtins.toJSON rejectsUnsafe}
            acceptsSafe=${builtins.toJSON acceptsSafe}
          ''
      );

  hostType-attribute-applies-to-traces-not-only-metrics =
    pkgs.runCommand "hostType-applies-to-traces" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              traces.enable = true;
              # metrics/logs deliberately left disabled -- isolates the
              # traces-only rendering path.
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          configText = evaluated.config.environment.etc."alloy/config.alloy".text;
        in
        if lib.hasInfix ''key    = "host_type"'' configText then
          "echo OK > $out"
        else
          throw ''
            hostType's own option doc promises a fleet-identification label
            that isn't scoped to metrics only -- but the traces-only
            rendered Alloy config has no host_type attribute anywhere.
          ''
      );

  # hostType's own option doc is explicit that this is NOT applied to
  # logs (intentional design -- that path goes through
  # systemd-journal-upload directly, with no Alloy pipeline to attach the
  # label in, confirmed in config.nix's renderJournalUploadTokenHeader:
  # the only thing it ever renders is the Authorization bearer token).
  # This was previously an undocumented-but-believed fact with no
  # regression test; confirms it directly, both that no Alloy config is
  # even rendered for a logs-only host (needsAlloyOtlp = metrics.enable
  # || traces.enable, config.nix) and that hostType has no other
  # mechanism to reach logs at all.
  hostType-is-genuinely-absent-for-logs-only =
    pkgs.runCommand "hostType-is-genuinely-absent-for-logs-only" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              logs.enable = true;
              # metrics/traces deliberately left disabled.
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          hasAlloyConfig = evaluated.config.environment.etc ? "alloy/config.alloy";
        in
        if !hasAlloyConfig then
          "echo OK > $out"
        else
          throw ''
            Expected no Alloy config to be rendered at all for a
            logs-only host (needsAlloyOtlp = metrics.enable ||
            traces.enable) -- hostType has no mechanism to reach logs,
            by design, so there should be nothing here for it to have
            reached.
          ''
      );

  alloy-tls-and-retry-options-are-inert-unless-configured =
    pkgs.runCommand "alloy-tls-and-retry-inert-unless-configured" { }
      (
        let
          unset = evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              traces.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          set = evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              traces.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
              alloy = {
                tlsCaFile = ./lib.nix; # in-repo fixture, content irrelevant
                tlsInsecureSkipVerify = true;
                retryOnFailure = {
                  initialInterval = "1s";
                  maxInterval = "10s";
                  maxElapsedTime = "1m";
                };
              };
            };
          };
          textUnset = unset.config.environment.etc."alloy/config.alloy".text;
          textSet = set.config.environment.etc."alloy/config.alloy".text;
          # How many of the 2 exporters (metrics + traces) actually got the
          # block -- counts occurrences rather than guessing exact
          # whitespace/formatting.
          countOccurrences = needle: haystack: (lib.length (lib.splitString needle haystack)) - 1;
          checks = {
            "no tls block when unset" = !(lib.hasInfix "tls {" textUnset);
            # Retrying forever is now the default (the disk queue is what bounds
            # data held during an outage), so the block exists with ONLY that.
            "unset: retry block holds only max_elapsed_time = 0s" =
              lib.hasInfix "retry_on_failure {" textUnset
              && lib.hasInfix ''max_elapsed_time = "0s"'' textUnset
              && !(lib.hasInfix "initial_interval" textUnset)
              && !(lib.hasInfix "max_interval" textUnset);
            "insecure_skip_verify set on both exporters" =
              countOccurrences "insecure_skip_verify = true" textSet == 2;
            "ca_file set on both exporters" = countOccurrences "ca_file" textSet == 2;
            "ca_file points at alloy's credential, not the original path" =
              lib.hasInfix "/run/credentials/alloy.service/tls-ca" textSet && !(lib.hasInfix "lib.nix" textSet);
            "tlsCaFile staged via LoadCredential on alloy.service" = lib.any (lib.hasPrefix "tls-ca:") (
              set.config.systemd.services.alloy.serviceConfig.LoadCredential or [ ]
            );
            "no alloy credential when tlsCaFile is unset" =
              !(lib.any (lib.hasPrefix "tls-ca:") (
                unset.config.systemd.services.alloy.serviceConfig.LoadCredential or [ ]
              ));
            "initial_interval set on both exporters" =
              countOccurrences ''initial_interval = "1s"'' textSet == 2;
            "max_interval set on both exporters" = countOccurrences ''max_interval = "10s"'' textSet == 2;
            "max_elapsed_time set on both exporters" =
              countOccurrences ''max_elapsed_time = "1m"'' textSet == 2;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "alloy tls/retry_on_failure options broken: ${builtins.toJSON (builtins.attrNames failed)}\n${textSet}"
      );

  queue-directory-outside-statedir-gets-readwritepaths =
    pkgs.runCommand "queue-directory-outside-statedir-gets-readwritepaths" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
              queue.directory = "/mnt/bigdisk/alloy-queue";
            };
          };
          rwp = evaluated.config.systemd.services.alloy.serviceConfig.ReadWritePaths or [ ];
        in
        if lib.elem "/mnt/bigdisk/alloy-queue" rwp then
          "echo OK > $out"
        else
          throw ''
            queue.directory set outside alloy's own StateDirectory
            (/var/lib/alloy) must be added to ReadWritePaths -- DynamicUser
            implies ProtectSystem=strict, which blocks writes anywhere not
            explicitly allow-listed. ReadWritePaths was: ${builtins.toJSON rwp}
          ''
      );

  alloy-write-token-oneshot-does-not-run-as-root =
    pkgs.runCommand "alloy-write-token-oneshot-does-not-run-as-root" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
              writeTokenFile = "${writeTokenFixture}";
            };
          };
          sc = evaluated.config.systemd.services.victoria-collector-alloy-write-token.serviceConfig;
        in
        if (sc.DynamicUser or false) == true then
          "echo OK > $out"
        else
          throw ''
            victoria-collector-alloy-write-token must run under its own
            DynamicUser, not root -- EnvironmentFile= is read by the
            service manager itself (systemd.exec(5)), not the target
            process, so file ownership is irrelevant to alloy.service's
            own EnvironmentFile= resolution. Unlike journal-upload's
            oneshot (which genuinely needs root -- /run/systemd is
            755 root:root), this one has no such requirement.
          ''
      );

  write-token-file-is-a-plain-string-not-a-nix-path =
    pkgs.runCommand "collector-write-token-file-is-a-plain-string" { }
      (
        let
          # Same bug class as vmauth's adminPasswordFile/readTokensFile/
          # writeTokensFile (tests/vmauth.nix) -- the identical
          # LoadCredential="write-token:${cfg.writeTokenFile}" interpolation
          # shape exists twice in config.nix (alloy's oneshot and
          # journal-upload's oneshot). See docs/decisions/0020.
          actualType =
            httpsEvaluated.options.services.victoriaCollector.writeTokenFile.type.nestedTypes.elemType.name;
        in
        if actualType == "str" then
          "echo OK > $out"
        else
          throw ''
            victoriaCollector.writeTokenFile must be types.str, not
            types.path (actual type: ${actualType}) -- same eval-crash/
            Nix-store-secret-leak risk as vmauth's equivalent options.
          ''
      );

  # Unlike the alloy write-token oneshot (whose failure is self-enforcing
  # via a required EnvironmentFile=, confirmed via systemd.exec(5)), the
  # journal-upload token oneshot renders a config drop-in directory,
  # which systemd treats as optional -- without an explicit `requires`,
  # systemd-journal-upload.service would start anyway on a failed render,
  # silently uploading unauthenticated. Found during Round 2 review.
  journal-upload-service-requires-its-token-render-oneshot =
    pkgs.runCommand "journal-upload-service-requires-its-token-render-oneshot" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              logs.enable = true;
              writeTokenFile = "${writeTokenFixture}";
              hostType = "server";
            };
          };
          requires = evaluated.config.systemd.services.systemd-journal-upload.requires or [ ];
        in
        if lib.elem "victoria-collector-journal-upload-token.service" requires then
          "echo OK > $out"
        else
          throw ''
            systemd-journal-upload.service must `requires` its own
            token-render oneshot -- a drop-in config directory under
            /run/systemd/<unit>.conf.d/ is optional to systemd (unlike a
            required EnvironmentFile=), so a failed render would
            otherwise let the consuming unit start anyway, silently
            uploading unauthenticated.
          ''
      );

  queue-option-takes-effect = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-option";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
        queue = {
          maxSizeBytes = 123456789;
          directory = "/var/lib/alloy/custom-queue";
        };
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      config_text = collector.succeed("cat /etc/alloy/config.alloy")
      assert "123456789" in config_text
      assert "/var/lib/alloy/custom-queue" in config_text
    '';
  };

  # The test above only ever set both queue options together -- never
  # confirmed either is independently inert/effective on its own (the
  # other staying at its documented default), nor that the option
  # actually reaches the traces exporter's own sending_queue block (a
  # second, separate occurrence in config.alloy.nix -- the metrics
  # exporter and traces exporter each render their own).
  queue-max-size-bytes-alone-takes-effect = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-max-size-bytes-alone";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
        queue.maxSizeBytes = 999999999;
        # queue.directory left at its default.
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      config_text = collector.succeed("cat /etc/alloy/config.alloy")
      assert "999999999" in config_text
      assert "/var/lib/alloy/queue" in config_text, (
          "expected queue.directory's default to still render when only "
          "maxSizeBytes is overridden"
      )
    '';
  };

  queue-directory-alone-takes-effect = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-directory-alone";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
        queue.directory = "/var/lib/alloy/directory-only-queue";
        # queue.maxSizeBytes left at its default (1GiB).
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      config_text = collector.succeed("cat /etc/alloy/config.alloy")
      assert "/var/lib/alloy/directory-only-queue" in config_text
      assert "1073741824" in config_text, (
          "expected queue.maxSizeBytes's default (1GiB) to still render "
          "when only directory is overridden"
      )
    '';
  };

  queue-option-applies-to-traces-exporter-too = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-option-traces-exporter";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        traces.enable = true;
        writeEndpoint = "http://127.0.0.1:4204";
        hostType = "server";
        queue.maxSizeBytes = 555555555;
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      config_text = collector.succeed("cat /etc/alloy/config.alloy")
      # Both exporters render their own sending_queue block from the same
      # cfg.queue.maxSizeBytes -- with only traces enabled, this confirms
      # the traces exporter's own occurrence picks it up too, not just
      # the metrics one exercised by the tests above.
      assert config_text.count("555555555") >= 1, (
          "expected the traces exporter's sending_queue to render the "
          "overridden queue.maxSizeBytes"
      )
      assert 'otelcol.exporter.otlphttp "traces"' in config_text
    '';
  };

  # Phase 40: same-host ordering fix -- both services that export to a
  # (possibly co-located) vmauth gateway now carry after/wants on it.
  # A plain unit name is a safe no-op on a collector-only host where
  # vmauth.service doesn't exist at all (confirmed empirically: systemd
  # silently ignores an After=/Wants= target with no matching unit).
  journal-upload-and-alloy-order-after-vmauth =
    pkgs.runCommand "journal-upload-and-alloy-order-after-vmauth" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              logs.enable = true;
              metrics.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          journalUpload = evaluated.config.systemd.services.systemd-journal-upload;
          alloy = evaluated.config.systemd.services.alloy;
          checks = {
            "journal-upload after vmauth" = lib.elem "vmauth.service" journalUpload.after;
            "journal-upload wants vmauth" = lib.elem "vmauth.service" journalUpload.wants;
            "alloy after vmauth" = lib.elem "vmauth.service" alloy.after;
            "alloy wants vmauth" = lib.elem "vmauth.service" alloy.wants;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "missing same-host ordering: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Phase 40: cross-host fix -- a collector with an intermittent network
  # (e.g. a laptop) must retry systemd-journal-upload forever, never hit
  # a permanent start-limit stop requiring a manual `systemctl
  # reset-failed`. startLimitIntervalSec = 0 disables that ceiling
  # entirely (systemd.service(5)).
  journal-upload-start-limit-disabled = pkgs.runCommand "journal-upload-start-limit-disabled" { } (
    let
      evaluated = evalWithCollector {
        services.victoriaCollector = {
          logs.enable = true;
          writeEndpoint = "http://127.0.0.1:4204";
          hostType = "server";
        };
      };
      startLimit = evaluated.config.systemd.services.systemd-journal-upload.startLimitIntervalSec;
    in
    if startLimit == 0 then
      "echo OK > $out"
    else
      throw "expected systemd-journal-upload.service's startLimitIntervalSec to be 0 (disabled), got ${toString startLimit}"
  );

  # Phase 43 fresh-agent review finding: an explicit restartTriggers on
  # alloy.service, set to the SAME content nixpkgs' own alloy module
  # already tracks via its own reloadTriggers (nixos/modules/services/
  # monitoring/alloy.nix, wired to ExecReload = kill -SIGHUP), shadowed
  # that lighter mechanism and forced a full stop+start on every
  # collector config change instead -- confirmed directly via a real
  # switch-to-configuration between two generations differing only in
  # hostType: MainPID changed with restartTriggers present, stayed
  # stable once removed. A hard restart drops the local OTLP receiver
  # (4317/4318) and host-metrics scraping for the duration, for a change
  # Alloy's own module is specifically designed to reload in place
  # instead. Uses nodes.machine (a real VM, not a container) --
  # specialisation + switch-to-configuration needs a full boot, the
  # mechanism nspawn containers don't support the same way.
  config-change-reloads-alloy-in-place-not-a-full-restart = pkgs.testers.nixosTest {
    name = "victoria-collector-alloy-reload-not-restart";

    nodes.machine =
      { lib, ... }:
      {
        imports = [ collectorModule ];
        services.victoriaCollector = {
          metrics.enable = true;
          writeEndpoint = "http://127.0.0.1:4204";
          hostType = "server-a";
        };
        specialisation.b.configuration = {
          services.victoriaCollector.hostType = lib.mkForce "server-b";
        };
      };

    testScript = ''
      machine.start()
      machine.wait_for_unit("alloy.service")
      # "active" only means systemd forked the process: a SIGHUP (the
      # reload) before Alloy has installed its handler kills it outright,
      # which is what made this test flake under load. Wait until Alloy
      # itself reports ready.
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:12345/-/ready")
      pid_before = machine.succeed("systemctl show -p MainPID --value alloy.service").strip()

      machine.succeed(
          "/run/current-system/specialisation/b/bin/switch-to-configuration test 2>&1"
      )
      machine.sleep(2)
      pid_after = machine.succeed("systemctl show -p MainPID --value alloy.service").strip()

      assert pid_before == pid_after, (
          f"expected alloy.service to reload in place (same MainPID) across "
          f"a hostType-only config change, not restart -- before={pid_before!r}, "
          f"after={pid_after!r}"
      )
    '';
  };

  # Alloy's tls.ca_file / https:// path, for real: the gateway sits behind
  # a TLS-terminating nginx and the collector verifies it against the CA
  # (the existing alloy-tls-and-retry-options-are-inert-unless-configured
  # only string-matches the rendered config).
  metrics-roundtrip-over-verified-tls = pkgs.testers.nixosTest {
    name = "victoria-collector-metrics-roundtrip-over-verified-tls";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        # vmauth stays on its loopback default: only nginx is reachable.
      };
      services.nginx = {
        enable = true;
        virtualHosts."stack" = {
          onlySSL = true;
          sslCertificate = "${stackSelfSignedCert}/cert.pem";
          sslCertificateKey = "${stackSelfSignedCert}/key.pem";
          locations."/".proxyPass = "http://127.0.0.1:4204";
        };
      };
      networking.firewall.allowedTCPPorts = [ 443 ];
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "https://stack";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
        alloy.tlsCaFile = "${stackSelfSignedCert}/cert.pem";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("nginx.service")
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      collector.wait_for_unit("alloy.service")
      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")
      # network-online.target can be reached even if the collector's own
      # address unit failed to start in the container (seen once in a
      # 240-check run: the collector never got an IP and the test timed
      # out 120s later) -- fail early and clearly instead.
      collector.wait_until_succeeds("ping -c 1 stack")

      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=alloy_up' | grep -q '\"value\"'",
          timeout=120,
      )
      # The data really arrived over TLS, through nginx.
      stack.succeed("grep -q 'POST /opentelemetry/v1/metrics' /var/log/nginx/access.log")
    '';
  };

  # queue.directory outside alloy's own StateDirectory: Alloy must really
  # write its queue there (not just have the path in ReadWritePaths).
  queue-directory-outside-statedir-is-really-written = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-directory-outside-statedir";

    containers.stack = mkStackContainer { services.metrics.enable = true; };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
        queue.directory = "/run/alloy-queue-test";
        # A dynamic user cannot write outside its StateDirectory (nothing owns the
        # directory for it); a static user plus the module's tmpfiles rule can, so
        # no world-writable workaround is needed here any more.
        alloy.dynamicUser = false;
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      collector.wait_for_unit("alloy.service")
      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")
      # network-online.target can be reached even if the collector's own
      # address unit failed to start in the container (seen once in a
      # 240-check run: the collector never got an IP and the test timed
      # out 120s later) -- fail early and clearly instead.
      collector.wait_until_succeeds("ping -c 1 stack")

      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=alloy_up' | grep -q '\"value\"'",
          timeout=120,
      )
      collector.succeed("test -n \"$(ls -A /run/alloy-queue-test)\"")
      # Owned by the static user, not world-writable.
      assert collector.succeed("stat -c '%U %a' /run/alloy-queue-test").strip() == "alloy 750"
      # The sandbox a dynamic user would have implied is still in force.
      assert collector.succeed("systemctl show -p ProtectSystem --value alloy.service").strip() == "strict"
    '';
  };

  # All three signals on ONE collector, each with a real roundtrip.
  three-signals-roundtrip-from-one-collector = pkgs.testers.nixosTest {
    name = "victoria-collector-three-signals-one-collector";

    containers.stack = mkStackContainer {
      services = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
      };
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      stack.wait_for_unit("victorialogs.service")
      stack.wait_for_unit("victoriatraces.service")
      collector.wait_for_unit("alloy.service")
      collector.wait_for_unit("systemd-journal-upload.service")
      collector.wait_for_open_port(4318)
      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")
      # network-online.target can be reached even if the collector's own
      # address unit failed to start in the container (seen once in a
      # 240-check run: the collector never got an IP and the test timed
      # out 120s later) -- fail early and clearly instead.
      collector.wait_until_succeeds("ping -c 1 stack")

      collector.succeed("logger --tag victoria-collector-test 'victoria_stack_three_signals_log_marker'")
      collector.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_three_signals_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000006\","
          "\"spanId\":\"0000000000000006\","
          "\"name\":\"victoria_stack_three_signals_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4318/v1/traces'"
      )

      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=alloy_up' | grep -q '\"value\"'",
          timeout=120,
      )
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4202/select/logsql/query' "
          "-d 'query=victoria_stack_three_signals_log_marker' "
          "| grep -q victoria_stack_three_signals_log_marker",
          timeout=120,
      )
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4203/select/jaeger/api/services' "
          "| grep -q victoria_stack_three_signals_service",
          timeout=120,
      )
    '';
  };

  # A fleet: two collectors with distinct hostType and distinct write
  # tokens shipping concurrently to one gateway.
  two-collectors-ship-distinguishable-series-concurrently = pkgs.testers.nixosTest {
    name = "victoria-collector-two-collector-fleet";

    containers.stack = mkStackContainer {
      services.metrics.enable = true;
      tokensFile = twoWriteTokensFixture;
    };

    containers.collector-a = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenAFixture}";
        hostType = "server";
      };
    };

    containers.collector-b = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenBFixture}";
        hostType = "edge-device";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      for c in (collector_a, collector_b):
          c.wait_for_unit("alloy.service")
      for m in (stack, collector_a, collector_b):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")
      # See the note in the single-collector tests: fail early if a collector
      # never got its address.
      for c in (collector_a, collector_b):
          c.wait_until_succeeds("ping -c 1 stack")

      # The hostType label lands on VictoriaMetrics as `host_type`, the plain
      # selector below matching what options.nix documents. (It used to
      # arrive as `host.type`, dot included, which only a quoted selector
      # could match.)
      for host_type in ("server", "edge-device"):
          stack.wait_until_succeeds(
              "curl -sfG 'http://127.0.0.1:4201/api/v1/query' "
              f"--data-urlencode 'query=alloy_up{{host_type=\"{host_type}\"}}' "
              "| grep -q '\"value\"'",
              timeout=120,
          )

      # Both hosts' series are present side by side and distinguishable.
      hosts = stack.succeed(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=alloy_up'"
      )
      assert "collector-a" in hosts and "collector-b" in hosts, hosts
    '';
  };

  # examples/fleet.nix is documentation operators copy from -- evaluate it
  # (gateway + two collectors with distinct labels/tokens) so it can't
  # drift from the real option set.
  fleet-example-evaluates = pkgs.runCommand "fleet-example-evaluates" { } (
    let
      fleet = import ../examples/fleet.nix { };
      gateway = testLib.evalWith {
        imports = [ fleet.gateway ];
        services.victoriaStack.vmauth.writeTokensFile = lib.mkForce "${twoWriteTokensFixture}";
      };
      collectorOf =
        hostType: tokenFile:
        evalWithCollector {
          imports = [
            (fleet.collector {
              inherit hostType;
              writeTokenFile = "${tokenFile}";
            })
          ];
        };
      a = collectorOf "server" writeTokenAFixture;
      b = collectorOf "edge-device" writeTokenBFixture;
      ownFailed' =
        e:
        lib.filter (lib.hasInfix "services.victoria") (
          map (x: x.message) (builtins.filter (x: !x.assertion) e.config.assertions)
        );
      checks = {
        "gateway: vmauth has a public HTTPS door and keeps its internal listener on loopback" =
          gateway.config.services.victoriaStack.vmauth.https.enable
          && lib.hasPrefix "127.0.0.1:" gateway.config.services.victoriaStack.vmauth.listenAddress;
        "gateway: no failed assertions" = ownFailed' gateway == [ ];
        "collectors: no failed assertions" = ownFailed' a == [ ] && ownFailed' b == [ ];
        "collectors: distinct hostType" =
          a.config.services.victoriaCollector.hostType != b.config.services.victoriaCollector.hostType;
        "collectors: distinct token files" =
          a.config.services.victoriaCollector.writeTokenFile
          != b.config.services.victoriaCollector.writeTokenFile;
        "collectors: endpoint is not loopback" =
          !(lib.hasInfix "127.0.0.1" a.config.services.victoriaCollector.writeEndpoint);
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "examples/fleet.nix broken: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # --- metrics customization (extraCollectors / disabledCollectors / scrapeInterval) ---

  metrics-customization-options-are-inert-by-default =
    pkgs.runCommand "metrics-customization-inert-by-default" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          text = evaluated.config.environment.etc."alloy/config.alloy".text;
          checks = {
            "enable_collectors is exactly today's hardcoded list" =
              lib.hasInfix ''enable_collectors = ["systemd"]'' text;
            "no disable_collectors line" = !(lib.hasInfix "disable_collectors" text);
            "no scrape_interval line" = !(lib.hasInfix "scrape_interval" text);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "defaults changed the rendered config: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  metrics-customization-options-render-when-set =
    pkgs.runCommand "metrics-customization-renders-when-set" { }
      (
        let
          evaluated = evalWithCollector {
            services.victoriaCollector = {
              metrics = {
                enable = true;
                extraCollectors = [
                  "processes"
                  "textfile"
                ];
                disabledCollectors = [
                  "loadavg"
                  "hwmon"
                ];
                scrapeInterval = "30s";
              };
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          };
          text = evaluated.config.environment.etc."alloy/config.alloy".text;
          checks = {
            "enable_collectors keeps systemd and adds the extras" =
              lib.hasInfix ''enable_collectors = ["systemd", "processes", "textfile"]'' text;
            "disable_collectors" = lib.hasInfix ''disable_collectors = ["loadavg", "hwmon"]'' text;
            "scrape_interval" = lib.hasInfix ''scrape_interval = "30s"'' text;
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "metrics customization did not render: ${builtins.toJSON (builtins.attrNames failed)}\n${text}"
      );

  metrics-customization-rejects-values-that-would-break-alloy-syntax =
    pkgs.runCommand "metrics-customization-rejects-unsafe-values" { }
      (
        let
          opts = httpsEvaluated.options.services.victoriaCollector.metrics;
          checks = {
            "collector name with a quote" = !(opts.extraCollectors.type.nestedTypes.elemType.check ''a"b'');
            "disabled collector with a quote" =
              !(opts.disabledCollectors.type.nestedTypes.elemType.check ''a"b'');
            "scrapeInterval with a quote" = !(opts.scrapeInterval.type.check ''30s"'');
            "ordinary names and durations are accepted" =
              opts.extraCollectors.type.nestedTypes.elemType.check "processes"
              && opts.scrapeInterval.type.check "30s"
              && opts.scrapeInterval.type.check "1m30s";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "unsafe values accepted (or safe ones rejected): ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # Real behavior, not rendered text: an extra collector's metric lands at
  # the gateway, and a disabled default collector's does NOT while the
  # others still do.
  metrics-customization-changes-what-actually-ships = pkgs.testers.nixosTest {
    name = "victoria-collector-metrics-customization";

    containers.stack = mkStackContainer { services.metrics.enable = true; };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics = {
          enable = true;
          extraCollectors = [ "processes" ];
          disabledCollectors = [ "loadavg" ];
        };
        writeEndpoint = "http://stack:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victoriametrics.service")
      collector.wait_for_unit("alloy.service")
      stack.systemctl("start network-online.target")
      collector.systemctl("start network-online.target")
      stack.wait_for_unit("network-online.target")
      collector.wait_for_unit("network-online.target")
      # network-online.target can be reached even if the collector's own
      # address unit failed to start in the container (seen once in a
      # 240-check run: the collector never got an IP and the test timed
      # out 120s later) -- fail early and clearly instead.
      collector.wait_until_succeeds("ping -c 1 stack")

      def has(metric):
          return stack.succeed(
              f"curl -sf 'http://127.0.0.1:4201/api/v1/query?query=count({metric})'"
          )

      # Enabled by default, so a pipeline that works at all ships these...
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=node_cpu_seconds_total' | grep -q '\"value\"'",
          timeout=180,
      )
      # ...the extra collector's metric arrives...
      stack.wait_until_succeeds(
          "curl -sf 'http://127.0.0.1:4201/api/v1/query?query=node_processes_pids' | grep -q '\"value\"'",
          timeout=180,
      )
      # ...and the disabled collector's does not (node_load1 is shipped by
      # default, so its absence is the behavior change).
      assert '"result":[]' in has("node_load1"), has("node_load1")
    '';
  };

  # The label name is part of the documented contract: host_type with an
  # underscore, so a plain `{host_type="server"}` selector works. A dotted
  # `host.type` can only be matched with a quoted selector.
  host-type-label-is-spelled-with-an-underscore-for-metrics-and-traces =
    pkgs.runCommand "host-type-label-spelling" { }
      (
        let
          textFor =
            m:
            (evalWithCollector {
              services.victoriaCollector = {
                writeEndpoint = "http://127.0.0.1:4204";
                hostType = "server";
              }
              // m;
            }).config.environment.etc."alloy/config.alloy".text;
          metrics = textFor { metrics.enable = true; };
          traces = textFor { traces.enable = true; };
          checks = {
            "metrics: host_type key with the configured value" =
              lib.hasInfix ''key    = "host_type"'' metrics && lib.hasInfix ''value  = "server"'' metrics;
            "traces: host_type key with the configured value" =
              lib.hasInfix ''key    = "host_type"'' traces && lib.hasInfix ''value  = "server"'' traces;
            "metrics: no dotted host.type left" = !(lib.hasInfix "host.type" metrics);
            "traces: no dotted host.type left" = !(lib.hasInfix "host.type" traces);
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "host_type label spelling broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  # alloy.extraFlags had no test at all. A real boot is the check: a mistyped or
  # misplaced flag crashes Alloy, and the flag must appear on the running
  # process's own command line.
  alloy-extra-flags-reach-the-running-process = pkgs.testers.nixosTest {
    name = "victoria-collector-alloy-extra-flags";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        # Nothing listens here; only the process's own flags matter.
        writeEndpoint = "http://127.0.0.1:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
        alloy.extraFlags = [ "--disable-reporting" ];
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      collector.wait_until_succeeds("curl -sf http://127.0.0.1:12345/-/ready")
      pid = collector.succeed("systemctl show -p MainPID --value alloy.service").strip()
      cmdline = collector.succeed(f"tr '\\0' ' ' < /proc/{pid}/cmdline")
      assert "--disable-reporting" in cmdline, cmdline
      # Still the module's own flag as well: extraFlags adds to it, never replaces.
      assert "--stability.level=public-preview" in cmdline, cmdline
    '';
  };

  # trustedCertificateFile was only exercised inside the maximal test. Logs over
  # verified TLS, with a negative control: a collector that does NOT trust the
  # gateway's CA must deliver nothing (so the pass above is verification at
  # work, not a gateway that accepts anything).
  journal-upload-https-verifies-the-gateway = pkgs.testers.nixosTest {
    name = "victoria-collector-journal-upload-https-verifies-the-gateway";

    containers.stack = {
      virtualisation.vlans = [ 1 ];
      imports = [ stackModule ];
      services.victoriaStack = {
        logs.enable = true;
        vmauth.writeTokensFile = "${writeTokensFixture}";
        # vmauth stays on its loopback default: only nginx is reachable.
      };
      services.nginx = {
        enable = true;
        virtualHosts."stack" = {
          onlySSL = true;
          sslCertificate = "${stackSelfSignedCert}/cert.pem";
          sslCertificateKey = "${stackSelfSignedCert}/key.pem";
          locations."/".proxyPass = "http://127.0.0.1:4204";
        };
      };
      networking.firewall.allowedTCPPorts = [ 443 ];
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        logs.enable = true;
        # Explicit port: systemd-journal-upload does not default https to 443.
        writeEndpoint = "https://stack:443";
        writeTokenFile = "${writeTokenFixture}";
        trustedCertificateFile = "${stackSelfSignedCert}/cert.pem";
      };
    };

    containers.collector-untrusted = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        logs.enable = true;
        writeEndpoint = "https://stack:443";
        writeTokenFile = "${writeTokenFixture}";
        # trustedCertificateFile left at the system bundle, which does not
        # contain the test CA.
      };
    };

    testScript = ''
      start_all()
      stack.wait_for_unit("nginx.service")
      stack.wait_for_unit("vmauth.service")
      stack.wait_for_unit("victorialogs.service")
      # Only the trusted uploader is awaited: the untrusted one is SUPPOSED to
      # fail verification and restart-loop, so it never settles as "active".
      collector.wait_for_unit("systemd-journal-upload.service")
      for m in (stack, collector, collector_untrusted):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")
      for c in (collector, collector_untrusted):
          c.wait_until_succeeds("ping -c 1 stack")

      # The token drop-in is owner/group-only.
      assert collector.succeed(
          "stat -c '%a %G' /run/systemd/journal-upload.conf.d/50-write-token.conf"
      ).strip() == "640 systemd-journal"

      collector.succeed("logger --tag tls-test 'victoria_tls_trusted_marker'")
      collector_untrusted.succeed("logger --tag tls-test 'victoria_tls_untrusted_marker'")

      def query(marker):
          return (
              "curl -sf 'http://127.0.0.1:4202/select/logsql/query' "
              f"-d 'query={marker}' | grep -q {marker}"
          )

      stack.wait_until_succeeds(query("victoria_tls_trusted_marker"), timeout=120)
      # By now the untrusted one has had as long as the trusted one to deliver.
      stack.fail(query("victoria_tls_untrusted_marker"))
      # ...and it failed for the right reason (it could not verify/connect), not
      # because it never tried.
      collector_untrusted.wait_until_succeeds(
          "journalctl -u systemd-journal-upload.service --no-pager "
          "| grep -iE 'certificate|verif|ssl|tls|could not connect|failed'",
          timeout=60,
      )
    '';
  };

  # --- Alloy config generation: scrape timeout, types, escaping, defaults ---

  scrape-timeout-follows-the-interval = pkgs.runCommand "scrape-timeout-follows-the-interval" { } (
    let
      textFor =
        interval:
        (evalWithCollector {
          services.victoriaCollector = {
            metrics = {
              enable = true;
              scrapeInterval = interval;
            };
            writeEndpoint = "http://127.0.0.1:4204";
            hostType = "server";
          };
        }).config.environment.etc."alloy/config.alloy".text;
      hasTimeout = interval: lib.hasInfix "scrape_timeout" (textFor interval);
      timeoutIs = interval: lib.hasInfix ''scrape_timeout = "${interval}"'' (textFor interval);
      checks = {
        # Alloy's own scrape_timeout default is 10s and it exits at start when
        # that is GREATER than the interval ("scrape_timeout (10s) greater than
        # scrape_interval (5s)"); `alloy validate` does not notice.
        "5s -> timeout 5s" = timeoutIs "5s";
        "500ms -> timeout 500ms" = timeoutIs "500ms";
        "9s999ms (combined form) -> timeout 9s999ms" = timeoutIs "9s999ms";
        "1s -> timeout 1s" = timeoutIs "1s";
        "10s needs none" = !(hasTimeout "10s");
        "30s needs none" = !(hasTimeout "30s");
        "1m30s needs none" = !(hasTimeout "1m30s");
        "1h needs none" = !(hasTimeout "1h");
        "null needs none" = !(hasTimeout null);
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "scrape_timeout wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # A zero-length interval fails at run time as well.
  zero-scrape-interval-is-rejected = pkgs.runCommand "zero-scrape-interval-rejected" { } (
    let
      fires =
        interval:
        lib.any (lib.hasInfix "scrapeInterval") (
          ownFailed (evalWithCollector {
            services.victoriaCollector = {
              metrics = {
                enable = true;
                scrapeInterval = interval;
              };
              writeEndpoint = "http://127.0.0.1:4204";
              hostType = "server";
            };
          })
        );
    in
    if fires "0s" && fires "0ms" && fires "0m0s" && !(fires "1s") && !(fires null) then
      "echo OK > $out"
    else
      throw "zero scrapeInterval handling wrong"
  );

  # REAL boot: validate passes on the broken config (verified), so a validate-only
  # test would hide the crash loop.
  scrape-interval-below-ten-seconds-really-boots = pkgs.testers.nixosTest {
    name = "victoria-collector-scrape-interval-below-ten-seconds";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics = {
          enable = true;
          scrapeInterval = "5s";
        };
        # Nothing listens here; the exporter just retries.
        writeEndpoint = "http://127.0.0.1:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      collector.wait_until_succeeds("curl -sf http://127.0.0.1:12345/-/ready")
      collector.sleep(12)
      collector.succeed("systemctl is-active alloy.service")
      journal = collector.succeed("journalctl -u alloy.service --no-pager")
      assert "greater than scrape_interval" not in journal, journal[-800:]
    '';
  };

  alloy-option-types-reject-values-alloy-cannot-run = pkgs.runCommand "alloy-option-types" { } (
    let
      opts = (evalWithCollector { }).options.services.victoriaCollector;
      retry = opts.alloy.retryOnFailure;
      queueSize = opts.queue.maxSizeBytes.type;
      dur = o: o.type.nestedTypes.elemType;
      checks = {
        "queue size 1 accepted" = queueSize.check 1;
        "queue size 0 rejected (alloy run: queue_size must be greater than zero)" = !(queueSize.check 0);
        "queue size -5 rejected" = !(queueSize.check (-5));
        "initialInterval 5s accepted" = (dur retry.initialInterval).check "5s";
        "initialInterval abc rejected" = !((dur retry.initialInterval).check "abc");
        "maxInterval with a quote rejected" = !((dur retry.maxInterval).check ''5s"'');
        "maxElapsedTime 1m30s accepted" = (dur retry.maxElapsedTime).check "1m30s";
        "maxElapsedTime five seconds rejected" = !((dur retry.maxElapsedTime).check "five seconds");
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "alloy option types wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # Interpolated options used to reach the generated config unescaped: a quote in
  # writeEndpoint or queue.directory broke the syntax. The real alloy binary is the
  # judge, with a control proving the check can fail.
  hostile-config-values-render-valid-alloy =
    let
      textFor =
        m:
        (evalWithCollector {
          services.victoriaCollector = {
            metrics.enable = true;
            traces.enable = true;
            hostType = "server";
            writeEndpoint = "http://127.0.0.1:4204";
          }
          // m;
        }).config.environment.etc."alloy/config.alloy".text;
      cases = {
        quote-in-endpoint = textFor { writeEndpoint = ''http://h"x''; };
        quote-in-queue-dir = textFor { queue.directory = ''/var/lib/alloy/q"x''; };
        newline-in-queue-dir = textFor { queue.directory = "/var/lib/alloy/q\nx"; };
        backslash-in-endpoint = textFor { writeEndpoint = ''http://h\x''; };
      };
    in
    pkgs.runCommand "hostile-config-values-render-valid-alloy"
      { nativeBuildInputs = [ pkgs.grafana-alloy ]; }
      ''
        export HOME=$TMPDIR
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: text: ''
            cat > ${name}.alloy <<'ALLOY_EOF'
            ${text}
            ALLOY_EOF
            alloy validate --stability.level=public-preview ${name}.alloy \
              || { echo "alloy rejects the config rendered for ${name}" >&2; exit 1; }
          '') cases
        )}
        # Control: the same hostile value interpolated RAW (what the generator used
        # to do) must be rejected, or this check proves nothing.
        cat > control.alloy <<'ALLOY_EOF'
        otelcol.exporter.otlphttp "m" {
          client {
            endpoint = "http://h"x/opentelemetry"
          }
        }
        ALLOY_EOF
        if alloy validate --stability.level=public-preview control.alloy 2>/dev/null; then
          echo "the control (raw interpolation) was accepted: this test cannot fail" >&2
          exit 1
        fi
        echo OK > $out
      '';

  queue-directory-with-dotdot-is-rejected = pkgs.runCommand "queue-directory-dotdot" { } (
    let
      fires =
        dir:
        lib.any (lib.hasInfix "queue.directory") (
          ownFailed (evalWithCollector {
            services.victoriaCollector = {
              metrics.enable = true;
              hostType = "server";
              writeEndpoint = "http://127.0.0.1:4204";
              queue.directory = dir;
            };
          })
        );
    in
    if
      fires "/var/lib/alloy/../etc/q"
      && fires "/var/lib/alloy/q/.."
      && !(fires "/var/lib/alloy/queue")
      && !(fires "/srv/bigdisk/alloy.queue")
    then
      "echo OK > $out"
    else
      throw "queue.directory .. guard wrong"
  );

  retry-forever-is-the-default-and-the-operator-can-override =
    pkgs.runCommand "retry-forever-default" { }
      (
        let
          textFor =
            m:
            (evalWithCollector {
              services.victoriaCollector = {
                metrics.enable = true;
                hostType = "server";
                writeEndpoint = "http://127.0.0.1:4204";
                alloy.retryOnFailure = m;
              };
            }).config.environment.etc."alloy/config.alloy".text;
          checks = {
            "default retries forever on both exporters" =
              lib.length (lib.splitString ''max_elapsed_time = "0s"'' (textFor { })) == 2;
            "an operator value wins" =
              lib.hasInfix ''max_elapsed_time = "5m"'' (textFor {
                maxElapsedTime = "5m";
              })
              && !(lib.hasInfix ''max_elapsed_time = "0s"'' (textFor {
                maxElapsedTime = "5m";
              }));
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "retry default wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  otlp-receiver-ports-are-configurable = pkgs.runCommand "otlp-receiver-ports" { } (
    let
      textFor =
        m:
        (evalWithCollector {
          services.victoriaCollector = {
            traces = {
              enable = true;
            }
            // m;
            hostType = "server";
            writeEndpoint = "http://127.0.0.1:4204";
          };
        }).config.environment.etc."alloy/config.alloy".text;
      checks = {
        "defaults unchanged" =
          lib.hasInfix ''endpoint = "127.0.0.1:4317"'' (textFor { })
          && lib.hasInfix ''endpoint = "127.0.0.1:4318"'' (textFor { });
        "custom ports render" =
          lib.hasInfix ''endpoint = "127.0.0.1:14317"'' (textFor {
            receiver = {
              grpcPort = 14317;
              httpPort = 14318;
            };
          })
          && lib.hasInfix ''endpoint = "127.0.0.1:14318"'' (textFor {
            receiver = {
              grpcPort = 14317;
              httpPort = 14318;
            };
          });
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "receiver ports wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  otlp-receiver-listens-on-custom-ports = pkgs.testers.nixosTest {
    name = "victoria-collector-custom-otlp-receiver-ports";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        traces = {
          enable = true;
          receiver = {
            grpcPort = 14317;
            httpPort = 14318;
          };
        };
        writeEndpoint = "http://127.0.0.1:4204";
        writeTokenFile = "${writeTokenFixture}";
        hostType = "server";
      };
    };

    testScript = ''
      start_all()
      collector.wait_for_unit("alloy.service")
      collector.wait_for_open_port(14317)
      collector.wait_for_open_port(14318)
      listeners = collector.succeed("ss -Hltn")
      assert ":4317" not in listeners and ":4318" not in listeners, listeners
    '';
  };

  # --- Alloy's user: dynamic by default, static on request (mirrors the storage
  # services' dynamicUser / manageTmpfiles / suppressDynamicUserWarning) ---

  alloy-static-user-wiring = pkgs.runCommand "alloy-static-user-wiring" { } (
    let
      evalFor =
        m:
        evalWithCollector {
          services.victoriaCollector = {
            metrics.enable = true;
            hostType = "server";
            writeEndpoint = "http://127.0.0.1:4204";
          }
          // m;
        };
      unit = e: e.config.systemd.services.alloy.serviceConfig;
      warnsAbout =
        e:
        lib.any (lib.hasInfix "dynamicUser") (
          lib.filter (lib.hasInfix "services.victoriaCollector") e.config.warnings
        );
      custom = {
        queue.directory = "/srv/alloy-queue";
      };
      dynamicDefault = evalFor { };
      dynamicCustom = evalFor custom;
      staticCustom = evalFor (custom // { alloy.dynamicUser = false; });
      staticNoTmpfiles = evalFor (
        custom
        // {
          alloy = {
            dynamicUser = false;
            manageTmpfiles = false;
          };
        }
      );
      suppressed = evalFor (custom // { alloy.suppressDynamicUserWarning = true; });
      checks = {
        "default: dynamic user, nothing changed" =
          (unit dynamicDefault).DynamicUser == true
          && !((unit dynamicDefault) ? User)
          && !(dynamicDefault.config.users.users ? alloy);
        "default dir with a dynamic user: no warning" = !(warnsAbout dynamicDefault);
        "dynamic user + a queue dir outside /var/lib/alloy: WARNING" = warnsAbout dynamicCustom;
        "the warning can be suppressed" = !(warnsAbout suppressed);
        "static user: no warning" = !(warnsAbout staticCustom);
        "static: DynamicUser forced off, user and group alloy" =
          (unit staticCustom).DynamicUser == false
          && (unit staticCustom).User == "alloy"
          && (unit staticCustom).Group == "alloy"
          && staticCustom.config.users.users.alloy.isSystemUser
          && staticCustom.config.users.groups ? alloy;
        "static: the journal-reading group from nixpkgs is kept" =
          lib.elem "systemd-journal" (unit staticCustom).SupplementaryGroups;
        "static: the queue directory is created for the user" =
          lib.elem "d /srv/alloy-queue 0750 alloy alloy - -" staticCustom.config.systemd.tmpfiles.rules;
        "manageTmpfiles = false: no rule" =
          !(lib.any (lib.hasInfix "/srv/alloy-queue") staticNoTmpfiles.config.systemd.tmpfiles.rules);
        # DynamicUser=yes implied these; DynamicUser=false drops them, so they
        # are set explicitly.
        "static: the implied sandbox is re-added" =
          (unit staticCustom).ProtectSystem == "strict"
          && (unit staticCustom).ProtectHome == "read-only"
          && (unit staticCustom).PrivateTmp == true
          && (unit staticCustom).RemoveIPC == true
          && (unit staticCustom).NoNewPrivileges == true;
        "the queue dir is writable under ProtectSystem=strict" =
          lib.elem "/srv/alloy-queue" (unit staticCustom).ReadWritePaths;
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "alloy user wiring wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # systemd-journal-upload does not follow the https=443 / http=80 convention: it
  # only recognises a port when a ":" appears somewhere after the scheme, and
  # otherwise appends its OWN default port after the URL's path
  # ("https://gw/insert/journald:19532/upload", answered with a 400). A standard
  # port-less endpoint is still a valid URL for Alloy, so this is a WARNING that
  # explains the quirk, never an error and never a rewrite of the URL.
  journald-endpoint-without-a-port-warns = pkgs.runCommand "journald-endpoint-port-warning" { } (
    let
      evalFor =
        m:
        evalWithCollector {
          services.victoriaCollector = {
            logs.enable = true;
            writeTokenFile = "${writeTokenFixture}";
          }
          // m;
        };
      warns =
        m:
        lib.any (lib.hasInfix "explicit port") (
          lib.filter (lib.hasInfix "services.victoriaCollector") (evalFor m).config.warnings
        );
      checks = {
        "https without a port" = warns { writeEndpoint = "https://stack"; };
        "http without a port" = warns { writeEndpoint = "http://stack"; };
        "a path but no port" = warns { writeEndpoint = "https://stack/victoria"; };
        "an explicit port" = !(warns { writeEndpoint = "https://stack:443"; });
        "a port and a path" = !(warns { writeEndpoint = "https://stack:443/victoria"; });
        "an IPv4 address with a port" = !(warns { writeEndpoint = "http://127.0.0.1:4204"; });
        # The uploader sees a ":" inside an IPv6 literal or a path: it works.
        "a bracketed IPv6 literal" = !(warns { writeEndpoint = "https://[::1]/pfx"; });
        "a colon in the path" = !(warns { writeEndpoint = "https://gw/a:b"; });
        "journaldWriteEndpoint is what counts (without a port)" = warns {
          writeEndpoint = "https://stack:8443";
          journaldWriteEndpoint = "https://stack";
        };
        "journaldWriteEndpoint is what counts (with a port)" =
          !(warns {
            writeEndpoint = "https://stack";
            journaldWriteEndpoint = "https://stack:443";
          });
        "never an assertion: the build proceeds" =
          ownFailed (evalFor {
            writeEndpoint = "https://stack";
          }) == [ ];
        "no warning when logs are not shipped" =
          !(lib.any (lib.hasInfix "explicit port") (
            (evalWithCollector {
              services.victoriaCollector = {
                metrics.enable = true;
                hostType = "server";
                writeEndpoint = "https://stack";
                writeTokenFile = "${writeTokenFixture}";
              };
            }).config.warnings
          ));
      };
      failed = lib.filterAttrs (_: ok: !ok) checks;
    in
    if failed == { } then
      "echo OK > $out"
    else
      throw "journald port warning wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
  );

  # nixpkgs' journald-upload module wires no restart trigger, so a rebuild that
  # changed only the endpoint or the CA rewrote /etc/systemd/journal-upload.conf and
  # left the running uploader on the old URL until reboot.
  journal-upload-restarts-when-its-config-changes =
    pkgs.runCommand "journal-upload-restart-trigger" { }
      (
        let
          e = evalWithCollector {
            services.victoriaCollector = {
              logs.enable = true;
              writeEndpoint = "http://127.0.0.1:4204";
              writeTokenFile = "${writeTokenFixture}";
            };
          };
          triggers = e.config.systemd.services.systemd-journal-upload.restartTriggers;
        in
        if lib.elem e.config.environment.etc."systemd/journal-upload.conf".source triggers then
          "echo OK > $out"
        else
          throw "systemd-journal-upload has no restart trigger on its config"
      );

  # The write-token drop-in holds a secret: created owner/group-only from the start
  # (the render script runs under the default umask 022, so it was 644 until the
  # chmod ran).
  journal-upload-token-dropin-is-never-world-readable =
    let
      e = evalWithCollector {
        services.victoriaCollector = {
          logs.enable = true;
          writeEndpoint = "http://127.0.0.1:4204";
          writeTokenFile = "${writeTokenFixture}";
        };
      };
      script = e.config.systemd.services.victoria-collector-journal-upload-token.serviceConfig.ExecStart;
    in
    pkgs.runCommand "journal-upload-token-dropin-umask" { } ''
      grep -q '^umask 027' ${script} || { echo "the token drop-in script does not set umask 027 before creating the file" >&2; exit 1; }
      echo OK > $out
    '';
}
