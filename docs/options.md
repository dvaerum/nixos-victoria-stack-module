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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.extraFlags



Extra command-line flags passed straight through to Alloy\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.initialInterval



` otelcol.exporter.otlphttp `’s ` retry_on_failure.initial_interval `
on both the metrics and traces exporters\. ` null ` (the default)
omits the block entirely, matching Alloy’s own default (` 5s `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"5s"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.maxElapsedTime



` otelcol.exporter.otlphttp `’s
` retry_on_failure.max_elapsed_time ` – how long a gateway
outage can last before Alloy gives up on a batch entirely
(the disk-backed ` queue ` block is what actually protects
against data loss during that window, this just bounds how
long any ONE batch keeps retrying)\. ` null ` (the default)
omits the block entirely, matching Alloy’s own default (` 5m `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"5m"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.maxInterval



` otelcol.exporter.otlphttp `’s ` retry_on_failure.max_interval `\.
` null ` (the default) omits the block entirely, matching
Alloy’s own default (` 30s `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.tlsCaFile



CA bundle for verifying the gateway’s own server certificate on
Alloy’s OTLP exporters specifically (` otelcol.exporter.otlphttp `’s
` tls.ca_file `) – a separate knob from ` trustedCertificateFile `
below, which only covers journald-upload’s own HTTPS case (a
different, non-Alloy code path)\. ` null ` (the default) omits the
block entirely, matching Alloy’s own default (system CA trust)\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.tlsInsecureSkipVerify



Skip TLS verification on Alloy’s OTLP exporters
(` otelcol.exporter.otlphttp `’s ` tls.insecure_skip_verify `)\.
` false ` (the default) omits the setting entirely, matching
Alloy’s own default\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.hostType



A free-form label promoted onto every metric AND trace this host
ships (as the ` host_type ` attribute, via the gateway’s own
relabel config) – restricted to ` [A-Za-z0-9_.-]+ ` so it can
never break the generated Alloy config syntax it’s embedded in\.
Not an enum beyond that restriction – this module has no opinion
about what values are meaningful; that’s entirely a property of
whatever alerting rules the consumer writes on top (see
docs/decisions – this module takes no position on alerting, only
on getting the label onto the data)\. NOT applied to logs: that
path goes through systemd-journal-upload directly, with no Alloy
pipeline to attach the label in, so it may be omitted when only
` logs.enable ` is set; it is required whenever ` metrics.enable ` or
` traces.enable ` is\.



*Type:*
null or string matching the pattern \[A-Za-z0-9_\.-]+



*Default:*

```nix
null
```



*Example:*

```nix
"server"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.disabledCollectors



node_exporter collectors to disable – e\.g\. an expensive one on a
resource-constrained host\. Takes precedence over ` extraCollectors `
if a name appears in both (Alloy’s own ` disable_collectors `
semantics)\. ` [ ] ` (the default) changes nothing\.



*Type:*
list of string matching the pattern \[a-z0-9_]+



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "hwmon"
  "zfs"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.extraCollectors



Extra node_exporter collectors to enable, on top of
node_exporter’s own default-enabled set (see the “Collectors
list” table in Alloy’s ` prometheus.exporter.unix ` docs for what
that is) plus this module’s own always-on ` systemd ` collector\.
` [ ] ` (the default) changes nothing\.



*Type:*
list of string matching the pattern \[a-z0-9_]+



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "processes"
  "textfile"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.scrapeInterval



Overrides Alloy’s own ` prometheus.scrape ` default (60s) for the
host-metrics scrape job\. ` null ` (the default) omits the argument
entirely, matching Alloy’s upstream default\.



*Type:*
null or string matching the pattern (\[0-9]+(ns|us|ms|s|m|h))+



*Default:*

```nix
null
```



*Example:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.queue\.directory



Directory Alloy’s disk-backed write-back queue is stored in\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/alloy/queue
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.writeTokenFile



Path (as a plain string, NOT a Nix path literal – interpolating a
real Nix path forces a Nix-store copy at eval time, which either
crashes if the file doesn’t exist yet on the build machine, the
normal case, since it lands at runtime via LoadCredential= (see
docs/decisions/0008/0020), or leaks the plaintext secret into the
world-readable store if it does) to a file containing exactly one
bearer token (no YAML structure needed at this end – that’s
vmauth’s own ` writeTokensFile ` list on the gateway side)
authorizing this host’s write traffic\. Required whenever the
gateway’s own ` requireAuthForWrites ` is ` true ` (the default)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.package



The victoria-logs package to use\. Defaults to pkgs\.victorialogs, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.extraFlags



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
"127.0.0.1:4202"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.manageTmpfiles



Whether this module re-asserts ` dataDir `’s ownership/mode (via
` systemd.tmpfiles.rules `) on every boot, when ` dynamicUser = false ` (the static-user branch)\. The default is self-healing:
it catches drift or manual mistakes automatically, which is
central to why the static-user path works at all for an
externally-managed mount (docs/decisions/0001)\. Set to ` false `
to manage the directory’s ownership/mode entirely yourself
outside this module – a plain escape hatch for a real reason
this module can’t anticipate, not a config mismatch, so there is
deliberately no warning attached to disabling it\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.package



The mcp-victorialogs package to use\. Defaults to this flake’s own packages\.mcp-victorialogs, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.disabledTools



` MCP_DISABLED_TOOLS ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs (a comma-separated list
on the wire; this option takes a real Nix list and joins it)\.
` [ ] ` (the default) adds nothing beyond whatever the binary
you’re configuring already disables on its own\. Each binary’s
own README documents its available tool names – e\.g\.
` documentation ` disables an embedded vector-database tool
that’s otherwise the dominant source of that MCP server’s
resource usage\.

metrics’ own binary (unlike logs/traces) hardcodes 6 tools
disabled by default when this is left entirely unset –
including ` test_rules `, which WRITES synthetic series into
the live instance – confirmed directly from its source\.
Setting this option for metrics is always additive on top
of that upstream default set (mcp\.nix unions the two), never
a replacement for it – so the ` example ` above genuinely
disables only ` documentation `, it does not silently
re-enable ` test_rules `/` export `/` flags `/etc\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "documentation"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.

When reached through vmauth (e\.g\. ` /mcp/metrics `,
` /mcp/logs `, ` /mcp/traces `): request it with NO trailing
slash – vmauth strips exactly 2 path parts before
forwarding, which only lands on the MCP binary’s own fixed
` /mcp ` path (not ` /mcp/ `) when the original request has none
either\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4206"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.logFormat



` MCP_LOG_FORMAT ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` text `)\.



*Type:*
null or one of “text”, “json”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.logLevel



` MCP_LOG_LEVEL ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` info `)\.



*Type:*
null or one of “debug”, “info”, “warn”, “error”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionMaxDiskSpaceUsageBytes



` -retention.maxDiskSpaceUsageBytes ` – the maximum disk space
victoria-logs may use at ` dataDir ` before older per-day
partitions are dropped, in addition to ` retentionPeriod `\.
Mutually exclusive with ` retentionMaxDiskUsagePercent `\. ` null `
(the default) omits the flag\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"500GB"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionMaxDiskUsagePercent



` -retention.maxDiskUsagePercent ` – like
` retentionMaxDiskSpaceUsageBytes `, but as a percentage of the
filesystem holding ` dataDir `\. Mutually exclusive with it\.
` null ` (the default) omits the flag\.



*Type:*
null or signed integer



*Default:*

```nix
null
```



*Example:*

```nix
80
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-logs itself does when the flag is omitted
entirely (a 7 day default for this binary, NOT unbounded) – matching
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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.snapshots\.enable



Whether to enable periodic on-disk snapshot creation (a systemd timer calling victoria-logs’s own snapshot API)\.



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary prunes its own old snapshots
on this schedule (a binary-native mechanism, not something this
module’s timer does)\. ` null ` disables automatic pruning:
snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.snapshots\.schedule



systemd ` OnCalendar ` expression for how often to create a
snapshot\. ` daily ` is systemd’s own shorthand for midnight\.



*Type:*
string



*Default:*

```nix
"daily"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.package



The victoria-metrics package to use\. Defaults to pkgs\.victoriametrics, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.extraFlags



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
"127.0.0.1:4201"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.manageTmpfiles



Whether this module re-asserts ` dataDir `’s ownership/mode (via
` systemd.tmpfiles.rules `) on every boot, when ` dynamicUser = false ` (the static-user branch)\. The default is self-healing:
it catches drift or manual mistakes automatically, which is
central to why the static-user path works at all for an
externally-managed mount (docs/decisions/0001)\. Set to ` false `
to manage the directory’s ownership/mode entirely yourself
outside this module – a plain escape hatch for a real reason
this module can’t anticipate, not a config mismatch, so there is
deliberately no warning attached to disabling it\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.package



The mcp-victoriametrics package to use\. Defaults to this flake’s own packages\.mcp-victoriametrics, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.disabledTools



` MCP_DISABLED_TOOLS ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs (a comma-separated list
on the wire; this option takes a real Nix list and joins it)\.
` [ ] ` (the default) adds nothing beyond whatever the binary
you’re configuring already disables on its own\. Each binary’s
own README documents its available tool names – e\.g\.
` documentation ` disables an embedded vector-database tool
that’s otherwise the dominant source of that MCP server’s
resource usage\.

metrics’ own binary (unlike logs/traces) hardcodes 6 tools
disabled by default when this is left entirely unset –
including ` test_rules `, which WRITES synthetic series into
the live instance – confirmed directly from its source\.
Setting this option for metrics is always additive on top
of that upstream default set (mcp\.nix unions the two), never
a replacement for it – so the ` example ` above genuinely
disables only ` documentation `, it does not silently
re-enable ` test_rules `/` export `/` flags `/etc\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "documentation"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.

When reached through vmauth (e\.g\. ` /mcp/metrics `,
` /mcp/logs `, ` /mcp/traces `): request it with NO trailing
slash – vmauth strips exactly 2 path parts before
forwarding, which only lands on the MCP binary’s own fixed
` /mcp ` path (not ` /mcp/ `) when the original request has none
either\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4205"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.logFormat



` MCP_LOG_FORMAT ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` text `)\.



*Type:*
null or one of “text”, “json”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.logLevel



` MCP_LOG_LEVEL ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` info `)\.



*Type:*
null or one of “debug”, “info”, “warn”, “error”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-metrics itself does when the flag is omitted
entirely (a 1 month default for this binary, NOT unbounded) – matching
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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.snapshots\.enable



Whether to enable periodic on-disk snapshot creation (a systemd timer calling victoria-metrics’s own snapshot API)\.



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary prunes its own old snapshots
on this schedule (a binary-native mechanism, not something this
module’s timer does)\. ` null ` disables automatic pruning:
snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.snapshots\.schedule



systemd ` OnCalendar ` expression for how often to create a
snapshot\. ` daily ` is systemd’s own shorthand for midnight\.



*Type:*
string



*Default:*

```nix
"daily"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.package



The victoria-traces package to use\. Defaults to pkgs\.victoriatraces, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.extraFlags



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
"127.0.0.1:4203"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.manageTmpfiles



Whether this module re-asserts ` dataDir `’s ownership/mode (via
` systemd.tmpfiles.rules `) on every boot, when ` dynamicUser = false ` (the static-user branch)\. The default is self-healing:
it catches drift or manual mistakes automatically, which is
central to why the static-user path works at all for an
externally-managed mount (docs/decisions/0001)\. Set to ` false `
to manage the directory’s ownership/mode entirely yourself
outside this module – a plain escape hatch for a real reason
this module can’t anticipate, not a config mismatch, so there is
deliberately no warning attached to disabling it\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.package



The mcp-victoriatraces package to use\. Defaults to this flake’s own packages\.mcp-victoriatraces, set via mkDefault in config\.nix\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.disabledTools



` MCP_DISABLED_TOOLS ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs (a comma-separated list
on the wire; this option takes a real Nix list and joins it)\.
` [ ] ` (the default) adds nothing beyond whatever the binary
you’re configuring already disables on its own\. Each binary’s
own README documents its available tool names – e\.g\.
` documentation ` disables an embedded vector-database tool
that’s otherwise the dominant source of that MCP server’s
resource usage\.

metrics’ own binary (unlike logs/traces) hardcodes 6 tools
disabled by default when this is left entirely unset –
including ` test_rules `, which WRITES synthetic series into
the live instance – confirmed directly from its source\.
Setting this option for metrics is always additive on top
of that upstream default set (mcp\.nix unions the two), never
a replacement for it – so the ` example ` above genuinely
disables only ` documentation `, it does not silently
re-enable ` test_rules `/` export `/` flags `/etc\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "documentation"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.listenAddress



Address the MCP server listens on\. Defaults to loopback-only
(reach it via ` services.victoriaStack.vmauth `’s own ` /mcp/* `
routing); override to expose it directly if ` vmauth ` is
disabled and that’s what you want\. Requires this service’s own
` enable = true ` – there is nothing for the MCP server to proxy
to otherwise (see docs/decisions/0002-opt-in-everything\.md)\.

When reached through vmauth (e\.g\. ` /mcp/metrics `,
` /mcp/logs `, ` /mcp/traces `): request it with NO trailing
slash – vmauth strips exactly 2 path parts before
forwarding, which only lands on the MCP binary’s own fixed
` /mcp ` path (not ` /mcp/ `) when the original request has none
either\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4207"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.logFormat



` MCP_LOG_FORMAT ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` text `)\.



*Type:*
null or one of “text”, “json”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.logLevel



` MCP_LOG_LEVEL ` – confirmed identical across all three
mcp-victoria\* binaries’ own READMEs\. ` null ` (the default)
omits the env var entirely, matching each binary’s own
upstream default (` info `)\.



*Type:*
null or one of “debug”, “info”, “warn”, “error”



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionMaxDiskSpaceUsageBytes



` -retention.maxDiskSpaceUsageBytes ` – the maximum disk space
victoria-traces may use at ` dataDir ` before older per-day
partitions are dropped, in addition to ` retentionPeriod `\.
Mutually exclusive with ` retentionMaxDiskUsagePercent `\. ` null `
(the default) omits the flag\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"500GB"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionMaxDiskUsagePercent



` -retention.maxDiskUsagePercent ` – like
` retentionMaxDiskSpaceUsageBytes `, but as a percentage of the
filesystem holding ` dataDir `\. Mutually exclusive with it\.
` null ` (the default) omits the flag\.



*Type:*
null or signed integer



*Default:*

```nix
null
```



*Example:*

```nix
80
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-traces itself does when the flag is omitted
entirely (a 7 day default for this binary, NOT unbounded) – matching
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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.snapshots\.enable



Whether to enable periodic on-disk snapshot creation (a systemd timer calling victoria-traces’s own snapshot API)\.



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary prunes its own old snapshots
on this schedule (a binary-native mechanism, not something this
module’s timer does)\. ` null ` disables automatic pruning:
snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.snapshots\.schedule



systemd ` OnCalendar ` expression for how often to create a
snapshot\. ` daily ` is systemd’s own shorthand for midnight\.



*Type:*
string



*Default:*

```nix
"daily"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.package



The victoriametrics package vmauth’s binary is bundled in\. Defaults (via mkDefault) to config\.services\.victoriaStack\.metrics\.package – see docs/decisions/0007-package-override-options\.md\.



*Type:*
package

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.adminPasswordFile



Path (as a plain string – see ` writeTokensFile `’s description
for why not a Nix path literal) to a file containing the
plaintext password for vmauth’s Basic Auth “admin” user (read +
MCP paths, same access as any ` readTokensFile ` entry, just a
different credential type)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.caFile



vmauth’s ` -backend.tlsCAFile ` – CA bundle for verifying
backend TLS certificates\. A real Nix path is fine here (unlike
the credential options above): a CA bundle is public by
nature, not a runtime-staged secret\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.certFile



vmauth’s ` -backend.tlsCertFile ` – client certificate for
mTLS to HTTPS backends\. Path as a plain string, staged via
` LoadCredential= ` at runtime, same reasoning as
` adminPasswordFile ` above – paired with a private key, worth
treating with the same care even though a certificate alone
isn’t secret\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.insecureSkipVerify



vmauth’s ` -backend.tlsInsecureSkipVerify ` – skip TLS
verification when connecting to HTTPS backends\. ` false ` (the
default) omits the flag entirely, matching vmauth’s own
upstream default\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.keyFile



vmauth’s ` -backend.tlsKeyFile ` – the client private key
paired with ` certFile `, for mTLS to HTTPS backends\. Path as a
plain string, NOT a Nix path literal – this is a real private
key; the exact same eval-crash/Nix-store-leak risk as
` adminPasswordFile ` applies (docs/decisions/0020), staged via
` LoadCredential= ` at runtime\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraFlags



Extra command-line flags passed straight through to vmauth,
appended last, for anything not worth promoting to its own
typed option – e\.g\. vmauth’s own TLS listener
(` -tls `/` -tlsCertFile `/` -tlsKeyFile `)\. Same shape as the storage
services’ ` extraFlags `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-tls"
  "-tlsCertFile=/path/to/cert.pem"
  "-tlsKeyFile=/path/to/key.pem"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraReadUrlMap



Extra vmauth url_map entries for the read/admin tier, appended after the auto-derived ones\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraRequestHeaders



vmauth’s ` headers ` option – extra HTTP request headers set (or,
with an empty value, removed) before proxying to any enabled
backend\. Applied uniformly across every url_map entry this
module builds (read, write, and MCP routes alike)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "TenantID: foobar"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraResponseHeaders



vmauth’s ` response_headers ` option – extra HTTP response
headers set (or, with an empty value, removed) before returning
the backend’s response to the client\. Applied uniformly across
every url_map entry this module builds\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "Server:"
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraWriteUrlMap



Escape hatch: extra vmauth url_map entries appended to the
write-tier credential’s url_map (the read tier is untouched –
see ` extraReadUrlMap ` for that side)\. Never added to the
unauthenticated ` openIngestPaths ` door\. Same
operator’s-own-responsibility philosophy as ` extraReadUrlMap `:
entries are NOT validated against the allow-list ADR 0021
established for the built-in routes (a pattern matching every
path only draws a warning)\. Real use: VictoriaMetrics’ own
` /write ` (InfluxDB line protocol) or ` /api/v1/write ` (Prometheus
remote write), which this module opens no door for by default\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  {
    src_paths = [
      "/write"
    ];
    url_prefix = "http://127.0.0.1:4201/";
  }
]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.listenAddress



Address vmauth listens on\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4204"
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.maxConcurrentPerUserRequests



vmauth’s ` -maxConcurrentPerUserRequests ` – the limit on
concurrent requests per configured user\. ` null ` (the default)
omits the flag entirely, matching vmauth’s own upstream
default\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.maxConcurrentRequests



vmauth’s ` -maxConcurrentRequests ` – the global limit on
concurrent requests across all configured users\. ` null ` (the
default) omits the flag entirely, matching vmauth’s own
upstream default\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.openIngestPaths



vmauth ` url_map ` entries for the unauthenticated-write case only
(` requireAuthForWrites = false `)\. Auto-derived from whichever of
metrics/logs/traces is enabled; override to ` [ ] ` to close the
anonymous write door entirely, even with ` requireAuthForWrites = false `\. Has NO effect on write-tier bearer tokens
(` writeTokensFile `) either way – those always route via the
same auto-derivation, independent of this option, since a
credentialed tier must stay reachable regardless of how the
anonymous door is sized (docs/decisions/0003, 0014)\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.readTokensFile



Path (as a plain string – see ` writeTokensFile `’s description
for why not a Nix path literal) to a YAML file (typically
sops-nix rendered) containing a ` tokens: ` list of objects, each a
bearer token authorized for read + MCP paths – same shape as
` writeTokensFile ` (inline ` # ` comments; optional ` backends `
list scoping a token to those backends’ raw API *and* that
signal’s MCP route, e\.g\. ` backends: ["traces"] ` reaches
` /traces/* ` and ` /mcp/traces ` only)\. Entries used to be bare
strings; that format is now rejected with a migration message –
see ` writeTokensFile `\. Deliberately a SEPARATE file
from ` writeTokensFile ` – see
docs/decisions/0003-vmauth-two-credential-tiers\.md for why\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.writeTokensFile



Path (as a plain string, NOT a Nix path literal – interpolating
a real Nix path forces a Nix-store copy at eval time, which
either crashes if the file doesn’t exist yet on the build
machine (the normal case: it lands at runtime via
LoadCredential=, see docs/decisions/0008/0020) or leaks the
plaintext secret into the world-readable store if it does) to a
YAML file (typically sops-nix rendered) containing a ` tokens: `
list of objects, each a bearer token authorized for the
write/ingest paths only\. Each entry may carry an inline ` # `
comment (stripped automatically) naming which host/purpose it’s
for, and an optional ` backends ` list (any of ` metrics `, ` logs `,
` traces `) scoping that one token to only those backends’ ingest
doors; without it the token reaches every enabled backend\.

```yaml
tokens:
  - token: "collector-host-a-secret"   # unscoped
  - token: "tracing-only-host-secret"
    backends: ["traces"]               # scoped
```

**Breaking change:** entries used to be bare strings
(` - some-token `)\. That format is now rejected at vmauth start
with a message saying so; migrate each line to ` - token: some-token `\.
See
docs/decisions/0003-vmauth-two-credential-tiers\.md\. Required
when ` requireAuthForWrites = true ` and at least one storage
service is enabled – left unset in that combination, every
write/ingest path through vmauth rejects every request with no
credential able to open it (vmauth itself starts and reports
healthy regardless, so this fails silently until writes are
actually attempted)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/f7wmxflrrpn7xcbi2b58rk8xkji4spp9-source/nixosModule/victoriaStack/options.nix)


