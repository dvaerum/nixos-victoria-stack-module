# 0030: A token or admin entry that grants no access warns; it does not stop vmauth

## Decision

The render script (`ExecStartPre` of `vmauth.service`) treats an entry that
would grant no access as a warning, not an error:

- `backends: []` (or a bare `backends:`) gives the token NO access. It used to
  mean "unscoped", i.e. full access.
- An unknown backend name (`"trackers"` for `"traces"`) is warned about and
  ignored; the token keeps its other valid backends.
- A valid backend that is not enabled on this host gives no routes: warning, no
  access. It used to be a render error.
- An entry with an empty `token:` is skipped with a warning.
- An empty or whitespace-only admin password creates no admin user, with a
  warning.

A token left with no access is left OUT of `config.json`. vmauth rejects a user
whose `url_map` is empty, so the only way to express "no access" is to not render
the user; its callers then get the 401 any unknown token gets.

Warnings go to stderr (the journal) and name the option and the entry number,
never a token. The unknown backend name itself is printed (it is a backend name,
not a credential).

## Why

One typo in one of many entries stopped vmauth, and with it every other
collector and reader. These entries are access-granting: dropping one can only
reduce access, never widen it, so failing soft is safe. `backends: []` meaning
"everything" was the one reading that widened access on an easy-to-make mistake;
it now fails closed as well as soft.

## What still stops the render

Errors whose only safe response is to refuse, because carrying on would guess
what the operator meant or hand out a wrong credential:

- duplicate tokens (within a file or across the read and write files),
- unknown keys in an entry, an entry without a `token` key, a wrong shape (not a
  list of objects, a non-string token or backend),
- the old bare-string format.

See [0003](0003-vmauth-two-credential-tiers.md) for the two credential tiers.
