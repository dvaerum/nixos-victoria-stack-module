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
      - full-test-read-token
  '';
  writeTokensFixture = pkgs.writeText "full-write-tokens.yaml" ''
    tokens:
      - full-test-write-token
  '';
  grafanaSecretKeyFixture = pkgs.writeText "full-grafana-secret-key" "full-test-grafana-secret-key";
  grafanaAdminPasswordFixture = pkgs.writeText "full-grafana-admin-password" "full-test-grafana-admin-password";
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
          "curl -sf -X POST -H 'Authorization: Bearer full-test-write-token' "
          "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp.bin "
          "'http://127.0.0.1:4204/opentelemetry/v1/metrics'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "
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
          "curl -sf -X POST -H 'Content-Type: application/stream+json' --data-binary @- "
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
          "curl -sf -X POST -H 'Authorization: Bearer full-test-write-token' "
          "-H 'Content-Type: application/json' --data-binary \"$payload\" "
          "'http://127.0.0.1:4204/insert/opentelemetry/v1/traces'"
      )
      machine.wait_until_succeeds(
          "curl -sf -H 'Authorization: Bearer full-test-read-token' "
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
          "curl -sD /tmp/mcp-headers.txt -u admin:full-test-admin-password -X POST "
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
          f"curl -sf -u admin:full-test-admin-password -X POST "
          f"'http://127.0.0.1:4204/mcp/metrics' -H 'Content-Type: application/json' "
          f"-H 'Accept: application/json, text/event-stream' "
          f"-H 'Mcp-Session-Id: {mcp_session_id}' "
          f"-d '{mcp_tool_call_body}'"
      )
      assert "victoria_stack_full_test_metric" in mcp_result, (
          f"expected the MCP query tool's real result to contain the "
          f"metric this test wrote: {mcp_result!r}"
      )

      # Grafana reachable through nginx, datasources provisioned.
      # wait_until_succeeds, not succeed: Grafana's HTTP port opens
      # before its own startup migrations finish (confirmed directly --
      # this raced and failed with a one-shot curl).
      machine.wait_until_succeeds("curl -sf 'http://127.0.0.1:80/grafana/login' | grep -qi grafana")
      datasources = machine.succeed(
          "curl -sf -u admin:full-test-grafana-admin-password 'http://127.0.0.1:3000/api/datasources'"
      )
      assert "victoriametrics-metrics-datasource" in datasources
      assert "victoriametrics-logs-datasource" in datasources
      assert "jaeger" in datasources
    '';
  };
}
