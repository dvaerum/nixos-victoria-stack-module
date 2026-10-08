{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  # The real NixOS module tree (not a hand-rolled minimal one): the stack
  # modules reference genuine NixOS options (systemd.services.*,
  # users.users.*, systemd.tmpfiles.rules) that only exist once
  # nixos/modules/module-list.nix is in scope ("The option `systemd` does
  # not exist" otherwise). This DOES surface some unrelated pre-existing
  # assertions/warnings from base NixOS modules in the raw list (missing
  # `system.stateVersion`, bootloader, etc.) -- callers filter to just our
  # own module's own messages (all of which start with
  # "services.victoriaStack") rather than demanding a literal empty list.
  #
  # Takes the module tree(s) to evaluate against so collector tests share
  # this one harness; `evalWith`/`evalWithCollector` below are `mkEvalWith`
  # applied to different base module lists.
  mkEvalWith =
    baseModules: extraModule:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs) system;
      modules = baseModules ++ [
        extraModule
        {
          # Silences the stateVersion warning noise, nothing more --
          # doesn't affect our own module's own assertions/warnings.
          system.stateVersion = lib.trivial.release;
        }
      ];
    };

  evalWith = mkEvalWith [ nixosModule.nixosModules.victoriaStack ];
  evalWithCollector = mkEvalWith [ nixosModule.nixosModules.victoriaCollector ];

  ownMessages = lib.filter (lib.hasInfix "services.victoriaStack");

  mkAssertionFiresCheck =
    {
      name,
      module,
      expectMessageSubstring,
    }:
    let
      evaluated = evalWith module;
      failedOwn = ownMessages (
        map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
      );
      matching = builtins.filter (lib.hasInfix expectMessageSubstring) failedOwn;
    in
    pkgs.runCommand "${name}" { } (
      if matching != [ ] then
        "echo OK > $out"
      else
        throw ''
          expected a failed assertion containing "${expectMessageSubstring}" for check "${name}", but none was found.
          Our own failed assertions were: ${builtins.toJSON failedOwn}
        ''
    );

  # The failed own assertions are EXACTLY these messages, whole: a substring
  # such as "mcp" or "vmauth" is satisfied by any neighbouring assertion.
  mkAssertionMessagesAreCheck =
    {
      name,
      module,
      expected,
    }:
    let
      evaluated = evalWith module;
      failedOwn = ownMessages (
        map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
      );
    in
    pkgs.runCommand "${name}" { } (
      if failedOwn == expected then
        "echo OK > $out"
      else
        throw ''
          check "${name}": the failed assertions differ.
          expected: ${builtins.toJSON expected}
          got:      ${builtins.toJSON failedOwn}
        ''
    );

  mkNoAssertionsFireCheck =
    { name, module }:
    let
      evaluated = evalWith module;
      failedOwn = ownMessages (
        map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
      );
    in
    pkgs.runCommand "${name}" { } (
      if failedOwn == [ ] then
        "echo OK > $out"
      else
        throw ''
          expected no failed assertions of our own for check "${name}", but found some.
          Failed: ${builtins.toJSON failedOwn}
        ''
    );

  mkWarningFiresCheck =
    {
      name,
      module,
      expectMessageSubstring,
    }:
    let
      evaluated = evalWith module;
      ownWarnings = ownMessages evaluated.config.warnings;
      matching = builtins.filter (lib.hasInfix expectMessageSubstring) ownWarnings;
    in
    pkgs.runCommand "${name}" { } (
      if matching != [ ] then
        "echo OK > $out"
      else
        throw ''
          expected a warning containing "${expectMessageSubstring}" for check "${name}", but none was found.
          Our own warnings were: ${builtins.toJSON ownWarnings}
        ''
    );

  mkNoWarningsCheck =
    { name, module }:
    let
      evaluated = evalWith module;
      ownWarnings = ownMessages evaluated.config.warnings;
    in
    pkgs.runCommand "${name}" { } (
      if ownWarnings == [ ] then
        "echo OK > $out"
      else
        throw ''
          expected no warnings of our own for check "${name}", but found some.
          Our own warnings were: ${builtins.toJSON ownWarnings}
        ''
    );

  # VictoriaMetrics' real OTLP metrics endpoint (/opentelemetry/v1/metrics,
  # the one vmauth's auto-open ingest route actually proxies to) rejects
  # both the plaintext Prometheus-exposition body AND the bare
  # "/opentelemetry" path (sans "/v1/metrics") that every test in this
  # suite previously sent -- confirmed directly: VictoriaMetrics returns
  # "unsupported path requested" and, separately, "json encoding isn't
  # supported for opentelemetry format. Use protobuf encoding". Every
  # `machine.succeed(curl .../opentelemetry')` write-path test was
  # therefore broken from day one, just never caught until container-boot
  # checks could actually execute (this environment's `uid-range`
  # limitation, resolved separately). This generates a genuinely valid,
  # minimal OTLP ExportMetricsServiceRequest protobuf payload at test run
  # time (the timestamp must be current when the request is actually
  # sent, not baked in at Nix build time) using nixpkgs'
  # python3Packages.opentelemetry-proto -- confirmed against a real
  # VictoriaMetrics instance, including that instant queries need
  # `wait_until_succeeds` to tolerate -search.latencyOffset's ~30s
  # default delay before "now"-relative queries see freshly-ingested data.
  otlpMetricGenerator =
    pkgs.writers.writePython3Bin "gen-otlp-metric"
      {
        libraries = [ pkgs.python3Packages.opentelemetry-proto ];
      }
      ''
        import sys
        import time
        from opentelemetry.proto.collector.metrics.v1.metrics_service_pb2 import (
            ExportMetricsServiceRequest,
        )
        from opentelemetry.proto.common.v1.common_pb2 import AnyValue

        metric_name = sys.argv[1]
        metric_value = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

        req = ExportMetricsServiceRequest()
        rm = req.resource_metrics.add()
        svc_name = AnyValue(string_value="victoria-stack-test")
        rm.resource.attributes.add(key="service.name", value=svc_name)
        sm = rm.scope_metrics.add()
        m = sm.metrics.add()
        m.name = metric_name
        dp = m.gauge.data_points.add()
        dp.time_unix_nano = time.time_ns()
        dp.as_double = metric_value

        sys.stdout.buffer.write(req.SerializeToString())
      '';

  # Test-script snippet for NEGATIVE write controls. The old controls POSTed a
  # junk body to the bare path /opentelemetry, which the BACKEND rejects with a
  # 4xx anyway, so they passed even when vmauth let the request through. This
  # posts a genuinely valid OTLP body to the real ingest path and returns
  # (http_status, body), so an assertion on vmauth's own answer (401 "missing
  # 'Authorization'", 401 "Unauthorized", 400 "missing route") proves vmauth, not
  # the backend, refused it. Measured against vmauth 1.153.
  otlpTestPython = ''
    def otlp_status(machine, url, auth=""):
        machine.succeed("${otlpMetricGenerator}/bin/gen-otlp-metric victoria_stack_negative_control 1 > /tmp/otlp-probe.bin")
        out = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' {auth} -X POST "
            "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/otlp-probe.bin "
            f"'{url}'"
        )
        body, code = out.rsplit("\n", 1)
        return code.strip(), body
  '';

  # The pair Grafana needs (grafana.readTokenFile + the same token in
  # vmauth.readTokensFile); obviously fake values for throwaway containers.
  grafanaReadToken = "grafana-fixture-read-token"; # gitleaks:allow
  grafanaReadTokenFile = pkgs.writeText "grafana-read-token" grafanaReadToken;
  vmauthReadTokensWithGrafana = pkgs.writeText "vmauth-read-tokens-with-grafana.yaml" ''
    tokens:
      - token: ${grafanaReadToken}
  '';

  # The systemd hardening profile the storage services, vmauth and the MCP
  # servers all carry (docs/decisions/0015), spelled out in full so a dropped or
  # loosened key in any of them is a failure, not just the handful that used to
  # be spot-checked.
  hardeningProfile = {
    DeviceAllow = [ "/dev/null rw" ];
    DevicePolicy = "strict";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "mincore"
    ];
  };

  # Names of the profile's keys that a serviceConfig lacks or sets differently.
  hardeningDiff = sc: lib.attrNames (lib.filterAttrs (k: v: (sc.${k} or null) != v) hardeningProfile);

  # Test-script snippet: one request, answered as (http_status, body). For
  # negative controls that must name WHO refused: vmauth says 401 "missing
  # 'Authorization'" / 401 "Unauthorized" / 400 "... missing route ...", while a
  # bare `curl -sf` failing only proves some refusal happened (a backend 4xx, a
  # connection error). Measured against vmauth 1.153.
  httpTestPython = ''
    def http(machine, url, auth="", extra=""):
        out = machine.succeed(f"curl -s -w '\\n%{{http_code}}' {auth} {extra} '{url}'")
        body, code = out.rsplit("\n", 1)
        return code.strip(), body
  '';
in
{
  inherit
    grafanaReadToken
    grafanaReadTokenFile
    vmauthReadTokensWithGrafana
    evalWith
    evalWithCollector
    mkAssertionFiresCheck
    mkAssertionMessagesAreCheck
    mkNoAssertionsFireCheck
    mkWarningFiresCheck
    mkNoWarningsCheck
    hardeningProfile
    hardeningDiff
    otlpMetricGenerator
    otlpTestPython
    httpTestPython
    ;
}
