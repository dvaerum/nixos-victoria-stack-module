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

## Update: the weekly bump gates on the same matrix

`update-dependencies.yml` ran `nix flake check -L` in its two jobs and hit the
same kill. Each stage is now: a read-only bump job uploads `flake.lock` (stage 2:
plus `packages/`) as an artifact; `check.yml` runs with its `artifact` input,
which unpacks it over the checkout in every job; a push job commits it only
when every shard passed. Only the push jobs have `contents: write` and they run
no Nix; the bump jobs and shards keep no git credentials.

## Update: the push jobs can be pointed at a scratch branch

The package stage only runs end to end when an upstream release is newer than
the pin, which a normal week rarely gives. `update-dependencies.yml` therefore
takes two `workflow_dispatch` inputs: `push_branch` (both push jobs push there
instead of the branch the run started on, creating it if needed) and `dry_run`
(print the commit instead of pushing). Dispatching on a scratch branch whose
package is pinned one release back, with `push_branch` set, exercises bump,
sharded check and push without any write to `main`. Scheduled runs have neither
input and behave as before.

## Not covered

`nix flake check` also evaluated the non-test outputs (packages, apps,
formatter); the matrix builds only `testSections`.
