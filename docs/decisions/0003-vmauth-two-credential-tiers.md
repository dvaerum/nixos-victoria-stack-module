# 0003: vmauth gets two separate credential-tier secrets

## Decision

`services.victoriaStack.vmauth.writeTokensFile` (ingest-only, consumed by
every `victoriaCollector` host across a fleet) and `.readTokensFile`
(read + MCP, consumed by humans/AI callers) are two independent sops-nix
secrets, even though they could technically share one file.

## Why

The two lists have different blast radii. `writeTokensFile` lives on every
fleet host (the much bigger attack surface); `readTokensFile` lives nowhere
except the one gateway host. A leaked collector config handing over
write-only access is a bounded problem ("it can write bogus data"); the same
leak handing over read access to the entire observability stack is not.
Keeping them as two files means a future change to who/what can read the
write-token file (e.g. granting every collector host read access to pull its
own token) never has to touch or even graze the access-control story for the
read/admin token file.

## Format

Both are YAML (not newline-separated plain text): a list of bearer tokens,
each optionally followed by an inline `#` comment naming the host/purpose it
belongs to. Parsed with `yq-go` (comments stripped natively by any real YAML
parser) rather than `jq -R -s -c 'split("\n")...'` (today's mechanism, which
treats the file as raw lines and has no comment concept at all). Self
documenting without needing a side channel to remember which token is whose.
