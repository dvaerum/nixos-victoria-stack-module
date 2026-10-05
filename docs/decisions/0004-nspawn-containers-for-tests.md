# 0004: systemd-nspawn containers for every integration test

## Decision

Every `nixosTest` in this project uses `pkgs.testers.nixosTest`'s
`containers = { ... }` backend (systemd-nspawn), not the default
`nodes = { ... }` (QEMU) backend. Including the cross-host
`victoriaCollector` -> `victoriaStack` test, which needs two containers to
talk to each other over the network.

## Why

None of these scenarios need a kernel of their own, SUID binaries, or
graphical output — pure systemd unit ordering, HTTP roundtrips, and (for the
collector test) real network traffic between two containers. A full QEMU VM
boot is unnecessary weight for that, and nspawn containers build/start
meaningfully faster in CI.

Confirmed, not assumed, on two points before committing to this for
everything:

- `nixos-postgres-maintenance-module` (a sibling project, same author)
  already runs its own single-container nspawn tests clean in plain GitHub
  Actions CI with nothing beyond
  `experimental-features = nix-command flakes auto-allocate-uids cgroups`.
- Multi-container networking specifically (the one case that project never
  needed) is validated by nixpkgs' own framework self-test,
  `nixos/tests/nixos-test-driver/containers.nix`: container<->container and
  container<->node reachability by hostname, correctly scoped to shared
  vlans, confirmed directly on the real `nixos-26.05` branch source (not
  just unstable) before relying on it.

## Known nspawn gotchas (carried into every test script)

- No `sudo` inside a container — use `runuser -u <user> --` instead.
- Avoid `machine.shutdown()` mid-test — container shutdown pays a real,
  measurable unmount cost per bind-mounted store path.
- Stopping a unit also stops everything below it in the dependency chain —
  no `StopWhenUnneeded=`-style isolation. A test that needs to inject state
  into a running service before re-triggering a chain has to stop
  everything, then explicitly restart the leaf service on its own first.
- Never name a `testScript` local variable `log` — it shadows the test
  driver's own structured logger and produces a confusing, misattributed
  type error.
