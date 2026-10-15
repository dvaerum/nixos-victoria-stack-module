# 0035: Syslog listeners are a named set; the fixed slots are sugar

## Decision

`services.victoriaStack.logs.syslog.listeners` is an `attrsOf` submodule: any number
of VictoriaLogs syslog listeners, keyed by a listener name. Each has `transport`
(`udp`, `tcp` or `tls`, no default), `ipAddress` (no default, as in
[0031](0031-victorialogs-syslog-listeners.md)), `port` (514, or 6514 for `tls`),
`tenant`, `extraFields`, `openFirewall`, `suppressExposureWarning` and, for `tls`,
`certFile` and `keyFile`. The motivating case is one address per tenant with the same
transport (`team-a-udp` on one address, `team-b-udp` on another), which used to need
hand-written positional flags in `logs.extraFlags`, unchecked.

```nix
services.victoriaStack.logs.syslog.listeners = {
  team-a-udp = { transport = "udp"; ipAddress = "192.0.2.10"; tenant = "team-a"; };
  team-b-udp = { transport = "udp"; ipAddress = "192.0.2.11"; tenant = "team-b"; };
  team-b-tls = {
    transport = "tls"; ipAddress = "192.0.2.11"; tenant = "team-b";
    certFile = "/run/secrets/syslog-b.pem"; keyFile = "/run/secrets/syslog-b.key";
  };
};
```

The `udp`, `tcp` and `tls` slots of 0031 stay, as shorthand for three listeners named
`udp`, `tcp` and `tls`. Both feed one ordered list in `syslog.nix`, so the rendering,
the assertions, the warnings, the firewall ports and the capability rule have one
code path, and the same configuration written either way renders a byte-identical
unit (a test compares the whole service config).

## Why an attribute set

An attrset, not a list, so that several modules can add to it and override one
listener by name (`listeners.team-a-udp.port = 1514`), which a list cannot do.

## Order

The list is the slots (`udp`, `tcp`, `tls`), then the listeners sorted by name.
It is the position of each listener in VictoriaLogs' positional arrays (see 0031), so
the order is part of the contract: renaming a listener can change its position, and
nothing else about it. Slots come first so a slot-only configuration renders exactly
what it always did, including the existing rule that the `tcp` slot precedes the `tls`
slot. Every array of a transport (`-syslog.listenAddr`, `extraFields`, `tenantID`;
for tcp the `-syslog.tls`, `tlsCertFile` and `tlsKeyFile` arrays) is generated from that one list, so entry N
of every array belongs to the same listener. A `tls` listener is a tcp listener with TLS
on: it shares the tcp arrays with plain tcp ones, a plain one gets blank TLS entries.
Verified against the pinned VictoriaLogs 1.53.0 with three listeners of each transport
(`-help`, and a real run on `127.0.0.x` addresses that checks every socket is bound).

## Tenant and trust

Syslog has no authentication and bypasses vmauth, so **the listener a packet reaches
is the only thing that decides its tenant**: a sender cannot pick one, but anyone who
can reach a team's address can write into that team's tenant. The network must keep
each tenant's devices on their own address (firewall, VLAN). `tenant` names a declared
`services.victoriaStack.tenants.<name>` (an unknown name is an assertion), rendered as
`<accountId>:<projectId>`, `0:0` for a listener without one, and the array only exists once
some listener of the transport has a tenant.

## Details decided here

- **Names:** the tenant-name charset (1 to 63 lower-case letters, digits, `-`; no
  leading or trailing hyphen), by assertion. A listener may not share its name with an
  *enabled* slot (`udp`, `tcp`, `tls`).
- **No `enable` on a listener:** a listener exists when it is declared; there is no per-name
  switch-off, only removing it. (A slot's `enable` is what makes it sugar.)
- **TLS files:** a `tls` listener needs both files, any other transport refuses them
  (assertions, rather than silently ignoring a file). The paths follow the slot rules:
  plain strings, staged by `LoadCredential=` as `syslog-tls-cert-<name>` and
  `syslog-tls-key-<name>` (the `tls` slot keeps `syslog-tls-cert` and `syslog-tls-key`, as does a
  listener named `tls`, which is why the two render identically), watched for replacement
  like the slot's. A `%` in the path is escaped, so it works; no other path rule exists
  (the slot has none).
- **Collisions:** unchanged and protocol-aware (0031) across every listener, every slot and
  the other listeners of the module. A listener names itself in the message by its option path.
- **`extraFlags`:** a flag of an array a listener owns is rejected while any listener or
  slot of that transport exists, including `-syslog.tenantID.*`. With no listener of a
  transport the flags stay available.
- **One entry reaches the first listener only:** the warning for a shared `-syslog.<knob>.<transport>`
  flag in `extraFlags` (0031) now applies to every transport with more than one listener, udp
  included, and names the listeners in order.
- **Low ports and firewall:** a port below 1024 on any listener gives the unit
  `CAP_NET_BIND_SERVICE` (and turns `PrivateUsers` off) as before; `openFirewall` opens that
  listener's port for its protocol (tls is tcp), deduplicated.
- **Warnings:** the exposure warning is per non-loopback listener, with the listener's own
  `suppressExposureWarning`.

See [0031](0031-victorialogs-syslog-listeners.md) for the slots, the flags and TLS, and
[0032](0032-tenants-in-token-files.md) for tenants. The example is
[`examples/syslog-tenants.nix`](../../examples/syslog-tenants.nix).
