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
      - collector-test-write-token # test fixture, not real
  '';

  writeTokenFixture = pkgs.writeText "collector-test-write-token" "collector-test-write-token";

  # Pure eval, no container boot needed: confirms the https:// branch of
  # journaldWriteEndpoint actually renders the dummy-cert + CA-bundle
  # settings it's supposed to -- the one branch with no prior coverage
  # at all (the roundtrip test above only ever uses a plain http://
  # writeEndpoint).
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

  journal-upload-https-renders-dummy-cert =
    pkgs.runCommand "journal-upload-https-renders-dummy-cert" { }
      (
        let
          upload = httpsEvaluated.config.services.journald.upload.settings.Upload;
          checks = [
            (upload ? ServerKeyFile)
            (upload ? ServerCertificateFile)
            (upload.TrustedCertificateFile == "/etc/ssl/certs/ca-certificates.crt")
            (upload.URL == "https://victoria-stack.example.invalid:4204/insert/journald")
          ];
        in
        if builtins.all (x: x) checks then
          "echo OK > $out"
        else
          throw "journal-upload https:// branch did not render the expected settings: ${builtins.toJSON upload}"
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
        if lib.hasInfix "host.type" configText then
          "echo OK > $out"
        else
          throw ''
            hostType's own option doc promises a fleet-identification label
            that isn't scoped to metrics only -- but the traces-only
            rendered Alloy config has no host.type attribute anywhere.
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
            "no retry_on_failure block when unset" = !(lib.hasInfix "retry_on_failure {" textUnset);
            "insecure_skip_verify set on both exporters" =
              countOccurrences "insecure_skip_verify = true" textSet == 2;
            "ca_file set on both exporters" = countOccurrences "ca_file" textSet == 2;
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
}
