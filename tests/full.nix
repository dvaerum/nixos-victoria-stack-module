{ pkgs, nixosModule }:

let
  module = nixosModule.nixosModules.default;
  example = import ../examples { };

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) otlpMetricGenerator;
  otlpMetric = "${otlpMetricGenerator}/bin/gen-otlp-metric";

  # Same throwaway-fixture pattern as every other test group -- these
  # override the example's placeholder /run/secrets/... paths, nothing
  # else about the example's own shape changes.
  adminPasswordFixture = pkgs.writeText "full-admin-password" "full-test-admin-password";
  readTokensFixture = pkgs.writeText "full-read-tokens.yaml" ''
    tokens:
      - token: full-test-read-token
  '';
  writeTokensFixture = pkgs.writeText "full-write-tokens.yaml" ''
    tokens:
      - token: full-test-write-token
  '';
  grafanaSecretKeyFixture = pkgs.writeText "full-grafana-secret-key" "full-test-grafana-secret-key";
  grafanaAdminPasswordFixture = pkgs.writeText "full-grafana-admin-password" "full-test-grafana-admin-password";
  # Server cert for the maximal test's TLS-fronted gateway; SAN matches
  # the container hostname the remote collector dials.
  stackSelfSignedCert =
    pkgs.runCommand "full-test-stack-self-signed-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
          -subj "/CN=stack" -addext "subjectAltName=DNS:stack" \
          -keyout $out/key.pem -out $out/cert.pem
      '';
  collectorWriteTokenFixture = pkgs.writeText "full-collector-write-token" "full-test-write-token";
in
{
  full-stack-enable-and-go = pkgs.testers.nixosTest {
    name = "victoria-stack-full";

    containers.machine =
      { lib, ... }:
      {
        imports = [
          module
          example
        ];

        services.victoriaStack.vmauth = {
          adminPasswordFile = lib.mkForce "${adminPasswordFixture}";
          readTokensFile = lib.mkForce "${readTokensFixture}";
          writeTokensFile = lib.mkForce "${writeTokensFixture}";
        };
        services.grafana.settings.security = {
          secret_key = lib.mkForce "$__file{${grafanaSecretKeyFixture}}";
          admin_password = lib.mkForce "$__file{${grafanaAdminPasswordFixture}}";
        };
        services.victoriaCollector.writeTokenFile = lib.mkForce "${collectorWriteTokenFixture}";
      };

    testScript = ''
      start_all()

      # Every real unit this configuration stands up.
      machine.wait_for_unit("victoriametrics.service")
      machine.wait_for_unit("victorialogs.service")
      machine.wait_for_unit("victoriatraces.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_unit("grafana.service")
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("mcp-victoriametrics.service")
      machine.wait_for_unit("mcp-victorialogs.service")
      machine.wait_for_unit("mcp-victoriatraces.service")
      machine.wait_for_unit("alloy.service")
      machine.wait_for_unit("systemd-journal-upload.service")

      machine.wait_for_open_port(80)
      machine.wait_for_open_port(3000)
      machine.wait_for_open_port(4204)

      # End-to-end: write through vmauth with the write-tier token,
      # query back through vmauth with the read-tier token. Real OTLP
      # protobuf, not plaintext -- VictoriaMetrics' actual
      # /opentelemetry/v1/metrics handler rejects both a bare
      # "/opentelemetry" path and non-protobuf bodies (confirmed
      # directly against a real instance -- see otlpMetricGenerator's
      # own comment in tests/lib.nix).
      machine.succeed(
          "${otlpMetric} victoria_stack_full_test_metric 1 > /tmp/otlp.bin"
      )
      machine.succeed(
          "curl -sf -X POST -H 'Authorization: Bearer full-test-write-token' "  # gitleaks:allow
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "  # gitleaks:allow
          "'http://127.0.0.1:4204/metrics/api/v1/query?query=victoria_stack_full_test_metric' "
          "| grep -q '\"value\"'"
      )

      # Same end-to-end shape for logs: written directly against the
      # backend's own port (vmauth's only real supported logs write path
      # is systemd-journal-upload's own wire format, exercised for real
      # elsewhere by tests/collector.nix's own cross-container roundtrip
      # -- the read tier's own url_map is a closed allow-list under
      # /select/* only, docs/decisions/0021), queried back through
      # vmauth with the read-tier token.
      machine.succeed(
          "echo '{\"log\":{\"level\":\"info\",\"message\":\"victoria_stack_full_test_log\"}"
          ",\"date\":\"0\",\"stream\":\"full-test\"}' | "
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "  # gitleaks:allow
          "'http://127.0.0.1:4202/insert/jsonline?_stream_fields=stream&_time_field=date&_msg_field=log.message'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "
          "'http://127.0.0.1:4204/logs/select/logsql/query' -d 'query=victoria_stack_full_test_log' "
          "| grep -q victoria_stack_full_test_log"
      )

      # Same end-to-end shape for traces: written through vmauth's
      # write-tier token (the auto-open OTLP ingest door every signal
      # type gets, nixosModule/victoriaStack/vmauth.nix), queried back
      # through vmauth with the read-tier token (Jaeger API).
      machine.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_full_test_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000005\","
          "\"spanId\":\"0000000000000005\","
          "\"name\":\"victoria_stack_full_test_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Authorization: Bearer full-test-write-token' "  # gitleaks:allow
          "-H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4204/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "  # gitleaks:allow
          "'http://127.0.0.1:4204/traces/select/jaeger/api/services' "
          "| grep -q victoria_stack_full_test_service"
      )

      # At least one real MCP tool call, not just the initialize
      # handshake -- confirmed live (mcp-victoriametrics is a stateful,
      # session-based MCP server): initialize first to obtain a session
      # ID, then tools/call against the real "query" tool, retrieving
      # the exact metric this test itself wrote above through the
      # write-tier token earlier.
      machine.succeed(
          "curl -sD /tmp/mcp-headers.txt -u admin:full-test-admin-password -X POST "  # gitleaks:allow
          "'http://127.0.0.1:4204/mcp/metrics' -H 'Content-Type: application/json' "
          "-H 'Accept: application/json, text/event-stream' "
          "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
          "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
          "\"clientInfo\":{\"name\":\"full-stack-test\",\"version\":\"1\"}}}' "
          "-o /tmp/mcp-init.json"
      )
      mcp_session_id = machine.succeed(
          "grep -i mcp-session-id /tmp/mcp-headers.txt | sed 's/.*: //' | tr -d '\\r\\n'"
      )
      mcp_tool_call_body = (
          '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":'
          '{"name":"query","arguments":{"query":"victoria_stack_full_test_metric"}}}'
      )
      mcp_result = machine.succeed(
          f"curl -sf -u admin:full-test-admin-password -X POST "  # gitleaks:allow
          f"'http://127.0.0.1:4204/mcp/metrics' -H 'Content-Type: application/json' "
          f"-H 'Accept: application/json, text/event-stream' "
          f"-H 'Mcp-Session-Id: {mcp_session_id}' "
          f"-d '{mcp_tool_call_body}'"
      )
      assert "victoria_stack_full_test_metric" in mcp_result, (
          f"expected the MCP query tool's real result to contain the "
          f"metric this test wrote: {mcp_result!r}"
      )

      # The same MCP handshake + a real tool call, repeated for the two
      # other ways a client actually arrives: through nginx's /victoria/
      # prefix (nginx -> vmauth -> mcp, not direct to vmauth), and with a
      # read-tier BEARER token instead of the admin Basic credential.
      def mcp_query(url, auth):
          machine.succeed(
              f"curl -sf -D /tmp/mcp-h.txt {auth} -X POST '{url}' "
              "-H 'Content-Type: application/json' "
              "-H 'Accept: application/json, text/event-stream' "
              "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
              "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
              "\"clientInfo\":{\"name\":\"full-stack-test\",\"version\":\"1\"}}}' "
              "-o /dev/null"
          )
          sid = machine.succeed(
              "grep -i mcp-session-id /tmp/mcp-h.txt | sed 's/.*: //' | tr -d '\\r\\n'"
          )
          return machine.succeed(
              f"curl -sf {auth} -X POST '{url}' "
              "-H 'Content-Type: application/json' "
              "-H 'Accept: application/json, text/event-stream' "
              f"-H 'Mcp-Session-Id: {sid}' "
              "-d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":"
              "{\"name\":\"query\",\"arguments\":{\"query\":\"victoria_stack_full_test_metric\"}}}'"
          )

      via_nginx = mcp_query(
          "http://127.0.0.1:80/victoria/mcp/metrics",
          "-u admin:full-test-admin-password",  # gitleaks:allow
      )
      assert "victoria_stack_full_test_metric" in via_nginx, (
          f"MCP tool call through nginx did not return the written metric: {via_nginx!r}"
      )
      via_read_token = mcp_query(
          "http://127.0.0.1:4204/mcp/metrics",
          "-H 'Authorization: Bearer full-test-read-token'",  # gitleaks:allow
      )
      assert "victoria_stack_full_test_metric" in via_read_token, (
          f"MCP tool call with the read-tier bearer token did not return the written metric: {via_read_token!r}"
      )

      # Grafana reachable through nginx, datasources provisioned.
      # wait_until_succeeds, not succeed: Grafana's HTTP port opens
      # before its own startup migrations finish (confirmed directly --
      # this raced and failed with a one-shot curl).  # gitleaks:allow
      machine.wait_until_succeeds("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")
      datasources = machine.succeed(
          "curl -sf -u admin:full-test-grafana-admin-password 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources
    '';
  };

  # Everything at once, the way no smaller test combines it: a custom
  # nginx.domain with operator-added TLS on the stable virtualHost name
  # (ADR 0022), all 3 credential tiers, all 3 backends, all 3 MCP servers,
  # Grafana, the host's own self-monitoring collector, AND a separate
  # remote collector shipping all 3 signals over verified TLS. Any bug
  # this catches should first have a smaller, more specific test.
  maximal-cross-product = pkgs.testers.nixosTest {
    name = "victoria-stack-maximal-cross-product";

    containers.stack =
      { lib, ... }:
      {
        virtualisation.vlans = [ 1 ];
        imports = [
          module
          example
        ];

        services.victoriaStack = {
          vmauth = {
            adminPasswordFile = lib.mkForce "${adminPasswordFixture}";
            readTokensFile = lib.mkForce "${readTokensFixture}";
            writeTokensFile = lib.mkForce "${writeTokensFixture}";
          };
          nginx.domain = "stack";
          # Collectors write to vmauth's own HTTPS door; nginx on 80/443
          # is reads and Grafana only (docs/decisions/0025).
          vmauth.https = {
            enable = true;
            certFile = "${stackSelfSignedCert}/cert.pem";
            keyFile = "${stackSelfSignedCert}/key.pem";
          };
        };
        services.nginx.virtualHosts."victoria-stack" = {
          addSSL = true;
          sslCertificate = "${stackSelfSignedCert}/cert.pem";
          sslCertificateKey = "${stackSelfSignedCert}/key.pem";
        };
        networking.firewall.allowedTCPPorts = [
          80
          443
          8443
        ];
        services.grafana.settings.security = {
          secret_key = lib.mkForce "$__file{${grafanaSecretKeyFixture}}";
          admin_password = lib.mkForce "$__file{${grafanaAdminPasswordFixture}}";
        };
        services.victoriaCollector.writeTokenFile = lib.mkForce "${collectorWriteTokenFixture}";
      };

    containers.collector = {
      virtualisation.vlans = [ 1 ];
      imports = [ nixosModule.nixosModules.victoriaCollector ];
      services.victoriaCollector = {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
        writeEndpoint = "https://stack:8443";
        writeTokenFile = "${collectorWriteTokenFixture}";
        hostType = "edge-device";
        alloy.tlsCaFile = "${stackSelfSignedCert}/cert.pem";
        trustedCertificateFile = "${stackSelfSignedCert}/cert.pem";
      };
    };

    testScript = ''
      start_all()

      for unit in [
          "victoriametrics", "victorialogs", "victoriatraces", "vmauth", "grafana",
          "nginx", "mcp-victoriametrics", "mcp-victorialogs", "mcp-victoriatraces",
          "alloy", "systemd-journal-upload",
      ]:
          stack.wait_for_unit(f"{unit}.service")
      stack.wait_for_open_port(443)
      collector.wait_for_unit("alloy.service")
      collector.wait_for_unit("systemd-journal-upload.service")
      collector.wait_for_open_port(4318)
      for m in (stack, collector):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")
      # network-online.target can be reached even if the collector's address
      # unit failed in the container; fail early and clearly instead of
      # timing out later waiting for data.
      collector.wait_until_succeeds("ping -c 1 stack")

      tls = "--cacert ${stackSelfSignedCert}/cert.pem --resolve stack:443:127.0.0.1"
      base = "https://stack/victoria"

      # Remote collector: all 3 signals over verified TLS, straight to the vmauth HTTPS door.
      collector.succeed("logger --tag victoria-maximal 'victoria_stack_maximal_log_marker'")
      collector.succeed(
          "now=$(date +%s%N); "
          "payload=$(cat <<JSON\n"
          "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
          "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"victoria_stack_maximal_service\"}}"
          "]},\"scopeSpans\":[{\"spans\":[{"
          "\"traceId\":\"00000000000000000000000000000007\","
          "\"spanId\":\"0000000000000007\","
          "\"name\":\"victoria_stack_maximal_span\","
          "\"kind\":1,"
          "\"startTimeUnixNano\":\"$now\","
          "\"endTimeUnixNano\":\"$now\""
          "}]}]}]}\nJSON\n); "
          "curl -sf -X POST -H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4318/v1/traces'"
      )

      # Read each signal back over TLS with the read-tier bearer token.
      read = f"curl -sf {tls} -H 'Authorization: Bearer full-test-read-token'"  # gitleaks:allow
      stack.wait_until_succeeds(
          f"{read} '{base}/metrics/api/v1/query?query=alloy_up' | grep -q collector",
          timeout=180,
      )
      stack.wait_until_succeeds(
          f"{read} '{base}/logs/select/logsql/query' -d 'query=victoria_stack_maximal_log_marker' "
          "| grep -q victoria_stack_maximal_log_marker",
          timeout=180,
      )
      stack.wait_until_succeeds(
          f"{read} '{base}/traces/select/jaeger/api/services' | grep -q victoria_stack_maximal_service",
          timeout=180,
      )

      # The 3 credential tiers over TLS: admin Basic reads, anonymous is
      # refused, a write token cannot read.
      stack.succeed(f"curl -sf {tls} -u admin:full-test-admin-password '{base}/metrics/api/v1/labels'")  # gitleaks:allow
      anon = stack.succeed(f"curl -s {tls} -o /dev/null -w '%{{http_code}}' '{base}/metrics/api/v1/labels'")
      assert anon == "401", f"anonymous read over TLS should be 401, got {anon}"
      wrong_tier = stack.succeed(
          f"curl -s {tls} -o /dev/null -w '%{{http_code}}' "
          f"-H 'Authorization: Bearer full-test-write-token' '{base}/metrics/api/v1/labels'"  # gitleaks:allow
      )
      # vmauth answers an authenticated user with no matching route (the
      # write tier has no read routes) with 400, not 401.
      assert wrong_tier in ("400", "401", "403"), f"write token must not read, got {wrong_tier}"

      # All 3 MCP servers reachable over TLS with the read-tier token.
      for svc in ("metrics", "logs", "traces"):
          code = stack.succeed(
              f"curl -s {tls} -o /dev/null -w '%{{http_code}}' -X POST "
              f"-H 'Authorization: Bearer full-test-read-token' "  # gitleaks:allow
              "-H 'Content-Type: application/json' "
              "-H 'Accept: application/json, text/event-stream' "
              "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
              "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
              "\"clientInfo\":{\"name\":\"maximal\",\"version\":\"1\"}}}' "
              f"'{base}/mcp/{svc}'"
          )
          assert code == "200", f"MCP {svc} over TLS: expected 200, got {code}"

      # Grafana through the same TLS front, datasources provisioned.
      stack.wait_until_succeeds(f"curl -sf {tls} 'https://stack/grafana/login' | grep -qi grafana")
      datasources = stack.succeed(
          "curl -sf -u admin:full-test-grafana-admin-password 'http://127.0.0.1:3000/api/datasources'"  # gitleaks:allow
      )
      for marker in ("victoriametrics-metrics-datasource", "victoriametrics-logs-datasource", "jaeger"):
          assert marker in datasources, f"missing datasource {marker}: {datasources!r}"
    '';
  };
}
