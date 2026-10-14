# 0034: A parallel-evaluation test gate next to `nix flake check`

## Decision

`nix run .#gate` (`scripts/gate.sh`) evaluates every check with
`nix-eval-jobs` in several worker processes and then builds the resulting
derivations with `nix build --keep-going`. `--sections a,b` does the same for
named groups only. `checks` is unchanged; `testSections.<system>.<group>`
exposes the groups (one `tests/*.nix` file each) that `checks` flattens.

Use: `gate --all` per task, `gate --sections` while editing (the script labels
it as not a gate), and the classic `nix flake check -L` as the final gate of a
stage.

## Why

`nix flake check` evaluates in one process: about 25 of its 34 minutes were
single-threaded evaluation of roughly 630 checks (51 GB peak). `nix-eval-jobs`
produces identical derivation paths with `--workers N`, so parallel evaluation
changes the time, not what is built. Nix itself has no evaluation parallelism
in the versions in use.

Mapping changed files to the affected groups was rejected: `options.nix`,
`assertions.nix` and `tests/default.nix` touch every group. Evaluating
everything and letting Nix skip derivations that did not change is simpler and
cannot miss a check.

## Fail-closed

The script exits non-zero on a `nix-eval-jobs` failure, any evaluation error,
zero evaluated checks, a count different from the attribute names the flake
defines, a failed `nix build`, or any output path still missing afterwards.

`tests/sections.nix` fails when a `tests/*.nix` file is not registered in
`tests/default.nix`, or when `testSections` and the registrations disagree.
