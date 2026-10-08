# 0012: journal-upload write-token via a dedicated root oneshot helper

## Status

Supersedes part of 0005's exact mechanism (the "why a drop-in, not a
hand-rolled unit" reasoning in 0005 stands; this ADR corrects the
specific *path* and *rendering mechanism*, which turned out to be
wrong/incomplete when implemented).

## Decision

A small, dedicated oneshot systemd service (not sops-nix-specific, not
tied to NixOS's `/etc` activation model) renders
`/run/systemd/journal-upload.conf.d/50-write-token.conf` immediately
before `systemd-journal-upload.service` starts, reading the raw token via
its own `LoadCredential=` from `services.victoriaCollector.writeTokenFile`
(the same plain, agnostic file-path option Alloy's exporter also reads --
docs/decisions/0008). Runs as root (the unit's only job, no `User=`
override) specifically because `/run/systemd/` itself is not writable by
an unprivileged or `DynamicUser` process.

## Why this, not 0005's original "sops.templates path" idea

0005 originally assumed the drop-in's `.source` would point at an
already-activation-time-rendered path (modeled on sops-nix's
`sops.templates.*.path`), via `environment.etc."systemd/journal-upload.conf.d/...".source`.
Two things confirmed wrong with that during implementation:

- `environment.etc` entries are realized once per NixOS generation, at
  activation time -- before any systemd service ever starts. Deriving
  their content from a plain `...File` option (this module's own
  agnostic secrets convention, docs/decisions/0008) would mean either
  `builtins.readFile`-ing the secret straight into the Nix store (exactly
  the leak this design exists to avoid) or requiring a *different*,
  non-agnostic option type (an already-pre-rendered path) just for this
  one case -- a real tension between 0005 and 0008 neither ADR resolved
  at the time they were written.
- Re-reading `journal-upload.conf(5)`'s own SYNOPSIS section carefully
  (not just its DESCRIPTION prose, which is easy to misread as covering
  the same ground) confirms `/run/systemd/journal-upload.conf.d/*.conf`
  is itself a real, documented drop-in location -- meaning a *runtime*-
  rendered file works fine for this purpose, sidestepping the
  activation-time problem entirely. No sops-nix (or any other
  activation-time secrets tool) dependency needed at all.

## Why a separate unit, not `systemd-journal-upload.service`'s own preStart

Confirmed directly from systemd's own shipped unit file
(`systemd-journal-upload.service`): `DynamicUser=yes`,
`User=systemd-journal-upload` -- a deliberately hardened, unprivileged
unit. `/run/systemd/` itself is not writable by that user. Adding a
`preStart` to that unit would require weakening its own hardening (either
dropping `DynamicUser`/`User=` or granting it write access to a path
owned by systemd itself) just to render one file, trading away real
security hardening upstream deliberately put there. A separate,
narrowly-scoped oneshot (root, ordered `Before=`/`WantedBy=` the real
service, nothing else in its remit) does the one privileged thing needed
without touching the hardened unit at all.
