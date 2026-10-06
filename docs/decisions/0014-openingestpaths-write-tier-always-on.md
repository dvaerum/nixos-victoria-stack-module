# 0014: openIngestPaths only sizes the anonymous door; write-tier tokens
get an always-on ingest map

## Decision

`openIngestPaths`'s own description always said overriding it to `[]`
closes the *unauthenticated* write path only, leaving credentialed
write-tier bearer tokens unaffected. The code didn't honor that: both the
`unauthorized_user` block and write-tier bearer-token users were given the
exact same (overridable) list, so `openIngestPaths = []` silently broke
authenticated writes too.

Fixed by deriving a second, always-on ingest map (`autoOpenIngestPaths`,
the existing auto-derivation logic) for write-tier bearer tokens
unconditionally — never the user-facing `openIngestPaths` override, which
now purely sizes the anonymous/no-credential door.

A new `lib.warnIf` fires when `requireAuthForWrites = false` *and*
`writeTokensFile` is also set: the anonymous door being open already
grants the same access a configured token would, making the token
pointless in that configuration. This is a genuine two-settings-contradict
situation (same shape as 0009's `dataDir`/`dynamicUser` warning), not a
general security nag for an operator who knows what they're doing — a
distinction that also ruled out adding an equivalent warning anywhere a
setting is just a plain, deliberate escape hatch with nothing to
contradict (e.g. `manageTmpfiles = false`).

## Why

ADR 0003's whole premise is blast-radius separation between credential
tiers. An option whose own documentation promises "disable anonymous
writes, keep my credentialed writers working" but whose code does the
opposite undermines that premise silently — exactly the kind of gap a
security-focused reviewer needs to be able to trust the docs not to have.
</content>
