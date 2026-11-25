# 0037: nixpkgs' alloy checkConfig is off for the collector's config

## Decision

When the nixpkgs in use has `services.alloy.checkConfig`, the collector module
sets it to `lib.mkDefault false`. On nixpkgs without that option nothing is set.
A consumer can still turn it back on, which fails the build (see below).

## Why

`checkConfig` runs `alloy validate` on `/etc/alloy/*.alloy` at build time with no
flags. The generated config uses `otelcol.storage.file` (the disk-backed sending
queue), which Alloy only accepts with `--stability.level=public-preview`, and
nixpkgs' check cannot be given that flag: `services.alloy.extraFlags` only reach
the service's `ExecStart`. Left on, every consumer's `nixos-rebuild build` fails
with `component "otelcol.storage.file" is at stability level "public-preview"`.

The module's own tests replace the check: `collector-default-rendered-config-validates-with-stability-flag`
validates the rendered config with the flag for the main option combinations
(and fails if Alloy ever stops needing the flag), and
`collector-hostile-config-values-render-valid-alloy` covers escaping.
`alloy-checkconfig-system-checks-pass-on-a-nixpkgs-with-alloy-checkconfig` builds the
system checks against a nixpkgs that has the option (flake input
`nixpkgs-alloy-check`, test-only); `alloy-checkconfig-evaluates-on-a-nixpkgs-without-alloy-checkconfig`
covers the guard for older releases.

## Rejected

Setting `checkConfig = false` unconditionally: an "option does not exist" error
on nixpkgs releases without it.
