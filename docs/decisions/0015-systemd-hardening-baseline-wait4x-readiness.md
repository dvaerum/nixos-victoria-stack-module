# 0015: Systemd hardening baseline + wait4x readiness, extended beyond
storage

## Decision

`metrics.nix`/`logs.nix`/`traces.nix` now carry the exact hardening
profile nixpkgs' own `victoriametrics`/`victorialogs`/`victoriatraces`
modules already ship (`NoNewPrivileges`, `ProtectSystem=full`,
`PrivateDevices`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies`,
syscall filtering, etc. — copied verbatim, not re-derived), plus
`LimitNOFILE = 1048576` on metrics and traces specifically (matching
nixpkgs' own asymmetry — logs doesn't set it either, upstream).

Readiness is a `wait4x http <url>/ping --timeout 90s` call instead of a
hand-rolled `until curl ...; do sleep 1; done` loop. `wait4x` is already
packaged in nixpkgs (`pkgs.wait4x`), purpose-built for exactly this
(multi-protocol service/port/HTTP readiness polling with built-in
timeout/backoff), and a direct one-command replacement for the loop
nixpkgs' own modules hand-roll independently five separate times
(`victoriametrics`, `victorialogs`, `victoriatraces`, `cadvisor`,
`influxdb` — confirmed by reading all five, no shared helper exists
anywhere in nixpkgs for this). Neither `Type=notify` nor socket activation
apply — none of these binaries implement `sd_notify()` or
`sd_listen_fds()`.

Hardening (not readiness — there's no HTTP health endpoint to poll) is
also applied to `vmauth.nix` and `mcp.nix`'s three services, and a
lighter basics-only pass (`NoNewPrivileges`, `PrivateTmp`, `ProtectHome`)
to the two Alloy write-token/journal-upload-token oneshots.

The Alloy write-token oneshot specifically no longer runs as root. Per
`systemd.exec(5)`: `EnvironmentFile=` is read by the service manager
(PID1, root) itself, *before* the target process execs — file ownership
is irrelevant to that read, root bypasses normal permission checks
regardless of who owns the file. It now runs under its own
`DynamicUser = true` + `RuntimeDirectory = "alloy-write-token"` instead.
The journal-upload oneshot *does* still need root: it writes under
`/run/systemd/journal-upload.conf.d/`, a directory confirmed `755
root:root` on this machine — an unprivileged user has no write bit there
at all.

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
</content>
