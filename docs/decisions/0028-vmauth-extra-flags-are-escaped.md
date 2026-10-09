# 0028: vmauth.extraFlags is shell-escaped, like the storage services'

## Decision

vmauth's `ExecStart` is built with `lib.escapeShellArgs` over the whole flag list,
as the storage services' already were. One list element is exactly one argument.

## Why

vmauth used a plain space-join, so `extraFlags = [ "-x=a b" ]` reached systemd as
two arguments (`-x=a`, `b`) while the same value under `metrics.extraFlags` stayed
one: the same option name behaved differently per service.

## Consequences

- A single element holding two flags (`"-a -b"`) now stays one argument and stops
  working as two. Nothing in the repository did this and nothing was deployed.
- Every flag containing `=` is single-quoted in the rendered unit (so are the
  storage services'); systemd still expands the `%d` credential specifier inside
  the quotes (the real https-door boot test pins it).
- Quoting alone does not make a value literal: systemd also reads C escapes
  (`\"` loses its backslash, `\b` becomes a backspace) and expands `%` and `$`
  inside the quotes. Every user-supplied element is therefore escaped for
  systemd first (`nixosModule/victoriaStack/exec-escape.nix`, one helper for the
  storage services, vmauth and the syslog flags) and only then quoted; the
  module's own `%d` flags skip the escape. MCP's values travel in `Environment=`,
  where only `%` needs escaping.
