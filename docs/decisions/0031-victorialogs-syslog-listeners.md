# 0031: VictoriaLogs syslog listeners: opt-in slots, no default address, no authentication

## Decision

`services.victoriaStack.logs.syslog` has the fixed slots `udp` and `tcp`
(like `vmauth.https` / `vmauth.http`), each rendering one VictoriaLogs
`-syslog.listenAddr.*` listener. A slot has `enable`, `ipAddress`, `port` (separate
options, never one `ip:port` string; default 514) and `extraFields`.
Anything beyond a slot (a second listener of one transport, a unix socket, tenants,
stream fields, compression, `-syslog.timezone`) goes through `logs.extraFlags`.

- **No default address.** A slot does nothing until `ipAddress` is set; enabling it
  without one is an assertion failure.
- **Every entry is labelled.** `extraFields` defaults to `{ source = "syslog"; }`,
  rendered as the JSON object the flag requires; it can be overridden or extended.
- **Low ports.** A port below 1024 (514 is the standard one) gives the unit
  `CAP_NET_BIND_SERVICE` in the bounding and ambient sets and turns `PrivateUsers`
  off, exactly as for vmauth ([0015](0015-systemd-hardening-baseline-wait4x-readiness.md)):
  a capability inside a user namespace does not count for binding. With every port
  at 1024 or above the empty capability set stays untouched.
- **No tenant option.** The module has no tenant plumbing on the query side, so
  everything stays in tenant 0:0 where the read tier, Grafana and the MCP server see it.

## Why

VictoriaLogs' syslog ingestion has no authentication and no client-certificate
option (measured on 1.53.0: `-help` has no `clientCA`/`mtls`/`auth`/`password` flag
for syslog). Anyone who can reach the port can write log lines, claim any hostname or
program name, and create streams: the stream is `app_name`, `hostname` and `proc_id`
by default, all sender-chosen, so an unauthenticated sender controls stream
cardinality. Syslog is therefore a door that bypasses vmauth's credential tiers
([0003](0003-vmauth-two-credential-tiers.md)): per-host token revocation does not
apply to it. That is why nothing opens by default and why the exposure is documented
on the options, not hidden.

The `-syslog.*` flags are arrays that are positional per transport (`.tcp`, `.udp`):
entry N belongs to the Nth `-syslog.listenAddr.<transport>`. The module generates
every array from one ordered list of active slots, so the arrays cannot drift apart;
a blank entry means "default" for a slot
with nothing to say. `-syslog.extraFields.*` must be a JSON object (`a=b` is a fatal
parse error); JSON commas and quotes inside it do not split the array item.

Measured facts the design relies on (VictoriaLogs 1.53.0): udp and tcp on one port
both bind; a tcp listener on an HTTP port is a fatal bind error but a udp one is not
(so the collision check needs the protocol); rows become searchable about a second
after they arrive.

## Assertions, warning and `extraFlags`

- A slot needs `logs.enable` (the listener is part of the VictoriaLogs process) and
  an `ipAddress`: assertions.
- Listener collisions are protocol-aware: the check compares host and port only
  within one protocol, because udp and tcp sockets can share a port (syslog on 514,
  or udp on the number of an HTTP port). A tcp slot still collides with every other
  tcp listener the module binds (the HTTP ports, vmauth's doors, nginx, Grafana).
- A listener on a non-loopback address without TLS gets an evaluation **warning**,
  never an assertion: a firewall or a trusted network may legitimately restrict it.
  Each slot has its own `suppressExposureWarning`, like `suppressDynamicUserWarning`
  ([0009](0009-dynamicuser-warning-not-assertion.md)).
- `extraFlags` may not carry a flag of an array the module renders for a transport
  that has an enabled slot (`-syslog.listenAddr.<t>`, `-syslog.extraFields.<t>`, and
  for tcp the `-syslog.tls`, `-syslog.tlsCertFile`, `-syslog.tlsKeyFile` arrays): the
  arrays are positional, so a stray entry shifts every slot after it. The unix
  transport and the scalar flags (`-syslog.timezone`, `-syslog.tlsMinVersion`) stay
  free; `-syslog.tls` is owned by exact name for that reason.

See [0025](0025-vmauth-public-write-doors.md) for the other public door.
