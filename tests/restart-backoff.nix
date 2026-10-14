{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  stackModule = nixosModule.nixosModules.victoriaStack;
  collectorModule = nixosModule.nixosModules.victoriaCollector;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith evalWithCollector;

  # Units that restart themselves and carry the module's backoff, and the ones
  # that must not: nixpkgs-owned units keep their own policy, helpers never restart.
  backedOff = {
    stack = [
      "victoriametrics"
      "victorialogs"
      "victoriatraces"
      "vmauth"
      "mcp-victoriametrics"
      "mcp-victorialogs"
      "mcp-victoriatraces"
    ];
    collector = [ "alloy" ];
  };

  stackEval = evalWith {
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
      grafana.enable = true;
    };
    services.grafana.enable = true;
  };
  collectorEval = evalWithCollector {
    services.victoriaCollector = {
      metrics.enable = true;
      logs.enable = true;
      writeEndpoint = "http://127.0.0.1:4210";
      writeTokenFile = "/var/lib/backoff/token";
      hostType = "server";
    };
  };

  # Real boot of one broken unit per class. `delays` returns the seconds each
  # automatic restart waited (stamps from the guest's monotonic journal, so a
  # loaded host cannot skew them): from the failure to the "Scheduled restart
  # job" line that systemd logs when the delay is over.
  delaysPython = ''
    def restart_delays(machine, unit, restarts=6, timeout=300):
        import re
        import time
        deadline = time.monotonic() + timeout
        while True:
            journal = machine.succeed(f"journalctl -u {unit} -o short-monotonic --no-pager")
            lines = journal.splitlines()
            if sum("Scheduled restart job" in l for l in lines) >= restarts:
                break
            assert time.monotonic() < deadline, f"{unit}: fewer than {restarts} restarts in {timeout}s:\n{journal[-3000:]}"
            time.sleep(2)
        def stamp(l):
            m = re.match(r"\[\s*([0-9.]+)\]", l)
            assert m is not None, l
            return float(m.group(1))

        delays, failed_at = [], None
        for l in lines:
            if "Failed with result" in l:
                failed_at = stamp(l)
            elif "Scheduled restart job" in l and failed_at is not None:
                delays.append(round(stamp(l) - failed_at, 1))
                failed_at = None
        return delays[:restarts]

    # Measured over 2 boots: every delay is within 0.3 s of the nominal one
    # (5, 9, 16.5, 30 s; Alloy 2, 5, 12, 30 s), so the 0.5-2 s windows below
    # have at least 6x headroom.
    def assert_backoff(unit, delays, first, cap=30):
        print(f"{unit}: restart delays {delays}")
        assert first - 0.5 <= delays[0] <= first + 2, f"{unit}: first retry {delays[0]}s, RestartSec is {first}"
        assert delays[2] > delays[0] + 5, f"{unit}: third retry {delays[2]}s is not clearly longer than the first {delays[0]}s: {delays}"
        assert all(a <= b + 1 for a, b in zip(delays, delays[1:])), f"{unit}: delays shrink: {delays}"
        assert max(delays) <= cap + 2, f"{unit}: a retry waited {max(delays)}s, the cap is {cap}s: {delays}"
        assert delays[4] >= cap - 5, f"{unit}: the fifth retry ({delays[4]}s) has not reached the {cap}s cap: {delays}"
  '';

  pinsCheck =
    name: services: expected:
    pkgs.runCommand name { } (
      let
        withSteps = lib.attrNames (
          lib.filterAttrs (_: s: (s.serviceConfig.RestartSteps or null) != null) services
        );
        wrong = lib.filter (
          u:
          let
            sc = services.${u}.serviceConfig;
          in
          (sc.RestartSteps or null) != 3 || (sc.RestartMaxDelaySec or null) != 30
        ) expected;
        missing = lib.filter (u: !(services ? ${u})) expected;
        unexpected = lib.subtractLists expected withSteps;
      in
      if missing == [ ] && wrong == [ ] && unexpected == [ ] then
        "echo OK > $out"
      else
        throw "restart backoff: missing units ${toString missing}; not RestartSteps=3/RestartMaxDelaySec=30: ${toString wrong}; carry it but must not: ${toString unexpected}"
    );
in
{
  stack-units-carry-the-backoff-and-the-others-do-not =
    pinsCheck "restart-backoff-stack" stackEval.config.systemd.services
      backedOff.stack;

  cluster-units-carry-the-backoff-and-nothing-else-does =
    pinsCheck "restart-backoff-cluster"
      (evalWith {
        services.victoriaStack.metrics = {
          enable = true;
          mode = "cluster";
        };
      }).config.systemd.services
      [
        "vmstorage"
        "vminsert"
        "vmselect"
        # vmauth comes on with the metrics database.
        "vmauth"
      ];

  collector-alloy-carries-the-backoff-and-the-others-do-not =
    pinsCheck "restart-backoff-collector" collectorEval.config.systemd.services
      backedOff.collector;

  # Alloy keeps nixpkgs' own first delay: the backoff only adds the growth.
  collector-alloy-keeps-nixpkgs-restart-sec =
    pkgs.runCommand "restart-backoff-alloy-restart-sec" { }
      (
        let
          sc = collectorEval.config.systemd.services.alloy.serviceConfig;
        in
        if sc.RestartSec == 2 && sc.Restart == "always" then
          "echo OK > $out"
        else
          throw "alloy: RestartSec=${toString sc.RestartSec} Restart=${sc.Restart}, expected nixpkgs' 2 and always"
      );

  broken-stack-units-back-off = pkgs.testers.nixosTest {
    name = "victoria-stack-broken-units-back-off";

    containers.machine = {
      imports = [
        stackModule
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
          extraFlags = [ "-noSuchFlag=1" ];
          mcp = {
            enable = true;
            package = pkgs.writeShellScriptBin "mcp-victoriametrics" "exit 3";
          };
        };
        logs = {
          enable = true;
          dynamicUser = false;
          extraFlags = [ "-noSuchFlag=1" ];
        };
        vmauth.extraFlags = [ "-noSuchFlag=1" ];
      };
      # A unit failing in a loop keeps the container's boot job pending.
      systemd.services =
        lib.genAttrs [ "victoriametrics" "victorialogs" "vmauth" "mcp-victoriametrics" ]
          (_: {
            wantedBy = lib.mkForce [ ];
          });
    };

    testScript = ''
      ${delaysPython}
      start_all()
      machine.wait_for_unit("multi-user.target")
      units = ["victoriametrics", "victorialogs", "vmauth", "mcp-victoriametrics"]
      for u in units:
          machine.succeed(f"systemctl start --no-block {u}.service")
      for u in units:
          assert_backoff(u, restart_delays(machine, f"{u}.service"), first=5)
    '';
  };

  # All three at once: vminsert and vmselect `want` vmstorage, and a start job
  # for a unit waiting out its backoff would cut that wait short. Each unit's
  # delays must still be the nominal 5, 9, 16.5, 30 s.
  broken-cluster-units-back-off = pkgs.testers.nixosTest {
    name = "victoria-stack-broken-cluster-units-back-off";

    containers.machine = {
      imports = [
        stackModule
        testLib.testStartupTimeouts
      ];
      services.victoriaStack.metrics = {
        enable = true;
        mode = "cluster";
        extraFlags = [ "-noSuchFlag=1" ];
        insert.extraFlags = [ "-noSuchFlag=1" ];
        storage.extraFlags = [ "-noSuchFlag=1" ];
      };
      # A unit failing in a loop keeps the container's boot job pending.
      systemd.services = lib.genAttrs [ "vmstorage" "vminsert" "vmselect" ] (_: {
        wantedBy = lib.mkForce [ ];
      });
    };

    testScript = ''
      ${delaysPython}
      start_all()
      machine.wait_for_unit("multi-user.target")
      units = ["vmstorage", "vminsert", "vmselect"]
      for u in units:
          machine.succeed(f"systemctl start --no-block {u}.service")
      for u in units:
          assert_backoff(u, restart_delays(machine, f"{u}.service"), first=5)
    '';
  };

  broken-alloy-backs-off = pkgs.testers.nixosTest {
    name = "victoria-collector-broken-alloy-backs-off";

    containers.collector = {
      imports = [ collectorModule ];
      systemd.tmpfiles.rules = [
        "d /var/lib/backoff 0700 root root -"
        "f /var/lib/backoff/token 0600 root root - tokens:\\n  - token: invalid-token-one\\n" # gitleaks:allow
      ];
      services.victoriaCollector = {
        metrics.enable = true;
        writeEndpoint = "http://127.0.0.1:4210";
        writeTokenFile = "/var/lib/backoff/token";
        hostType = "server";
      };
    };

    testScript = ''
      ${delaysPython}
      start_all()
      collector.wait_for_unit("multi-user.target")
      assert_backoff("alloy", restart_delays(collector, "alloy.service"), first=2)
    '';
  };
}
