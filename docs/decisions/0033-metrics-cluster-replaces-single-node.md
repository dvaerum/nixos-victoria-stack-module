# 0033: The metrics cluster replaces single-node VictoriaMetrics

## Decision

`services.victoriaStack.metrics` runs the cluster version of VictoriaMetrics on
the one host: vmstorage (data), vminsert (writes) and vmselect (reads). There is
no single-node mode and no switch between the two.

| Process | Option | Default | Role |
|---|---|---|---|
| vmselect | `metrics.listenAddress` | `127.0.0.1:4201` | read API |
| vminsert | `metrics.insert.listenAddress` | `127.0.0.1:4209` | write API |
| vmstorage | `metrics.storage.listenAddress` | `127.0.0.1:4210` | its own HTTP: health, snapshots |
| vmstorage, for vminsert | fixed | `127.0.0.1:4211` | RPC |
| vmstorage, for vmselect | fixed | `127.0.0.1:4212` | RPC |

Retention, `dataDir`, `dynamicUser`, `startupTimeout` and the snapshots belong to
vmstorage; `extraFlags` goes to vmselect, `insert.extraFlags` to vminsert and
`storage.extraFlags` to vmstorage. `metrics.package` is the cluster package
(`packages/victoriametrics-cluster`, built from upstream's `v<version>-cluster`
tag; nixpkgs has no cluster package). `vmauth.package` stays
`pkgs.victoriametrics`: vmauth is not in the cluster tag. A check fails when the
two versions differ, and the weekly dependency workflow bumps the cluster package
to `pkgs.victoriametrics`' version.

Client-facing paths do not change: vmauth still serves `/metrics/...` and
`/opentelemetry/...`, and rewrites them onto vmselect's `/select/0/prometheus/...`
and vminsert's `/insert/0/...` ([0021](./0021-vmauth-read-tier-allow-list.md),
[0014](./0014-openingestpaths-write-tier-always-on.md)).

## Why

- **Native tenants.** Single-node VictoriaMetrics has no tenant. The cluster
  version keeps data per `accountID:projectID` and takes it from the URL, so a
  tenant needs no label trick ([0032](./0032-tenants-in-token-files.md) lists
  metrics tenants as not done; its later Update records them done).
- **Stage 3 builds on it.** vmauth can stamp `/insert/<accountId>/` and
  `/select/<accountId>/prometheus/` per token. This decision stays on tenant 0.
- **Cheap on one host.** Measured idle resident memory: about 20 MB for
  vmstorage, 8 MB for vminsert and 14 MB for vmselect.

## What changed for operators

- **Units.** `victoriametrics.service` and `victoriametrics-snapshot.{service,timer}`
  are gone: use `vmstorage`, `vminsert`, `vmselect` and `vmstorage-snapshot`. The
  static user, its group, the default `dataDir` and the `StateDirectory` keep the
  name `victoriametrics`. The units start in the order storage, then the other two,
  with no `requires`/`wants` between them, so one restarting does not cascade.
  Resource limits go on the process that needs them:
  `systemd.services.vmstorage.serviceConfig.MemoryMax`.
- **Ports.** Writes straight to a backend go to `:4209`, not `:4201`. Anything
  that dialled the old single port for both reads and writes must be split.
- **Direct paths.** The backends no longer serve the plain paths. Write to
  `http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus`, read from
  `http://127.0.0.1:4201/select/0/prometheus/api/v1/...`. vmstorage serves
  `/snapshot/*` and `/internal/force_flush` on `:4210`.
- **Operator routes in vmauth.** Only the OTLP write route is derived. Entries you
  add in `extraWriteUrlMap`, `extraReadUrlMap` or `openIngestPaths` keep the
  `url_prefix` you wrote, so it must now point at the cluster paths: a Prometheus
  import or remote-write route needs
  `url_prefix = "http://127.0.0.1:4209/insert/0/prometheus/"` (the request path
  `/api/v1/import/prometheus` or `/api/v1/write` is appended), an InfluxDB route
  `.../insert/0/influx/`, and a read route
  `url_prefix = "http://127.0.0.1:4201/select/0/prometheus/"`. An entry left at
  `http://127.0.0.1:4201/` reaches vmselect, which has no such path. An
  `openIngestPaths` entry for a Prometheus path was tested in cluster mode
  (`tests/vmauth-cluster.nix`: an anonymous import through the open door reads
  back through the read tier); `openIngestPaths` replaces the derived list, so
  repeat the OTLP route when you set it.
- **`extraFlags` ownership.** `extraFlags` is rejected when it carries
  `-httpListenAddr` (also without the `.` family suffix that was checked before)
  or `-storageNode`; each process has its own list. The flags a process takes are
  `storage.extraFlags` for vmstorage (`-dedup.minScrapeInterval`), `insert.extraFlags`
  for vminsert. `-snapshotAuthKey` is rejected in `storage.extraFlags` while
  `snapshots.enable` is true, because that is the process serving the endpoint.
  Separately, an existing `-syslog.tenantID.*` in `logs.extraFlags` is rejected
  while a syslog slot is enabled, because the slot renders it
  ([0031](./0031-victorialogs-syslog-listeners.md),
  [0032](./0032-tenants-in-token-files.md)).
- **Self-monitoring** pushes to vminsert's tenant-0 import endpoint with
  `job="vmstorage"`, `"vminsert"` and `"vmselect"`
  ([0026](./0026-self-monitoring-via-pushmetrics.md)).
- **No migration.** Nothing was deployed on the single-node layout, so no data
  move is provided.

## Not chosen

- **Keeping both modes.** A `metrics.mode` switch carried the build-up of the
  cluster so every commit stayed green, and was removed once the tests were
  ported. Keeping it would double every test and every route for a path nobody
  needs once the cluster costs about 42 MB.
- **`VM_INSTANCE_TYPE=cluster` for the metrics MCP server.** It would build
  `<entrypoint>/select/<tenant>/prometheus/...`, which is no allow-listed route
  ([0023](./0023-mcp-trust-boundary-extends-grafana.md)); stage 3 decides it.

## For stage 3

- The route table lives in `vmauth.nix` (`metricsReadPrefix`, `metricsWritePrefix`);
  tenant 0 is hard-coded there and in `self-monitoring.nix`.
- A tenant's write route is `/insert/<accountId>/...`, its read route
  `/select/<accountId>/prometheus/...`; reads and writes are different processes,
  so a client-chosen id has to be matched against the token's list on both.
- `metrics.effectiveUrl` is the read base (vmselect), `effectiveInsertUrl` the
  write base (vminsert); an override of either reaches only its own routes.
