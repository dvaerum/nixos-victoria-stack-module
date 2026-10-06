# 0011: Local nspawn container tests need a daemon-level Nix feature

## Status

Resolved as of Phase 34. Kept as a record of the constraint and the
decision not to route around it unilaterally, not because the blocker
is still live.

## What's blocked

`pkgs.testers.nixosTest`'s `containers = {...}` backend (used throughout
this project -- see 0004) requires the Nix daemon to advertise the
`uid-range` system feature, which in turn requires
`nix.settings.auto-allocate-uids = true;` (plus the matching experimental
feature) in the **host machine's own** NixOS configuration, followed by a
rebuild + switch.

Confirmed directly: on the development machine this was implemented on,
`nix show-config` reports `system-features = benchmark big-parallel kvm
nixos-test` -- `uid-range` is absent. `/etc/nix/nix.conf` is a symlink into
the Nix store (`/etc/static/nix/nix.conf`), confirming the daemon's config
is managed declaratively through the host's own `configuration.nix`, not
something safely hand-editable or overridable from an unprivileged client
flag.

## Why this isn't something to route around unilaterally

Enabling an experimental Nix daemon feature machine-wide affects every
other Nix build on that host, not just this project -- a real, if small,
stability/trust tradeoff that belongs to whoever owns the machine, not to
whichever project happens to need the feature first. This is exactly the
class of "human product or risk judgment call" this project's own
development discipline says to surface rather than decide alone.

## What's verified vs. not, as of Phase 3

Eval-only checks (the `assertions` group, and `storage.nix`'s
dynamicUser/dataDir warning checks) have zero dependency on this feature
and are fully, honestly verified locally.

Container-boot checks (ingest/query roundtrips, static-user ownership,
package-override-takes-effect, and everything in every later phase that
needs a running service) are implemented per the same design, confirmed to
fail ONLY for this reason (`Reason: missing system features` /
`Required features: {nixos-test, uid-range}`) and not for any other bug,
but are not independently verified as passing until either:

- the host enables `auto-allocate-uids` and rebuilds, or
- CI (which already enables this correctly in `ci.yml`/`ci-stable.yml`/
  `update-dependencies.yml` via `cachix/install-nix-action@v27`'s
  `extra_nix_config`) runs them after a push.

Push access is itself separately blocked as of this writing (see git log --
`gh auth login` / SSH key registration pending). Both are tracked as open
items for the human operator, not guessed past.

## Resolution (Phase 34)

Both items resolved: `auto-allocate-uids` was enabled on the development
machine's own NixOS configuration (a separate repo/commit, this project's
own host, not routed around here), and push access was restored
separately (a branch-name mismatch between local `master` and the
remote's `main`, not a credential problem). Every container-boot check
in the project ran for real for the first time as a result -- see
PLAN.md's Phase 34 entry for what that first real run actually found (2
genuine production bugs invisible to pure code review).

