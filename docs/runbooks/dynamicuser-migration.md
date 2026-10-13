# Switching `dynamicUser` on a host that already holds data

Applies to `services.victoriaStack.metrics`, `.logs` and `.traces`. The module
does not move data when `dynamicUser` changes, so the switch needs the manual
steps below. The test `storage-dynamicuser-switch-needs-manual-migration`
(`tests/storage.nix`) runs them in a VM, so each step is proven.

## Why the data is stranded

With `dynamicUser = true` systemd keeps the state in `/var/lib/private/<unit>`
and makes `/var/lib/<unit>` a symlink to it. `/var/lib/private` is root-only
(mode 0700). With `dynamicUser = false` the module's tmpfiles rule only
creates `/var/lib/<unit>` as a directory owned by the static user, and it
leaves the existing symlink alone (`systemd-tmpfiles` logs
`"/var/lib/<unit>" already exists and is not a directory.` and carries on).
The static user then cannot get through `/var/lib/private`.

`<unit>` is `victoriametrics`, `victorialogs` or `victoriatraces`; the static
user and group carry the same name.

## Symptom (true to false)

After the switch the unit does not stay up, and its journal shows (the binary
name differs per service):

```
FATAL: cannot stat "/var/lib/victoriametrics": stat /var/lib/victoriametrics: permission denied
```

The symlink is still there and `/var/lib/private/<unit>` still holds the data.

## Procedure (true to false)

Do this after the switch if the unit is failing, or before it if you can stop
the unit first. Run as root.

1. Stop the unit: `systemctl stop <unit>.service`.
2. Remove the symlink: `rm /var/lib/<unit>` (a symlink, so no `-r`).
3. Move the real directory: `mv /var/lib/private/<unit> /var/lib/<unit>`.
4. Hand it to the static user:
   `chown -R <unit>:<unit> /var/lib/<unit>`.
5. Clear the failed state and start:
   `systemctl reset-failed <unit>.service && systemctl start <unit>.service`.
6. Verify through the real unit: `systemctl show -p User --value <unit>.service`
   prints the static user, and the service's readiness endpoint answers
   (for metrics, `curl -sf http://127.0.0.1:4201/health`; use your
   `listenAddress`). Query an old series to confirm the data is back.

A custom `dataDir` follows the same steps with that path in place of
`/var/lib/<unit>`; the data still sits in `/var/lib/private/<unit>`.

## Rollback (false to true)

Flipping back (or rolling back to a generation with `dynamicUser = true`) needs
no manual step. Probed in the test: with the real directory at
`/var/lib/<unit>`, systemd moves it to `/var/lib/private/<unit>`, recreates the
`/var/lib/<unit>` symlink and re-owns the contents for the dynamic user, and
the old data is served again. Stop the unit before the switch so it is not
writing during the move, then verify as in step 6 of the procedure above.

## Snapshots and backups

Snapshots live inside the data directory, so they move with it. A backup taken
by path (`/var/lib/<unit>` or `/var/lib/private/<unit>`) or a ZFS/filesystem
snapshot of the old layout restores into the old location, not the new one:
restore, then repeat the steps for the direction you are in. Take a copy before
moving anything you cannot re-ingest.
