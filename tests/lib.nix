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
  # "/opentelemetry" path (sans "/v1/metrics"): VictoriaMetrics returns
  # "unsupported path requested" and, separately, "json encoding isn't
  # supported for opentelemetry format. Use protobuf encoding". This
  # generates a valid, minimal OTLP ExportMetricsServiceRequest protobuf
  # payload at test run time (the timestamp must be current when the
  # request is sent, not baked in at Nix build time) using nixpkgs'
  # python3Packages.opentelemetry-proto. Instant queries need
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

  # Test-script snippet for NEGATIVE write controls. A control that POSTs a
  # junk body to the bare path /opentelemetry is rejected by the BACKEND with a
  # 4xx anyway, so it passes even when vmauth lets the request through. This
  # posts a genuinely valid OTLP body to the real ingest path and returns
  # (http_status, body), so an assertion on vmauth's own answer (401 "missing
  # 'Authorization'", 401 "Unauthorized", 400 "missing route") proves vmauth, not
  # the backend, refused it. Measured against vmauth.
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
  # loosened key in any of them is a failure.
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

  # The readiness probe of one eval'd unit (readiness.nix renders ExecStartPost
  # as `<store path> <unit> <deadline seconds> <kind> <target>`): its
  # executable and the four arguments, null when the unit has no such probe.
  # Targets that need shell quoting are not handled; pin those separately.
  readinessProbe =
    unit:
    let
      words = lib.splitString " " (unit.serviceConfig.ExecStartPost or "");
    in
    if builtins.length words == 5 then
      {
        exe = builtins.head words;
        unit = builtins.elemAt words 1;
        deadline = builtins.elemAt words 2;
        kind = builtins.elemAt words 3;
        target = builtins.elemAt words 4;
      }
    else
      null;

  # Seconds the probe waits and of TimeoutStartSec for one eval'd unit; each is
  # null when absent or not in whole seconds. Callers pin both the values and
  # the gap between them.
  probeAndStartSeconds =
    unit:
    let
      seconds = m: if m == null then null else lib.toIntBase10 (builtins.head m);
      probe = readinessProbe unit;
    in
    {
      probe = if probe == null then null else seconds (builtins.match "([0-9]+)" probe.deadline);
      start = seconds (builtins.match "([0-9]+)s" (unit.serviceConfig.TimeoutStartSec or ""));
    };

  # Names of the profile's keys that a serviceConfig lacks or sets differently.
  hardeningDiff = sc: lib.attrNames (lib.filterAttrs (k: v: (sc.${k} or null) != v) hardeningProfile);

  # Test-script snippet: one request, answered as (http_status, body). For
  # negative controls that must name WHO refused: vmauth says 401 "missing
  # 'Authorization'" / 401 "Unauthorized" / 400 "... missing route ..." (see
  # otlpTestPython for why a bare `curl -sf` is too weak a control).
  httpTestPython = ''
    def http(machine, url, auth="", extra=""):
        out = machine.succeed(f"curl -s -w '\\n%{{http_code}}' {auth} {extra} '{url}'")
        body, code = out.rsplit("\n", 1)
        return code.strip(), body
  '';

  # Test-script snippet replacing `machine.wait_for_unit` for MODULE units.
  # They carry Restart=on-failure/always, so a unit that cannot start never
  # reaches "failed": systemd cycles it as `activating (auto-restart)` and
  # wait_for_unit burns its whole 900s timeout. The storage units are worse:
  # their postStart readiness probe (up to 5m) keeps the unit in
  # `activating (start-post)` after the main process already died, so even the
  # first restart is 5m away. This fails as soon as the unit is failed, has
  # auto-restarted `max_restarts` times, or sits in start-post with no main
  # process left; the message carries the unit's journal. `timeout` only
  # bounds a healthy-but-slow start (a live main process and no restarts).
  #
  # `max_restarts=None` is for a unit that retries BY DESIGN while its peer is
  # down (systemd-journal-upload: it exits on every refused connection and
  # startLimitIntervalSec = 0 keeps it cycling). Its restart count says nothing
  # about health, and it sits `activating (auto-restart)` between attempts, so
  # any count trips on a unit that is merely early; only `failed` and `timeout`
  # remain. Alloy and the module's own units do not exit while waiting, so they
  # keep the default.
  waitActivePython = ''
    def wait_active(machine, unit, timeout=900, max_restarts=2):
        import time
        deadline = time.monotonic() + timeout
        while True:
            props = dict(
                line.split("=", 1)
                for line in machine.succeed(
                    f"systemctl show -p ActiveState,SubState,NRestarts,Result,Type,MainPID {unit}"
                ).splitlines()
            )
            if props["ActiveState"] == "active":
                return
            main_gone = (
                props["SubState"] == "start-post"
                and props["MainPID"] == "0"
                and props["Type"] in ("simple", "exec", "notify", "idle")
            )
            broken = (
                props["ActiveState"] == "failed"
                or (max_restarts is not None and int(props["NRestarts"]) >= max_restarts)
                or main_gone
            )
            if broken or time.monotonic() > deadline:
                _, journal = machine.execute(f"journalctl -u {unit} -n 30 --no-pager")
                # The probe's retry spam can fill the tail and bury the main
                # process's own error.
                _, main_log = machine.execute(
                    f"journalctl -u {unit} --no-pager | grep -v 'post-start\\[' | tail -n 15"
                )
                why = "failed or restart-looping" if broken else f"not active after {timeout}s"
                assert False, (
                    f"{unit} {why} ({props}); journal:\n{journal}\n"
                    f"without post-start probe lines:\n{main_log}"
                )
            time.sleep(1)
  '';

  # Test-script snippet: start a unit whose main process dies at once and
  # assert that the probe ended the start with its own "main process exited"
  # message and not with its deadline message ("not ready after Ns"). Returns
  # the seconds from systemd's "Starting" line to its first "Failed with
  # result" line (RestartSec=5 spaces the later cycles), both stamps from the
  # guest's monotonic journal, for the caller to print. Which message ends the
  # start is the load-independent signal: a wall-clock bound failed on a loaded
  # build server (the unit's start itself took 11s before its main process ran).
  # Without the probe's main-process check only the deadline message ever
  # appears, so the wait ends at the unit's deadline and the assertion fails.
  # The unit must not be wantedBy anything: a unit failing in a loop keeps the
  # container's boot job pending.
  brokenUnitFailureSeconds = ''
    def broken_unit_failure_seconds(machine, unit):
        import re
        machine.succeed(f"systemctl start --no-block {unit}")
        verdict = f"{unit}: main process exited before becoming ready"
        late = f"{unit}: not ready after"
        # Longer than any default deadline (300s): the wait ends on whichever
        # message the probe logs first, so it is event-driven, not a time bound.
        machine.wait_until_succeeds(
            f"journalctl -u {unit} --no-pager | grep -qE '{verdict}|{late}'", timeout=400
        )
        journal = machine.succeed(f"journalctl -u {unit} -o short-monotonic --no-pager")
        assert verdict in journal and late not in journal, (
            f"{unit}: the start ended at the probe's deadline, not at the main process exiting; journal:\n{journal[-3000:]}"
        )

        def stamp(marker):
            line = next(l for l in journal.splitlines() if marker in l)
            m = re.match(r"\[\s*([0-9.]+)\]", line)
            assert m is not None, line
            return float(m.group(1))

        # systemd counts the start as failed, not only the probe: the unit
        # leaves `activating` (Restart=on-failure then cycles it).
        machine.wait_until_succeeds(
            f"systemctl show -p NRestarts,ActiveState {unit} | grep -qE 'NRestarts=[1-9]|ActiveState=failed'",
            timeout=60,
        )
        return stamp("Failed with result") - stamp("Starting ")
  '';

  # Boot tests import this so a storage unit that cannot start fails in 2 minutes
  # rather than 5 (wait_active above ends earlier only when the main process is
  # gone). The slowest healthy storage start in the nspawn tests was 15s with the
  # whole suite building at once, so 2m keeps about 8x headroom. mkDefault: a test
  # of the option itself sets its own value.
  testStartupTimeouts = {
    services.victoriaStack = lib.genAttrs [ "metrics" "logs" "traces" ] (_: {
      startupTimeout = lib.mkDefault "2m";
    });
  };
  # Sends one syslog message the way a device would: RFC 3164 or 5424, over
  # UDP, TCP (newline or octet-counting framing) or TLS, with a timestamp of
  # "now" (VictoriaLogs infers the year of an RFC 3164 stamp).
  syslogSend =
    pkgs.writers.writePython3Bin "syslog-send"
      {
        flakeIgnore = [
          "E501"
          "E302"
          "E305"
          "E231"
          "E722"
        ];
      }
      ''
        import argparse
        import datetime
        import socket
        import ssl

        p = argparse.ArgumentParser()
        p.add_argument("--proto", choices=["udp", "tcp", "tls"], required=True)
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, required=True)
        p.add_argument("--format", choices=["3164", "5424", "raw"], default="3164")
        p.add_argument("--framing", choices=["newline", "octet"], default="newline")
        p.add_argument("--hostname", default="testhost")
        p.add_argument("--cacert")
        p.add_argument("--tls-max", choices=["1.2", "1.3"], default="1.3")
        p.add_argument("--client-cert")
        p.add_argument("--client-key")
        p.add_argument("message")
        a = p.parse_args()

        now = datetime.datetime.now(datetime.timezone.utc)
        if a.format == "3164":
            ts = now.strftime("%b %e %H:%M:%S")
            line = f"<34>{ts} {a.hostname} su[1234]: {a.message}"
        elif a.format == "5424":
            ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
            line = f'<165>1 {ts} {a.hostname} evntslog 4321 ID47 [exampleSDID@32473 iut="3" eventSource="Application"] {a.message}'
        else:
            line = a.message
        data = line.encode()
        if a.proto != "udp":
            data = f"{len(data)} ".encode() + data if a.framing == "octet" else data + b"\n"

        if a.proto == "udp":
            s = socket.socket(socket.AF_INET6 if ":" in a.host else socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(data, (a.host, a.port))
        else:
            s = socket.create_connection((a.host, a.port), timeout=10)
            if a.proto == "tls":
                ctx = ssl.create_default_context(cafile=a.cacert)
                if a.tls_max == "1.2":
                    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
                if a.client_cert:
                    ctx.load_cert_chain(a.client_cert, a.client_key)
                s = ctx.wrap_socket(s, server_hostname=a.host)
                print(s.version())
            s.sendall(data)
            # Close the way a well-behaved sender does. Closing a TLS 1.3 socket
            # with unread session tickets resets the connection, and the reset
            # discards the message the server had not read yet.
            if a.proto == "tls":
                s = s.unwrap()
            s.shutdown(socket.SHUT_WR)
            s.settimeout(3)
            try:
                while s.recv(4096):
                    pass
            except OSError:
                # The data is already sent; a peer that resets while draining
                # (it refused the stream) changes nothing for the sender.
                pass
        s.close()
      '';

  # Throwaway server certificates (the SAN must cover the address the client
  # dials); generated at build time, never committed.
  mkCert =
    cn: san:
    pkgs.runCommand "syslog-test-cert-${cn}" { nativeBuildInputs = [ pkgs.openssl ]; } ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
        -subj "/CN=${cn}" -addext "subjectAltName=${san}" \
        -keyout $out/key.pem -out $out/cert.pem
    '';
in
{
  inherit
    waitActivePython
    brokenUnitFailureSeconds
    testStartupTimeouts
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
    probeAndStartSeconds
    readinessProbe
    otlpMetricGenerator
    otlpTestPython
    httpTestPython
    syslogSend
    mkCert
    ;
}
