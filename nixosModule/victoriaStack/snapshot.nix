# The periodic snapshot oneshot + timer, shared by the single-node units of
# storage-common.nix and vmstorage in cluster mode. A oneshot POSTs to the
# binary's own snapshot API over loopback (the same trust boundary as every
# other internal call in this module -- no credential), fired by a timer.
# Pruning is the binary's own -snapshotsMaxAge, not this unit's job.
{
  config,
  lib,
  pkgs,
}:
let
  inherit (import ./exec-escape.nix { inherit lib; }) escape;
in
{
  # -snapshotsMaxAge for `snapshots` (the option subtree); empty while disabled.
  # null passes 0, which DISABLES pruning: omitting the flag would leave the
  # binaries' own 3d default in force (each binary's -help), deleting snapshots
  # the operator meant to keep.
  maxAgeFlags =
    snapshots:
    lib.optional snapshots.enable "-snapshotsMaxAge=${
      if snapshots.maxAge == null then "0" else snapshots.maxAge
    }";

  # `service` is the unit being snapshotted (without ".service"), `url` the
  # create endpoint to POST. Returns { services; timers; } to merge under
  # `systemd`, both named "<service>-snapshot".
  mkUnits =
    {
      snapshots,
      service,
      description,
      url,
    }:
    {
      services."${service}-snapshot" = {
        inherit description;
        # Ordering only, no Requires=: a Requires= start would bring back a
        # service the operator stopped on purpose (restore/copy of dataDir).
        # After= still makes a queued start of the service finish first, so a
        # timer firing at boot never meets it half-started.
        after = [ "${service}.service" ];
        serviceConfig = {
          Type = "oneshot";
          # Exit 3 (not active) is in systemd's 1-254 "condition not met"
          # range: the run is skipped, not failed. "+" runs it outside the
          # sandbox below, whose AF_UNIX-less address list would otherwise
          # keep systemctl from reaching systemd.
          ExecCondition = "+${config.systemd.package}/bin/systemctl is-active --quiet ${service}.service";
          ExecStart = lib.escapeShellArgs (
            map escape [
              (lib.getExe pkgs.curl)
              "--silent"
              "--show-error"
              "--fail"
              "--request"
              "POST"
              url
            ]
          );
          DynamicUser = true;
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      timers."${service}-snapshot" = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = snapshots.schedule;
          # Catch up a missed run after downtime rather than skipping it.
          Persistent = true;
        };
      };
    };
}
