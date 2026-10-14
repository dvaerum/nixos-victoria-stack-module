# Switching `dynamicUser` on a host that already holds data

Applies to `services.victoriaStack.metrics`, `.logs` and `.traces`. The module
does not move data when `dynamicUser` changes, so the switch needs the manual
steps below. The test `storage-dynamicuser-switch-needs-manual-migration`
(`tests/storage.nix`) runs them in a VM, so each step is proven.

## Why the data is stranded

With `dynamicUser = true` systemd keeps the state in `/var/lib/private/<name>`
and makes `/var/lib/<name>` a symlink to it. `/var/lib/private` is root-only
(mode 0700). With `dynamicUser = false` the module's tmpfiles rule only
creates `/var/lib/<name>` as a directory owned by the static user, and it
leaves the existing symlink alone (`systemd-tmpfiles` logs
`"/var/lib/<name>" already exists and is not a directory.` and carries on).
The static user then cannot get through `/var/lib/private`.

`<name>` is the state directory and the static user and group:
`victoriametrics`, `victorialogs` or `victoriatraces`. `<service>` is the unit that
holds it: `vmstorage` for `victoriametrics`
([0033](../decisions/0033-metrics-cluster-replaces-single-node.md); `vminsert` and
`vmselect` keep no data and always run as a dynamic user), otherwise the same as
`<name>`.

## Symptom (true to false)

After the switch the service does not stay up, and its journal shows (the binary
name differs per service):

```
FATAL: cannot stat "/var/lib/victoriametrics": stat /var/lib/victoriametrics: permission denied
```

The symlink is still there and `/var/lib/private/<name>` still holds the data.

## Procedure (true to false)

Do this after the switch if the service is failing, or before it if you can stop
it first. Run as root.

1. Stop the service: `systemctl stop <service>.service`.
2. Remove the symlink: `rm /var/lib/<name>` (a symlink, so no `-r`).
3. Move the real directory: `mv /var/lib/private/<name> /var/lib/<name>`.
4. Hand it to the static user:
   `chown -R <name>:<name> /var/lib/<name>`.
5. Clear the failed state and start:
   `systemctl reset-failed <service>.service && systemctl start <service>.service`.
6. Verify through the real unit: `systemctl show -p User --value <service>.service`
   prints the static user, and the service's readiness endpoint answers
   (for metrics, vmstorage's `curl -sf http://127.0.0.1:4210/health`; use your
   `services.victoriaStack.metrics.storage.listenAddress`). Query an old series to confirm the data is back.

A custom `dataDir` follows the same steps with that path in place of
`/var/lib/<name>`; the data still sits in `/var/lib/private/<name>`.

## Rollback (false to true)

Flipping back (or rolling back to a generation with `dynamicUser = true`) needs
no manual step. Probed in the test: with the real directory at
`/var/lib/<name>`, systemd moves it to `/var/lib/private/<name>`, recreates the
`/var/lib/<name>` symlink and re-owns the contents for the dynamic user, and
the old data is served again. Stop the service before the switch so it is not
writing during the move, then verify as in step 6 of the procedure above.

## Snapshots and backups

Snapshots live inside the data directory, so they move with it. A backup taken
by path (`/var/lib/<name>` or `/var/lib/private/<name>`) or a ZFS/filesystem
snapshot of the old layout restores into the old location, not the new one:
restore, then repeat the steps for the direction you are in. Take a copy before
moving anything you cannot re-ingest.
