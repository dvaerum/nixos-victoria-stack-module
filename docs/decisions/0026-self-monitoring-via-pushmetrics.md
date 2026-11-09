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
  involved, and it needs no credential (the push goes to the local metrics
  instance's `listenAddress`, loopback by default, not through vmauth: the same
  trust boundary as the other internal calls, ADR 0010).
- The `job` label keeps the four services apart; their Go-runtime series
  would otherwise collide.

## Not chosen

- A metrics-only option: leaves three services unmonitored.
- Leaving it to the collector: requires a collector on the stack host and
  scraping all four `/metrics` pages from the outside.

## Update: metrics cluster

With the metrics cluster ([0033](./0033-metrics-cluster-replaces-single-node.md)) the push target is vminsert's tenant-0 import
endpoint on its own address (`http://<insert.listenAddress>/insert/0/prometheus/api/v1/import/prometheus`),
straight to it and not through vmauth. vmstorage, vminsert and vmselect each push
their own metrics with `job="vmstorage"`, `"vminsert"` and `"vmselect"`, like the
single-node process did, so `metrics.selfMonitoring` covers all three.

## Update: instance label

Every push also carries `-pushmetrics.extraLabel=instance="<networking.hostName>"`
next to the `job` one. Pushed series otherwise had no `instance` label, and the
upstream VictoriaMetrics dashboards (cluster, vmauth, logs, traces) filter and
template on it, so their panels were empty. There is no option for it
([0024](./0024-option-stability-stance.md)): the host name is the one sensible
value, and a different one can be set at ingest by relabelling. An
operator-supplied `-pushmetrics.*` flag in `extraFlags` is treated as before:
it doubles the push and raises the existing warning.
