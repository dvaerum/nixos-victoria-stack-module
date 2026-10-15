{ pkgs, nixosModule }:

# Grafana recovers by itself from being killed inside its start-up
# (docs/decisions/0015, "Restart backoff"). The kill leaves a row in Grafana's
# own database (server_lock "oss-ac-basic-role-seeder") that makes every start
# exit 1 for the next 2 minutes; at systemd's default 100 ms RestartSec the
# start limit (5 starts in 10 s) is used up in under a second and the unit stays
# failed (`start-limit-hit`) until an operator runs `reset-failed`.
let
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };

  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";
in
{
  killed-inside-startup-comes-back-without-reset-failed = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-recovers-from-a-killed-startup";

    nodes.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.sqlite ];
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
      services.victoriaStack = {
        logs.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "${testLib.grafanaReadTokenFile}";
        };
        vmauth.readTokensFile = "${testLib.vmauthReadTokensWithGrafana}";
      };
    };

    testScript = ''
      import time
      ${testLib.waitActivePython}

      GRAFANA = "http://127.0.0.1:3000/api/health"

      start_all()
      wait_active(machine, "grafana.service")
      machine.wait_until_succeeds(f"curl -sf {GRAFANA}")

      # What a SIGKILL at the moment Grafana takes the seeder lock leaves behind
      # (measured by polling the database for the row and killing right then):
      # the row, dated now. Planted instead of raced for, because the window
      # between the row appearing and the seeding finishing is a few ms.
      machine.succeed("systemctl stop grafana.service")
      machine.succeed(
          "sqlite3 /var/lib/grafana/data/grafana.db "
          "\"delete from server_lock where operation_uid='oss-ac-basic-role-seeder'; "
          "insert into server_lock (operation_uid, version, last_execution) "
          "values ('oss-ac-basic-role-seeder', 0, strftime('%s','now'))\""
      )
      machine.succeed("systemctl start --no-block grafana.service")
      machine.wait_until_succeeds(
          "journalctl -u grafana.service --no-pager | grep -F 'there is already a lock for this actionName'",
          timeout=60,
      )

      # No reset-failed, no manual start: the unit must come back on its own
      # once the lock (2 minutes) has expired.
      deadline = time.monotonic() + 180
      while machine.execute(f"curl -sf {GRAFANA}")[0] != 0:
          if time.monotonic() > deadline:
              _, state = machine.execute("systemctl show -p ActiveState,SubState,Result,NRestarts grafana.service")
              _, journal = machine.execute("journalctl -u grafana.service -n 40 --no-pager")
              assert False, f"Grafana not healthy 180s after the lock was taken:\n{state}\n{journal}"
          time.sleep(2)
    '';
  };
}
