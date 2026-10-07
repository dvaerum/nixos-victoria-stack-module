# 0016: nginx mirrors what it fronts — never an independently-chosen
default

## Decision

House rule: any nginx tunable for a location that fronts another service
in this module is either **derived from that service's own setting** or
**copied verbatim from that service's own official documentation** —
never picked independently. Any future deviation from this rule needs its
own ADR justifying the drift.

Applied now:

- **`/victoria/` (reads-only front for vmauth, ADR 0025)**: `proxy_connect_timeout` /
  `proxy_send_timeout` / `proxy_read_timeout` are derived from
  `services.victoriaStack.vmauth.idleConnTimeout` (single source of
  truth — cannot drift out of sync with vmauth's own already-tuned
  value). `client_max_body_size` is
  `nginx.maxRequestBodySize` (default `8m`) with `proxy_request_buffering
  off`: vmauth itself has no body-size ceiling of its own (confirmed from
  vmauth's real upstream docs — it only has request-body *buffering*,
  `-requestBufferSize`/`-maxQueueDuration`, a different concept entirely
  — freeing backend connections sooner on slow uploads, not limiting max
  size), so nginx is where an oversized anonymous body is stopped, and
  with buffering off vmauth checks the credential first.

- **`/grafana/` (fronts Grafana)**: implements Grafana's own official
  sub-path reverse-proxy configuration
  (grafana.com/tutorials/run-grafana-behind-a-proxy/) verbatim — a
  `map $http_upgrade $connection_upgrade {}` block at the `http{}` level
  (via `services.nginx.appendHttpConfig`), a `proxy_set_header Host
  $host;`, and a `rewrite ^/grafana/(.*) /$1 break;` rule. This also adds
  a previously entirely-missing `/grafana/api/live/` location — Grafana's
  own docs mark this as *required* for Grafana Live (WebSocket-based
  real-time dashboard/alerting updates) to work at all through a
  sub-path reverse proxy; without it, Grafana Live silently fails to
  connect through this module's nginx, undetected by any prior review
  pass since catching it required fetching Grafana's own docs rather than
  reading this module's code in isolation.

## Why

Two previously-unaddressed gaps motivated this: no way to raise nginx's
body-size ceiling below what big OTLP/journald ingest batches could need
(found by review), and — found only while implementing this ADR, not by
any of the four review agents — an entire missing nginx location required
for Grafana Live to function. Both share the same root cause: nginx's
settings for the services it fronts were chosen independently of those
services' own tuning or documented requirements, rather than derived from
them. The house rule exists so this class of drift can't recur silently
the next time either vmauth or Grafana's own configuration changes.
</content>
