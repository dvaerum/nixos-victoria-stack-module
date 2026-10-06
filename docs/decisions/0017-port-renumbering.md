# 0017: victoriaStack service ports renumbered to a sequential scheme

## Decision

`services.victoriaStack`'s own services now default to a clean sequential
port range instead of a mix of each binary's own upstream default and
ports this project invented ad hoc:

| Service        | New default | Was    |
|----------------|-------------|--------|
| metrics        | `:4201`     | `:8428` (VictoriaMetrics' own upstream default) |
| logs           | `:4202`     | `:9428` (VictoriaLogs' own upstream default) |
| traces         | `:4203`     | `:10428` (VictoriaTraces' own upstream default) |
| vmauth         | `:4204`     | `:8880` (this project's own choice; vmauth's real upstream default is `:8427`) |
| metrics.mcp    | `:4205`     | `:8881` (this project's own choice) |
| logs.mcp       | `:4206`     | `:8882` (this project's own choice) |
| traces.mcp     | `:4207`     | `:8883` (this project's own choice) |

All seven remain fully overridable via their existing `listenAddress`
options — only the shipped defaults changed.

`nginx` is explicitly **excluded** from this renumbering (kept at its own
existing default) — an operator decision based on prior experience of
collisions with other services when nginx was moved off its standard
port.

`victoriaCollector`'s Alloy OTLP receiver (`:4317`/`:4318`) is explicitly
**out of scope** for this renumbering — it is the OpenTelemetry project's
own published, industry-wide convention for "just works, no config
needed" OTLP ingestion, not a number this project chose. Renumbering it
would only matter if the receiver were reachable from outside the
collector's own host, which it isn't (loopback-only by design), so the
decision not to touch it costs nothing either way.

## Why

An explicit, opinionated operator decision: a predictable, sequential
range across all of this module's own services (not individually tied to
each wrapped binary's own default) is easier to reason about and firewall
than a mix of three different upstream defaults plus two ad hoc choices
this project made independently. `nginx` and the collector's OTLP receiver
were each excluded for their own distinct, concrete reason (operational
collision history; external interop convention), not merely left out by
oversight.
</content>
