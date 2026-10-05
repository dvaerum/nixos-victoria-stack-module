# nixos-victoria-stack-module

A NixOS module providing a from-scratch VictoriaMetrics/VictoriaLogs/
VictoriaTraces stack with an auth gateway (vmauth), optional Grafana
datasource wiring, optional nginx reverse-proxy, optional MCP servers, and a
separate fleet-wide collector agent (`victoriaCollector`).

Status: under active implementation. See [`PLAN.md`](./PLAN.md) for the full
design and task list, and [`docs/decisions/`](./docs/decisions/) for the ADRs
behind each real design decision.

**Documentation:** [options](./docs/options.md)

## Why this exists

nixpkgs' own `services.victoriametrics`/`victorialogs`/`victoriatraces`
modules hardcode their storage path and `DynamicUser`, which conflicts with a
pre-mounted dataset (e.g. ZFS) and has no first-class `retentionPeriod` on
`victorialogs` at all. This module builds each service from scratch instead,
with `dataDir` and `dynamicUser` as real, independent options — see
`docs/decisions/0001-victoria-stack-built-from-scratch.md`.

## License

MIT, see [`LICENSE`](./LICENSE).
