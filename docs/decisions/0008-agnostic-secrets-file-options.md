# 0008: Agnostic ...File secret options, no sops-nix dependency in module code

## Decision

Every credential option across this module (`vmauth.adminPasswordFile`,
`.writeTokensFile`, `.readTokensFile`, `victoriaCollector.writeTokenFile`,
etc.) is a plain file-path option. The module's own code never calls
`config.sops.*` or assumes sops-nix exists at all — it only needs a path to a
file whose *content* is the secret, however that file got there.

## Why

Matches this author's own existing convention (`CoNexus`'s
`clientSecretFile`) and the project's own stated secrets policy: sops is
something a *consumer* wires up, not something a module assumes. Baking
`config.sops.placeholder."..."` directly into module logic (as today's real
`deployment-a` vmauth.nix does) works, but makes sops-nix a hard, invisible
dependency of this flake for anyone who wants real secrets at all — agenix,
a manually-placed file, or any other mechanism would be locked out.

Confirmed this doesn't cost anything functionally: sops-nix's own README
documents `sops.secrets.<name> = { format = "yaml"; sopsFile = ...; key = ""; }`
as a first-class way to mount an entire structured file as one secret, and
`sops.secrets.<name>.path` (plus `.key` addressing into a shared file) as the
mechanism for pulling individual named values out of one shared encrypted
file — i.e. "one encrypted file, many individually-addressed secrets" is
already a native sops-nix feature, not something this module needs to
reimplement with its own secret-splitting service. The README documents this
pattern as the recommended (not required) way to wire real secrets into this
module's `...File` options.
