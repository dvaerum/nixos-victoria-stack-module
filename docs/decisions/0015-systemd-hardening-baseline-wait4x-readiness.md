# 0015: Systemd hardening baseline + wait4x readiness, extended beyond
storage

## Status

The Alloy part of the last paragraph before "Why" (the write-token oneshot with
`EnvironmentFile=`, its `DynamicUser` and `RuntimeDirectory`) is superseded by
[0006](./0006-alloy-write-token-via-systemd-credential.md): that oneshot no longer exists and
Alloy gets the token as a systemd credential. The rest of this ADR still holds.

## Decision

`metrics.nix`/`logs.nix`/`traces.nix` now carry the exact hardening
profile nixpkgs' own `victoriametrics`/`victorialogs`/`victoriatraces`
modules already ship (`NoNewPrivileges`, `ProtectSystem=full`,
`PrivateDevices`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies`,
syscall filtering, etc. — initially copied from nixpkgs, not re-derived), plus
`LimitNOFILE = 1048576` on metrics and traces specifically (matching
nixpkgs' own asymmetry — logs doesn't set it either, upstream).

Since raised: `ProtectSystem=strict` and an empty `CapabilityBoundingSet` on the
storage, vmauth and mcp units. The exception is a unit with a listener on a port
below 1024 (vmauth, or the logs unit with a syslog port below 1024 -- the default
`udp`/`tcp` port 514): it gets `CAP_NET_BIND_SERVICE` (bounding and ambient) and `PrivateUsers=false`,
because a capability held inside a user namespace does not count for binding in the host's
network namespace (a real boot failed with `bind: permission denied` otherwise). Measured: DynamicUser units were already
effectively strict even with an explicit `full`; only static-user units truly
ran with `full`.

Readiness on the storage services is an `ExecStartPost` probe that polls `wait4x http
<url>/ping` until the `startupTimeout` deadline (the `startupTimeout` option, `5m` by
default, so the probe outlasts a slow open of a large data directory;
`TimeoutStartSec` is always a minute above it, so the two never expire
together) instead of a
hand-rolled `until curl ...; do sleep 1; done` loop. `wait4x` is already
packaged in nixpkgs (`pkgs.wait4x`), purpose-built for exactly this
(multi-protocol service/port/HTTP readiness polling with built-in
timeout/backoff), and a direct one-command replacement for the loop
nixpkgs' own modules hand-roll independently five separate times
(`victoriametrics`, `victorialogs`, `victoriatraces`, `cadvisor`,
`influxdb` — confirmed by reading all five, no shared helper exists
anywhere in nixpkgs for this). Neither `Type=notify` nor socket activation
apply — none of these binaries implement `sd_notify()` or
`sd_listen_fds()`, so the readiness signal stays a probe.

The probe is one shared script (`readiness.nix` / `readiness.sh`) used by every unit. It
retries `wait4x` with a 2-second per-attempt `--timeout` and a 250 ms poll interval, and also
watches the unit's main process (`$MAINPID`, which systemd sets for `ExecStartPost`):
when that process is gone the probe fails at once, naming the unit, instead of
polling a port nobody will ever listen on. systemd waits for `ExecStartPost`, so a
plain `wait4x --timeout 5m` left a crashed unit in `activating (start-post)` for the
whole five minutes. The deadline therefore only bounds how long a *live* but
unready process is waited for; a slow start is still given all of it.

Update: the poll interval went from 1 s to 250 ms. A unit's start used to end at the
first poll after its port opened, so on a unit that is ready within a second the wait
was 0.9 s or 1.9 s depending on the phase of the poll (6 starts of `victorialogs` in
each of 3 boots: mean about 1.4 s before, about 0.95 s after, floor 0.87 s); chained
backend boots were about 2 s shorter. `--quiet` keeps the log silent at any rate and
the probe still ends at once when the main process dies, so only the number of
loopback connection attempts grows (4x, harmless).

Update: the metrics cluster units (`vmstorage`, `vminsert`, `vmselect`) probe `/health`
instead of `/ping`, and `LimitNOFILE` sits on the cluster processes that carry it
([0033](./0033-metrics-cluster-replaces-single-node.md)).

Hardening is also applied to `vmauth.nix` and `mcp.nix`'s three services,
each with its own probe target: vmauth is checked with a TCP probe
(`<listen address>`, 90s deadline: with `-httpInternalListenAddr`
its `/health` is not served on the data listener, so there is no HTTP endpoint
to poll), and each MCP server with an HTTP probe of `<url>/health/readiness`
(90s deadline). A lighter pass covers the collector's oneshots: the
journal-upload token render gets `NoNewPrivileges`, `PrivateTmp` and
`ProtectHome` and keeps `CAP_CHOWN` because it must `chgrp` its drop-in to
`systemd-journal` (an empty set made it fail in a real boot); the two path
helpers get only an empty `CapabilityBoundingSet`.

The Alloy write-token oneshot specifically no longer runs as root. Per
`systemd.exec(5)`: `EnvironmentFile=` is read by the service manager
(PID1, root) itself, *before* the target process execs — file ownership
is irrelevant to that read, root bypasses normal permission checks
regardless of who owns the file. It now runs under its own
`DynamicUser = true` + `RuntimeDirectory = "alloy-write-token"` instead.
The journal-upload oneshot *does* still need root: it writes under
`/run/systemd/journal-upload.conf.d/`, a directory confirmed `755
root:root` on this machine — an unprivileged user has no write bit there
at all. It keeps `CAP_CHOWN` (it needs `chgrp` to `systemd-journal`).

## Why

ADR 0001 justified building these units from scratch to fix two narrow,
specific problems (hardcoded `-storageDataPath`, `DynamicUser`'s
`StateDirectory` interaction with externally-mounted datasets). It never
argued for or even mentioned dropping nixpkgs' own hardening profile —
that was an unacknowledged regression, not a deliberate trade-off, found
by independent review. Bringing these units back up to the bar nixpkgs
already cleared costs nothing beyond more `serviceConfig` lines; there was
no real security trade-off to relitigate, since nixpkgs' own maintainers
already validated this exact profile against these exact binaries.

## Restart backoff

The storage services (which also run the syslog listeners), vmauth, the three
MCP units and the collector's Alloy restart with an exponential backoff
(`RestartSteps=3`, `RestartMaxDelaySec=30`, defined once in
`nixosModule/restart-backoff.nix`), so a unit that cannot start stops filling the
journal with a retry every few seconds. The first retry keeps the unit's own
`RestartSec` (5 s; Alloy keeps nixpkgs' 2 s): measured on a real boot the retries
wait 5, 9, 16.5, 30, 30 ... s, and Alloy 2, 5, 12, 30, 30 ... s. `Restart=always`
and `on-failure` behave the same, and the start limit is never tripped because
retries only get slower.

Limitation: systemd 261 never resets the growth after a healthy run. The restart
counter is zeroed only by a manual start or restart, `reset-failed`, or
`RESTART_RESET=1` sent by the service itself, so after a few crashes in a unit's
lifetime every later crash waits the 30 s cap. That is accepted because it is
bounded and the collector's disk queue absorbs it; a helper that runs
`reset-failed` after a healthy period would remove it. A low cap was chosen for
this reason, instead of a couple of minutes.

Left out: `systemd-journal-upload` (nixpkgs' own escalating restart policy, see
`nixosModule/victoriaCollector/config.nix`), nginx (nixpkgs-owned), and the
oneshot and path helper units (they never restart).

Update: Grafana now carries the backoff too, with `RestartSec = 5`, all three
`mkDefault` because the operator owns Grafana's unit. A Grafana killed inside its
start-up (a deploy that stops it mid-start) leaves a row in its own database
(`server_lock`, `oss-ac-basic-role-seeder`) that makes every start exit 1 for
2 minutes. At nixpkgs' default `RestartSec` (100 ms) the five starts of the start
limit are spent in under a second and the unit stays failed (`start-limit-hit`)
until `reset-failed`; with the backoff the 6th start, about 2 minutes later,
succeeds without anyone touching it (`tests/grafana-recovery.nix`).
