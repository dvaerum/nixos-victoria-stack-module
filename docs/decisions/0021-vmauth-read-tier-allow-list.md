# 0021: vmauth's read tier is a curated allow-list, not a passthrough

## Decision

`vmauth.nix`'s `readUrlMap` (the `url_map` shared by `readTokensFile` bearer
tokens and `adminPasswordFile`'s Basic Auth user — docs/decisions/0003
confirms both are meant to carry identical, read-only access) now enumerates
a curated allow-list of each backend's real, documented read-only HTTP
endpoints, instead of a blanket `src_paths = ["/metrics/.*"]`-style
passthrough to the backend's entire native API.

Per backend:

- **VictoriaMetrics**: `/api/v1/query`, `/api/v1/query_range`, `/api/v1/series`,
  `/api/v1/labels`, `/api/v1/label/.+/values`, `/api/v1/export.*`,
  `/federate` — confirmed from VictoriaMetrics' own API docs' "Reads"
  section; the first five are also vmauth's own official
  per-tenant-authorization example, not improvised.
- **VictoriaLogs**: `/select/.*` — confirmed from VictoriaLogs' own HTTP API
  docs: its entire read surface lives under `/select/*`, with `/insert/*` as
  the completely separate, never-overlapping write namespace. One regex is
  both correct and already a closed allow-list here.
- **VictoriaTraces**: `/select/.*` — same reasoning; VictoriaTraces' own
  docs confirm it "provides the same HTTP endpoints that VictoriaLogs
  provides" (also under `/select/*`) plus the Jaeger query API (also under
  `/select/jaeger/*`).

A **deny-list** (vmauth's own native `deny_paths`, blocking specific known-bad
paths while forwarding everything else) was considered and rejected: it
fails *open* (a future backend endpoint nobody added to the deny-list is
reachable by default — the exact shape of the bug this ADR fixes), whereas
an allow-list fails *closed* (an endpoint not on the list is rejected by
default). New legitimate read endpoints need this list updated by hand;
`extraReadUrlMap` is the interim escape hatch until then.

## Why

The previous blanket passthrough let a read-tier credential — explicitly
documented as the safe-to-hand-out, read-only tier (docs/decisions/0003) —
reach every native endpoint the backend exposes under that prefix,
including write and destructive-admin endpoints. Verified live against a
real running container before this fix:

```
curl -H "Authorization: Bearer $READ_TOKEN" -X POST \
  'http://127.0.0.1:4204/metrics/api/v1/import' -d '...'
# → write succeeds with a "read" credential

curl -H "Authorization: Bearer $READ_TOKEN" -X POST \
  'http://127.0.0.1:4204/metrics/api/v1/admin/tsdb/delete_series' \
  -d 'match[]=some_metric'
# → permanent data deletion succeeds with a "read" credential
```

The same passthrough shape let the read tier reach VictoriaLogs'
`/insert/jsonline` endpoint (forged log injection) and would have reached
VictoriaTraces' equivalent write path too. This directly undermined the
entire stated rationale for splitting credential tiers in the first place
(docs/decisions/0003: "a leaked collector token handing over write-only
access is a bounded problem... the same leak handing over read access to
the entire observability stack is not") — the actual blast radius of a
leaked read token was strictly worse than a leaked write token, not better.

Found via a fresh-agent critical review explicitly tasked with hunting for
exactly this class of gap, and confirmed empirically (not just read from
code) before any fix was written — the same discipline this project has
used since Phase 34 found that reading code alone misses real bugs that
only surface by actually sending the request.

## Test coverage

`tests/vmauth.nix`'s `read-tier-is-genuinely-read-only` confirms, for both
credential types (admin password and read token) and all 3 backends: real
read endpoints still work, and the specific endpoints verified dangerous
above are rejected. `read-tier-url-map-is-a-closed-allow-list-not-a-wildcard`
pins the literal `src_paths` shape via eval-only check, so a future
accidental widening back toward a wildcard is caught immediately, not just
"the specific endpoints tested still happen to work."
