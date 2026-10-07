# 0026: Self-monitoring uses each binary's own -pushmetrics flags

## Decision

`services.victoriaStack.{metrics,logs,traces,vmauth}.selfMonitoring`
(`enable`, defaulting to `metrics.enable`; `interval`, default `30s`) makes a service push its own
`/metrics` page into the local VictoriaMetrics instance:

```
metrics ─┐
logs    ─┤  -pushmetrics.url=<metrics effectiveUrl>/api/v1/import/prometheus
traces  ─┤  -pushmetrics.interval=<interval>
vmauth  ─┘  -pushmetrics.extraLabel=job="<service>"
```

Enabling any of them requires `metrics.enable` (an assertion says so).

## Why

- Only VictoriaMetrics has `-selfScrapeInterval`; logs, traces and vmauth do
  not, and a flag a binary rejects would crash-loop the unit. All four share
  the `-pushmetrics.*` family, so one option works the same everywhere.
- It is the binaries' own mechanism: no extra unit, timer or collector is
  involved, and it needs no credential (loopback to the metrics instance,
  the same trust boundary as the other internal calls, ADR 0010).
- The `job` label keeps the four services apart; their Go-runtime series
  would otherwise collide.

## Not chosen

- A metrics-only option: leaves three services unmonitored.
- Leaving it to the collector: requires a collector on the stack host and
  scraping all four `/metrics` pages from the outside.
