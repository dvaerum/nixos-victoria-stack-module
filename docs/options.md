## _module\.args

Additional arguments passed to each module in addition to ones
like ` lib `, ` config `,
and ` pkgs `, ` modulesPath `\.

This option is also available to all submodules\. Submodules do not
inherit args from their parent module, nor do they provide args to
their parent module or sibling submodules\. The sole exception to
this is the argument ` name ` which is provided by
parent modules to a submodule and contains the attribute name
the submodule is bound to, or a unique generated name if it is
not bound to an attribute\.

Some arguments are already passed by default, of which the
following *cannot* be changed with this option:

 - ` lib `: The nixpkgs library\.

 - ` config `: The results of all options after merging the values from all modules together\.

 - ` options `: The options declared in all modules\.

 - ` specialArgs `: The ` specialArgs ` argument passed to ` evalModules `\.

 - All attributes of ` specialArgs `
   
   Whereas option values can generally depend on other option values
   thanks to laziness, this does not apply to ` imports `, which
   must be computed statically before anything else\.
   
   For this reason, callers of the module system can provide ` specialArgs `
   which are available during import resolution\.
   
   For NixOS, ` specialArgs ` includes
   ` modulesPath `, which allows you to import
   extra modules from the nixpkgs package tree without having to
   somehow make the module aware of the location of the
   ` nixpkgs ` or NixOS directories\.
   
   ```
   { modulesPath, ... }: {
     imports = [
       (modulesPath + "/profiles/minimal.nix")
     ];
   }
   ```

For NixOS, the default value for this option includes at least this argument:

 - ` pkgs `: The nixpkgs package set according to
   the ` nixpkgs.pkgs ` option\.



*Type:*
lazy attribute set of raw value



*Default:*

```nix
{ }
```

*Declared by:*
 - [\<nixpkgs/lib/modules\.nix>](https://github.com/NixOS/nixpkgs/blob//lib/modules.nix)



## services\.victoriaCollector\.alloy\.package



The Alloy package to use\. Defaults to pkgs\.grafana-alloy, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.extraFlags



Extra command-line flags passed straight through to Alloy\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.hostType



A free-form label promoted onto every metric this host ships (as
the ` host_type ` label, via the gateway’s own relabel config)\. Not
an enum deliberately – this module has no opinion about what
values are meaningful; that’s entirely a property of whatever
alerting rules the consumer writes on top (see
docs/decisions – this module takes no position on alerting, only
on getting the label onto the data)\.



*Type:*
string



*Example:*

```nix
"server"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.journaldWriteEndpoint



Overrides ` writeEndpoint ` for journald-upload specifically\. ` null `
(the default) means “same as ` writeEndpoint `”\. Only needs setting
when the two must differ, e\.g\. an HTTPS mount for Alloy’s own OTLP
traffic vs\. a separate plain-HTTP mount for journald uploads
specifically (systemd/systemd\#39166 – an HTTP/2-only buffer bug in
systemd-journal-upload with no code-level fix as of this writing;
removing TLS/ALPN/h2 from just this one hop is the only real lever)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.logs\.enable



Whether to enable shipping this host’s journal (via systemd-journal-upload) to a victoriaStack gateway\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.enable



Whether to enable shipping this host’s metrics (via Alloy/OTLP) to a victoriaStack gateway\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.queue\.directory



Directory Alloy’s disk-backed write-back queue is stored in\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/alloy/queue
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.queue\.maxSizeBytes



Size cap for Alloy’s disk-backed write-back queue (per exporter),
so a gateway outage doesn’t silently drop everything past the
small in-memory default\. A constrained edge device may want a
much smaller cap; a busier host may want more headroom – no
universally-right value, hence a real option rather than a fixed
constant\.



*Type:*
signed integer



*Default:*

```nix
1073741824
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.traces\.enable



Whether to enable shipping traces (via Alloy/OTLP) to a victoriaStack gateway\. Also
stands up a local OTLP receiver for host-local apps that already
speak OTLP – tied 1:1 to this toggle, since a receiver with nowhere
to forward collected spans is a dead end (see
docs/decisions/0002-opt-in-everything\.md’s same reasoning applied
here)\.
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.trustedCertificateFile



CA bundle used to verify the gateway’s own server certificate for
journald-upload’s HTTPS case\. Defaults to the system’s normal CA
bundle\.



*Type:*
absolute path



*Default:*

```nix
/etc/ssl/certs/ca-certificates.crt
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.writeEndpoint



Base URL of the victoriaStack vmauth gateway’s write/ingest paths\.
Carries its own scheme (http/https) – not assumed here, since
consumers differ (plain HTTP over a trusted LAN vs\. HTTPS over a
tailnet)\.



*Type:*
string



*Example:*

```nix
"https://victoria-stack.example.com:8443"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.writeTokenFile



Path to a file containing exactly one bearer token (no YAML
structure needed at this end – that’s vmauth’s own
` writeTokensFile ` list on the gateway side) authorizing this host’s
write traffic\. Required whenever the gateway’s own
` requireAuthForWrites ` is ` true ` (the default)\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaStack\.grafana\.enable



Whether to enable Grafana datasource provisioning for whichever of metrics/logs/traces
is enabled\. Does NOT configure services\.grafana itself (left entirely
to the consumer) and never routes through vmauth – see
docs/decisions/0010-grafana-direct-loopback-own-auth\.md
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.enable



Whether to enable victorialogs\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.package



The victoria-logs package to use\. Defaults to pkgs\.victorialogs, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.dataDir



Directory the victoria-logs binary stores its data in
(` -storageDataPath `)\. Changing this away from the default
` /var/lib/victorialogs ` – e\.g\. to point at an externally-mounted
dataset – requires ` dynamicUser = false ` (static user); see
` suppressDynamicUserWarning ` and
docs/decisions/0009-dynamicuser-warning-not-assertion\.md for why
this is a warning, not a hard assertion\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/victorialogs
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.dynamicUser



Whether to run victoria-logs under a systemd ` DynamicUser `
(nixpkgs’ own default behavior for these binaries) or a static,
stable system user\. ` DynamicUser `’s ` StateDirectory ` handling
tries to migrate a pre-existing ` dataDir ` into a private
DynamicUser-managed copy on every start, which fails outright
(“Device or resource busy”) once ` dataDir ` is itself an
externally-managed mount (e\.g\. a ZFS dataset) – confirmed on two
independent real deployments\. Set this to ` false ` whenever
` dataDir ` is not the default ` /var/lib/victorialogs ` path\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.extraOptions



Extra command-line flags passed straight through to victoria-logs,
for anything not worth promoting to its own typed option\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-search.maxUniqueTimeseries=300000"
]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.listenAddress



Address victoria-logs listens on\. Defaults to loopback-only –
` services.victoriaStack.vmauth ` is the sanctioned way to reach it
from outside this host\. Override to ` 0.0.0.0:<port> ` to bypass
vmauth entirely and expose it directly, if that’s deliberately
what you want\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:9428"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.enable



Whether to enable an MCP (Model Context Protocol) server fronting this victorialogs instance\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.package



The mcp-victorialogs package to use\. Defaults to this flake’s own packages\.mcp-victorialogs, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:8882"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-logs itself does when the flag is omitted
entirely (effectively unbounded for these binaries) – matching
upstream’s own default rather than imposing an opinionated one\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.suppressDynamicUserWarning



Silence the build-time warning emitted when ` dataDir ` has been
customized away from ` /var/lib/... ` while ` dynamicUser ` is still
` true `\. Use once you’ve deliberately confirmed this combination
is what you want (it almost never is – see ` dynamicUser `’s own
description)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.enable



Whether to enable victoriametrics\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.package



The victoria-metrics package to use\. Defaults to pkgs\.victoriametrics, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.dataDir



Directory the victoria-metrics binary stores its data in
(` -storageDataPath `)\. Changing this away from the default
` /var/lib/victoriametrics ` – e\.g\. to point at an externally-mounted
dataset – requires ` dynamicUser = false ` (static user); see
` suppressDynamicUserWarning ` and
docs/decisions/0009-dynamicuser-warning-not-assertion\.md for why
this is a warning, not a hard assertion\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/victoriametrics
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.dynamicUser



Whether to run victoria-metrics under a systemd ` DynamicUser `
(nixpkgs’ own default behavior for these binaries) or a static,
stable system user\. ` DynamicUser `’s ` StateDirectory ` handling
tries to migrate a pre-existing ` dataDir ` into a private
DynamicUser-managed copy on every start, which fails outright
(“Device or resource busy”) once ` dataDir ` is itself an
externally-managed mount (e\.g\. a ZFS dataset) – confirmed on two
independent real deployments\. Set this to ` false ` whenever
` dataDir ` is not the default ` /var/lib/victoriametrics ` path\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.extraOptions



Extra command-line flags passed straight through to victoria-metrics,
for anything not worth promoting to its own typed option\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-search.maxUniqueTimeseries=300000"
]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.listenAddress



Address victoria-metrics listens on\. Defaults to loopback-only –
` services.victoriaStack.vmauth ` is the sanctioned way to reach it
from outside this host\. Override to ` 0.0.0.0:<port> ` to bypass
vmauth entirely and expose it directly, if that’s deliberately
what you want\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:8428"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.enable



Whether to enable an MCP (Model Context Protocol) server fronting this victoriametrics instance\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.package



The mcp-victoriametrics package to use\. Defaults to this flake’s own packages\.mcp-victoriametrics, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:8881"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-metrics itself does when the flag is omitted
entirely (effectively unbounded for these binaries) – matching
upstream’s own default rather than imposing an opinionated one\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.suppressDynamicUserWarning



Silence the build-time warning emitted when ` dataDir ` has been
customized away from ` /var/lib/... ` while ` dynamicUser ` is still
` true `\. Use once you’ve deliberately confirmed this combination
is what you want (it almost never is – see ` dynamicUser `’s own
description)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.nginx\.enable



Whether to enable a single nginx vhost reverse-proxying to vmauth, covering every
currently-enabled service plus Grafana (if enabled)\. Requires
` vmauth.enable = true ` – see docs/decisions/0002-opt-in-everything\.md
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.nginx\.domain



Optional FQDN for the vhost’s ` server_name `\. ` null ` (the
default) serves on plain IP/hostname with no domain-specific
behavior – this module deliberately has no ACME/TLS opinion
either way\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.enable



Whether to enable victoriatraces\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.package



The victoria-traces package to use\. Defaults to pkgs\.victoriatraces, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.dataDir



Directory the victoria-traces binary stores its data in
(` -storageDataPath `)\. Changing this away from the default
` /var/lib/victoriatraces ` – e\.g\. to point at an externally-mounted
dataset – requires ` dynamicUser = false ` (static user); see
` suppressDynamicUserWarning ` and
docs/decisions/0009-dynamicuser-warning-not-assertion\.md for why
this is a warning, not a hard assertion\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/victoriatraces
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.dynamicUser



Whether to run victoria-traces under a systemd ` DynamicUser `
(nixpkgs’ own default behavior for these binaries) or a static,
stable system user\. ` DynamicUser `’s ` StateDirectory ` handling
tries to migrate a pre-existing ` dataDir ` into a private
DynamicUser-managed copy on every start, which fails outright
(“Device or resource busy”) once ` dataDir ` is itself an
externally-managed mount (e\.g\. a ZFS dataset) – confirmed on two
independent real deployments\. Set this to ` false ` whenever
` dataDir ` is not the default ` /var/lib/victoriatraces ` path\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.extraOptions



Extra command-line flags passed straight through to victoria-traces,
for anything not worth promoting to its own typed option\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-search.maxUniqueTimeseries=300000"
]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.listenAddress



Address victoria-traces listens on\. Defaults to loopback-only –
` services.victoriaStack.vmauth ` is the sanctioned way to reach it
from outside this host\. Override to ` 0.0.0.0:<port> ` to bypass
vmauth entirely and expose it directly, if that’s deliberately
what you want\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:10428"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.enable



Whether to enable an MCP (Model Context Protocol) server fronting this victoriatraces instance\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.package



The mcp-victoriatraces package to use\. Defaults to this flake’s own packages\.mcp-victoriatraces, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:8883"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-traces itself does when the flag is omitted
entirely (effectively unbounded for these binaries) – matching
upstream’s own default rather than imposing an opinionated one\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.suppressDynamicUserWarning



Silence the build-time warning emitted when ` dataDir ` has been
customized away from ` /var/lib/... ` while ` dynamicUser ` is still
` true `\. Use once you’ve deliberately confirmed this combination
is what you want (it almost never is – see ` dynamicUser `’s own
description)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.enable



Whether to run vmauth, the auth/routing gateway in front of
whichever of metrics/logs/traces are enabled\. Auto-defaults to
` true ` (via ` mkDefault `, so it stays overridable) whenever any of
those is enabled – see
docs/decisions/0002-opt-in-everything\.md\. A ` true ` value here has
no effect at all if none of metrics/logs/traces is enabled (there
is nothing to front)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.package



The victoriametrics package vmauth’s binary is bundled in\. Defaults (via mkDefault) to config\.services\.victoriaStack\.metrics\.package – see docs/decisions/0007-package-override-options\.md\.



*Type:*
package

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.adminPasswordFile



Path to a file containing the plaintext password for vmauth’s
Basic Auth “admin” user (read + MCP paths, same access as any
` readTokensFile ` entry, just a different credential type)\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraReadUrlMap



Extra vmauth url_map entries for the read/admin tier, appended after the auto-derived ones\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.idleConnTimeout



vmauth’s ` -http.idleConnTimeout `\. The default of ` 1m ` sits right
on top of a typical collector’s own OTLP export interval
(confirmed in production: ~52-60s), producing intermittent
“connection reset by peer” retries as vmauth force-closes
connections collectors are about to reuse\. 5m gives real headroom\.



*Type:*
string



*Default:*

```nix
"5m"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.listenAddress



Address vmauth listens on\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:8880"
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.openIngestPaths



vmauth ` url_map ` entries for the unauthenticated-write case
(` requireAuthForWrites = false `)\. Auto-derived from whichever of
metrics/logs/traces is enabled; override to ` [ ] ` to close
writes entirely even with ` requireAuthForWrites = false ` (has no
effect when ` requireAuthForWrites = true `, since those paths
require the write-tier credential regardless of this list)\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.readTokensFile



Path to a YAML file (typically sops-nix rendered) containing a
` tokens: ` list of bearer tokens authorized for read + MCP paths\.
Deliberately a SEPARATE file from ` writeTokensFile ` – see
docs/decisions/0003-vmauth-two-credential-tiers\.md for why\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.requireAuthForWrites



Whether the native ingest/write paths for enabled backends
require a write-tier credential (` writeTokensFile `)\. Default
` true `\. Set to ` false ` to open those paths to any caller that can
reach vmauth at all, relying on a network boundary (e\.g\. a
tailnet) as the only gate instead – a single toggle, not a
per-path list to maintain\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.writeTokensFile



Path to a YAML file (typically sops-nix rendered) containing a
` tokens: ` list of bearer tokens authorized for the write/ingest
paths only\. Each entry may carry an inline ` # ` comment (stripped
automatically) naming which host/purpose it’s for\. See
docs/decisions/0003-vmauth-two-credential-tiers\.md\. Required
when ` requireAuthForWrites = true ` and at least one storage
service is enabled\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/q0x26mk1py4wj3s05h0sx7s2dnah180p-source/nixosModule/victoriaStack/options.nix)


