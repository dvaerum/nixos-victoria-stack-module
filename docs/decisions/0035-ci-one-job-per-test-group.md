# 0035: CI runs one job per test group (sharded), not `nix flake check`

## Decision

`ci.yml` and `ci-stable.yml` call `check.yml`. It lists the groups from
`testSections.x86_64-linux` (ADR 0034), splits any group of more than 30
checks into shards, and runs one matrix job per shard: `nix build --keep-going`
over just that shard's checks, with `fail-fast: false`. A final `ci` job gives
branch protection one stable status name whatever the group list is.
`ci-stable.yml` passes the resolved stable branch in; each job pins nixpkgs to
it with `nix flake lock --override-input` in its own throwaway checkout.

## Why

`nix flake check -L` evaluates about 630 checks in one process (51 GB peak,
ADR 0034). The 16 GB hosted runner was killed ("The runner has received a
shutdown signal") before building anything, on every run since the suite
outgrew about 130 checks. A job that evaluates only its own shard peaks well
under 14 GB, and its build output stays within the runner disk.

`nix-eval-jobs` was not used for CI: one worker on
`assertions.nix` `datadir-accepts-only-plain-absolute-paths` needs over 15 GB.

Groups come from the flake, so a new `tests/*.nix` file is covered without
editing the workflow. Shards are every n-th check by sorted name, so every
check is built exactly once.

## Not covered

`nix flake check` also evaluated the non-test outputs (packages, apps,
formatter); the matrix builds only `testSections`.
