{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  stackModule = nixosModule.nixosModules.victoriaStack;
  collectorModule = nixosModule.nixosModules.victoriaCollector;

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
          journaldWriteEndpoint = "https://victoria-stack.example.invalid:8880";
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
        vmauth.writeTokensFile = writeTokensFixture;
      };
    };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://stack:8880";
        writeTokenFile = writeTokenFixture;
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
          "curl -sf 'http://127.0.0.1:8428/api/v1/query?query=alloy_up' | grep -q '\"value\"'",
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
        writeEndpoint = "http://127.0.0.1:8880";
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
        writeEndpoint = "http://127.0.0.1:8880";
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
            (upload.URL == "https://victoria-stack.example.invalid:8880/insert/journald")
          ];
        in
        if builtins.all (x: x) checks then
          "echo OK > $out"
        else
          throw "journal-upload https:// branch did not render the expected settings: ${builtins.toJSON upload}"
      );

  queue-option-takes-effect = pkgs.testers.nixosTest {
    name = "victoria-collector-queue-option";

    containers.collector = {
      imports = [ collectorModule ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://127.0.0.1:8880";
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
}
