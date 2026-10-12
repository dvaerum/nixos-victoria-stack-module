{ pkgs, nixosModule }:

let
  testLib = import ./lib.nix { inherit pkgs nixosModule; };

  # Fails its first `$2` starts and succeeds from then on, counting in /run.
  # Used as ExecStartPre= so the unit cycles through auto-restarts the way a
  # unit waiting for its peer does, and then becomes active.
  flapGate = pkgs.writeShellApplication {
    name = "flap-gate";
    text = ''
      state=/run/$1.count
      n=0
      [ ! -f "$state" ] || n=$(<"$state")
      echo $((n + 1)) >"$state"
      [ "$n" -ge "$2" ]
    '';
  };
in
{
  # wait_active (tests/lib.nix) is what every boot test waits on, and the rest
  # of the suite only ever sees it either succeed at once or fail on a broken
  # unit. This drives its three decisions with transient units that auto-restart
  # `fails` times before starting for good.
  wait-active-restart-tolerance = pkgs.testers.nixosTest {
    name = "victoria-stack-wait-active-restart-tolerance";

    containers.machine = { };

    testScript = ''
      ${testLib.waitActivePython}
      start_all()
      machine.wait_for_unit("multi-user.target")

      def flapping(name, fails):
          machine.succeed(
              f"systemd-run --no-block --unit={name} --collect "
              "--property=Restart=on-failure --property=RestartSec=3 "
              "--property=StartLimitIntervalSec=0 "
              f"--property=ExecStartPre='${flapGate}/bin/flap-gate {name} {fails}' "
              "sleep infinity"
          )

      def restarts(name):
          return int(machine.succeed(f"systemctl show -p NRestarts --value {name}.service").strip())

      # One restart before it comes up is healthy under the default limit of 2.
      flapping("flap-once", 1)
      wait_active(machine, "flap-once.service", timeout=60)
      assert restarts("flap-once") == 1, restarts("flap-once")

      # Three restarts: the default gives up with the restart-count message ...
      flapping("flap-thrice", 3)
      try:
          wait_active(machine, "flap-thrice.service", timeout=60)
      except AssertionError as e:
          msg = str(e)
          assert "failed or restart-looping" in msg, msg
          # ... and it is the restart count that tripped it, not a failed unit.
          assert "'ActiveState': 'activating'" in msg and any(f"'NRestarts': '{n}'" in msg for n in (2, 3)), msg
      else:
          raise Exception("wait_active returned for a unit that restarted twice before becoming active")

      # ... while max_restarts=None tolerates the restarts and waits for the unit.
      wait_active(machine, "flap-thrice.service", timeout=60, max_restarts=None)
      assert restarts("flap-thrice") == 3, restarts("flap-thrice")

      # A unit that never starts still ends in the failure message, with its journal.
      flapping("flap-never", 1000)
      try:
          wait_active(machine, "flap-never.service", timeout=8, max_restarts=None)
      except AssertionError as e:
          assert "not active after 8s" in str(e) and "journal:" in str(e), str(e)
      else:
          raise Exception("wait_active returned for a unit that never becomes active")
    '';
  };
}
