{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  # The real NixOS module tree (not a hand-rolled minimal one): our own
  # module's config.nix files reference genuine NixOS options
  # (systemd.services.*, users.users.*, systemd.tmpfiles.rules) that only
  # exist once nixos/modules/module-list.nix itself is in scope. An earlier,
  # more minimal `lib.evalModules [ assertions.nix ourModule ]` harness
  # worked fine for Phase 2 (before any config.nix touched a real option),
  # but broke the moment metrics.nix landed ("The option `systemd` does not
  # exist") -- using the real module tree is the necessary fix, not a
  # shortcut. This DOES surface some unrelated pre-existing
  # assertions/warnings from base NixOS modules in the raw list (missing
  # `system.stateVersion`, bootloader, etc.) -- callers filter to just our
  # own module's own messages (all of which start with
  # "services.victoriaStack") rather than demanding a literal empty list.
  #
  # Generalized to accept which module tree(s) to evaluate against --
  # previously hardcoded to victoriaStack only, which meant
  # tests/collector.nix had to roll its own near-identical ad-hoc harness
  # the moment it needed an eval-only check (confirmed real drift, not
  # hypothetical: two parallel copies of this exact function existed
  # before this unification). `evalWith`/`evalWithCollector` below are
  # both just `mkEvalWith` applied to a different base module list --
  # one definition, not two to keep in sync by hand.
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
in
{
  inherit
    evalWith
    evalWithCollector
    mkAssertionFiresCheck
    mkNoAssertionsFireCheck
    mkWarningFiresCheck
    mkNoWarningsCheck
    otlpMetricGenerator
    otlpTestPython
    ;
}
