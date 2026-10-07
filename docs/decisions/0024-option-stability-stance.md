# 0024: Option-stability stance -- renames go through mkRenamedOptionModule

## Decision

This project has no versioning or release promise yet, so an option may
still be removed or reshaped without notice. From now on, though, any
option **rename** ships with `lib.mkRenamedOptionModule`, so existing
configs keep evaluating (with NixOS's standard rename warning) instead of
failing with "option does not exist".

This is not retroactive: renames made before this ADR are not shimmed.

## Why

A rename is the one breaking change that can be made painless for
consumers at almost no cost. Anything that is not a rename (a removed
option, a changed type, a changed meaning) cannot be auto-migrated by Nix
and is called out in the option's own description instead.

## First real example

`services.victoriaStack.{metrics,logs,traces}.extraOptions` became
`extraFlags` (matching `vmauth.extraFlags` and the collector's
`alloy.extraFlags`). The old name still works and warns; it is declared
once in `storage-common.nix`.
