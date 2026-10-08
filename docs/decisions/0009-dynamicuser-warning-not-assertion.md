# 0009: dataDir/dynamicUser mismatch is a warning, not an assertion

## Decision

`dynamicUser = true` (the default) combined with a `dataDir` that has been
changed away from the upstream default produces a build-time warning (an
entry in `warnings`), not a hard assertion — and the warning is itself suppressible via
`suppressDynamicUserWarning`.

## Why

This is exactly the broken combination both real deployments
(`deployment-a`, `deployment-b`) independently discovered the hard way
(`DynamicUser`'s `StateDirectory` migration fails against an externally
mounted path). A hard assertion would make that combination impossible to
build at all. A warning catches it at `nixos-rebuild build` time (not months
later at runtime, the way it was originally discovered) while still
respecting that the operator might have a reason this module can't know
about — and provides an explicit, cheap way to silence it once acknowledged,
rather than forcing a workaround to get past a hard failure.
