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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.dynamicUser



Whether Alloy runs as a systemd ` DynamicUser ` (nixpkgs’ own default
for it) or as a static ` alloy ` user and group\. A dynamic user can
only write inside its own ` StateDirectory ` (` /var/lib/alloy `), so a
` queue.directory ` outside it needs ` dynamicUser = false `: nothing
would otherwise own that directory for the dynamic user, and Alloy
would fail at run time\. With a static user the module creates the
directory for it (` manageTmpfiles `) and re-adds the sandboxing a
dynamic user implies\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.extraFlags



Extra command-line flags passed straight through to Alloy\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.manageTmpfiles



With ` dynamicUser = false `, whether this module creates
` queue.directory ` (mode 0750, owned by ` alloy `) on every boot via
` systemd.tmpfiles.rules `\. The directory is only created when it is
outside ` /var/lib/alloy `: inside it, the unit’s own ` StateDirectory `
already covers it\. Set to ` false ` to manage a directory outside it
yourself\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.initialInterval



` otelcol.exporter.otlphttp `’s ` retry_on_failure.initial_interval `
on both the metrics and traces exporters\. ` null ` (the default)
omits the block entirely, matching Alloy’s own default (` 5s `)\.



*Type:*
null or string matching the pattern (\[0-9]+(ns|us|ms|s|m|h))+



*Default:*

```nix
null
```



*Example:*

```nix
"5s"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.maxElapsedTime



` otelcol.exporter.otlphttp `’s
` retry_on_failure.max_elapsed_time ` – how long a gateway
outage can last before Alloy gives up on a batch entirely\.
The default ` "0s" ` means never: a batch keeps retrying until the
gateway is back, and the disk-backed ` queue ` is what bounds the
data held (when it is full the oldest data is dropped)\. Alloy’s
own default is ` 5m `, after which it logs “Dropping data” even
though the queue still has room – so a longer outage would lose
data the queue was meant to protect\. Set a duration to give up
sooner; ` null ` omits the setting (Alloy’s own ` 5m `)\.



*Type:*
null or string matching the pattern (\[0-9]+(ns|us|ms|s|m|h))+



*Default:*

```nix
"0s"
```



*Example:*

```nix
"5m"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.retryOnFailure\.maxInterval



` otelcol.exporter.otlphttp `’s ` retry_on_failure.max_interval `\.
` null ` (the default) omits the block entirely, matching
Alloy’s own default (` 30s `)\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.alloy\.suppressDynamicUserWarning



Silence the build-time warning for a dynamic user with a
` queue.directory ` outside ` /var/lib/alloy ` (use once you have made
that directory writable for Alloy’s runtime user yourself)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.hostType



A free-form label promoted onto every metric AND trace this host
ships, as the ` host_type ` label (` {host_type="server"} ` in a
query; series stored by older versions carry ` host.type `
instead) – restricted to ` [A-Za-z0-9_.-]+ ` so it can
never break the generated Alloy config syntax it’s embedded in\.
Not an enum beyond that restriction – this module has no opinion
about what values are meaningful; that’s entirely a property of
whatever alerting rules the consumer writes on top (this module
only gets the label onto the data)\. NOT applied to logs: that
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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.extraCollectors



Extra node_exporter collectors to enable, on top of
node_exporter’s own default-enabled set (see the “Collectors
list” table in Alloy’s ` prometheus.exporter.unix ` docs for what
that is) plus this module’s own always-on ` systemd ` collector\.
` [ ] ` (the default) changes nothing\.

Alloy ignores a collector name it does not know without an error, so
a misspelt name does nothing: check that the metrics you expect
actually appear\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.metrics\.scrapeInterval



Overrides Alloy’s own ` prometheus.scrape ` default (60s) for the
host-metrics scrape job\. ` null ` (the default) omits the argument
entirely, matching Alloy’s upstream default\. Must be longer than zero\.
Below 10s the module also sets ` scrape_timeout ` to the interval:
Alloy’s own 10s timeout default makes it exit at start when it
exceeds the interval\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.queue\.directory



Directory Alloy’s disk-backed write-back queue is stored in\.



*Type:*
absolute path



*Default:*

```nix
/var/lib/alloy/queue
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.queue\.maxSizeBytes



Size cap for Alloy’s disk-backed write-back queue (per exporter),
so a gateway outage doesn’t silently drop everything past the
small in-memory default\. A constrained edge device may want a
much smaller cap; a busier host may want more headroom – no
universally-right value, hence a real option rather than a fixed
constant\.



*Type:*
positive integer, meaning >0



*Default:*

```nix
1073741824
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.traces\.receiver\.grpcPort



Port of the local OTLP/gRPC receiver ` traces.enable ` stands up (loopback
only, for apps on this host)\. Change it when 4317 is already taken\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
4317
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaCollector\.traces\.receiver\.httpPort



Port of the local OTLP/HTTP receiver (loopback only)\. Change it when 4318
is already taken\.



*Type:*
16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
4318
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



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

Rotation: replacing the file’s content only takes effect once
` victoria-collector-alloy-write-token.service ` (which renders it for
Alloy) and ` victoria-collector-journal-upload-token.service ` (for the
log uploader) are restarted; restarting them restarts the services that
require them, so Alloy and systemd-journal-upload send the new token\. With
sops-nix, list both units in the secret’s ` restartUnits `\. If a render
unit fails, the services that require it stop rather than keep sending
a stale or missing token\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaCollector/options.nix)



## services\.victoriaStack\.grafana\.enable



Whether to enable Grafana datasource provisioning for whichever of metrics/logs/traces
is enabled\. Configures services\.grafana only for the datasources (and
the ` declarativePlugins ` the metrics and logs datasources need) and,
when ` nginx.enable ` is on, a default ` root_url ` for the ` /grafana/ `
sub-path; users and passwords are left to the consumer\. The
datasources go through vmauth’s read tier, never straight to a
backend, so a Grafana Viewer can read but not write or delete\. Needs
` vmauth.enable ` and ` readTokenFile ` – see
docs/decisions/0029-grafana-datasources-through-vmauth-read-tier\.md
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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.grafana\.readTokenFile



Path (as a plain string – see ` vmauth.writeTokensFile `’s
description for why not a Nix path literal) to a file holding ONE
bearer token, the credential Grafana’s datasources send to vmauth\.
Required when ` grafana.enable ` is on\.

The same token must also be listed in ` vmauth.readTokensFile `;
this module does not add it for you, so a mismatch makes every
datasource query fail with 401 (closed, never open)\. Keep it
separate from your other read tokens, so it can be rotated alone\.

The file is delivered to Grafana’s unit with systemd
` LoadCredential= `, so it need not be readable by the ` grafana `
user\. Replacing it restarts Grafana automatically, since Grafana
reads it only at start\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.package



The victoria-logs package to use\. Defaults to pkgs\.victorialogs\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.extraFlags



Extra command-line flags passed straight through to victoria-logs,
for anything not worth promoting to its own typed option\.

Flags that change addressing or auth (` -http.pathPrefix* `, ` -tls* `,
` -httpAuth.* `) are rejected at build time: the module’s readiness
check and self-push use plain http on the known address and path\.
Put nginx in front of the service instead\.

The ` syslog.udp ` / ` syslog.tcp ` options own the ` -syslog.listenAddr.* `
and ` -syslog.extraFields.* ` arrays of their transport (and the
` -syslog.tls `, ` -syslog.tlsCertFile ` and ` -syslog.tlsKeyFile ` arrays
while a tcp slot is enabled): those arrays are positional with the
listeners, so a flag of the same array here is rejected at build time\.
Every other ` -syslog.* ` flag, and the ` unix ` transport, can be passed
here freely\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.mcp\.package



The mcp-victorialogs package to use\. Defaults to this flake’s own packages\.mcp-victorialogs\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionMaxDiskSpaceUsageBytes



` -retention.maxDiskSpaceUsageBytes ` – the maximum disk space
victoria-logs may use at ` dataDir ` before older per-day
partitions are dropped, in addition to ` retentionPeriod `\.
Mutually exclusive with ` retentionMaxDiskUsagePercent `\. ` null `
(the default) omits the flag\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?(\[KMGT]i?B)?



*Default:*

```nix
null
```



*Example:*

```nix
"500GB"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionMaxDiskUsagePercent



` -retention.maxDiskUsagePercent ` – like
` retentionMaxDiskSpaceUsageBytes `, but as a percentage of the
filesystem holding ` dataDir `\. Mutually exclusive with it\.
` null ` (the default) omits the flag\.



*Type:*
null or integer between 1 and 100 (both inclusive)



*Default:*

```nix
null
```



*Example:*

```nix
80
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-logs itself does when the flag is omitted
entirely (a 7 day default for this binary, NOT unbounded) – matching
upstream’s own default rather than imposing an opinionated one\.

The minimum is 1 day: a shorter value (` 1h `, ` 23h `, ` 0 `) makes
victoria-logs refuse to start, and evaluation warns about it\. A bare
number means months, so ` 1 ` is one month, not one day\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.selfMonitoring\.enable



Whether victoria-logs pushes its own ` /metrics ` page into the local
VictoriaMetrics instance\.

 - On by default whenever ` services.victoriaStack.metrics.enable ` is
   true (there is then a database to push into)\.
 - Off by default when the metrics database is not enabled on this
   host, so logs-only or traces-only setups need no change\.
 - Set it to ` false ` to opt a service out\. Setting it to ` true `
   without ` metrics.enable ` is an error: there is nothing to push to\.



*Type:*
boolean



*Default:*

```nix
config.services.victoriaStack.metrics.enable
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.selfMonitoring\.interval



How often victoria-logs pushes its own metrics (` -pushmetrics.interval `)\.
Only used when ` selfMonitoring.enable ` is true\. The series carry a
` job ` label naming the service, so the four services stay apart\.



*Type:*
string matching the pattern (\[0-9]+(ms|s|m|h))+



*Default:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary itself prunes snapshots older
than this (not the ` schedule ` timer, which only creates them)\.
Same format as ` retentionPeriod `: a number with one optional
unit (` s `, ` h `, ` d `, ` w `, ` M `, ` y `; a bare number is months),
or several ` s `/` h `/` d `/` w ` parts such as ` 1d12h `; ` 0 ` disables
pruning\.
` null ` disables automatic pruning (it passes
` -snapshotsMaxAge=0 `; leaving the flag out would keep each
binary’s own 3d default): snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.tcp\.enable



Whether to enable the tcp syslog listener of VictoriaLogs\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.tcp\.extraFields



Fields added to every entry received on this listener
(` -syslog.extraFields.* `)\. The default labels everything ` source=syslog `;
override ` source ` or add fields as needed\. ` { } ` adds nothing\.



*Type:*
attribute set of string



*Default:*

```nix
{
  source = "syslog";
}
```



*Example:*

```nix
{
  site = "lab";
  source = "router";
}
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.tcp\.ipAddress



Address the listener binds; required once the slot is enabled, with no
default so that nothing opens by accident\. ` 0.0.0.0 ` or ` :: ` accept
syslog from every network the host is on\. An IPv6 address (contains
` : `) is bracketed automatically\.

VictoriaLogs’ syslog ingestion has NO authentication: anyone who can
reach the port can write log lines, claim any hostname or program name,
and create new streams (each distinct hostname/app_name/proc_id
combination is one)\. Bind a specific address and restrict who can
reach the port with a firewall\. A listener on a non-loopback address
without TLS also sends the logs unencrypted, and evaluation warns about
it (see ` suppressExposureWarning `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"192.0.2.10"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.tcp\.port



Port of the listener\. A port below 1024 gives the VictoriaLogs unit
` CAP_NET_BIND_SERVICE ` (and turns off ` PrivateUsers `, since a
capability inside a user namespace does not count for binding); the
unit keeps its empty capability set otherwise\.



*Type:*
integer between 1 and 65535 (both inclusive)



*Default:*

```nix
514
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.tcp\.suppressExposureWarning



Silences the evaluation warning that this listener accepts unencrypted,
unauthenticated syslog from the network (an address other than
loopback)\. Set it once you have confirmed that a firewall or a trusted
network restricts who can reach the port; same idea as
` suppressDynamicUserWarning `
(docs/decisions/0009-dynamicuser-warning-not-assertion\.md)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.udp\.enable



Whether to enable the udp syslog listener of VictoriaLogs\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.udp\.extraFields



Fields added to every entry received on this listener
(` -syslog.extraFields.* `)\. The default labels everything ` source=syslog `;
override ` source ` or add fields as needed\. ` { } ` adds nothing\.



*Type:*
attribute set of string



*Default:*

```nix
{
  source = "syslog";
}
```



*Example:*

```nix
{
  site = "lab";
  source = "router";
}
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.udp\.ipAddress



Address the listener binds; required once the slot is enabled, with no
default so that nothing opens by accident\. ` 0.0.0.0 ` or ` :: ` accept
syslog from every network the host is on\. An IPv6 address (contains
` : `) is bracketed automatically\.

VictoriaLogs’ syslog ingestion has NO authentication: anyone who can
reach the port can write log lines, claim any hostname or program name,
and create new streams (each distinct hostname/app_name/proc_id
combination is one)\. Bind a specific address and restrict who can
reach the port with a firewall\. A listener on a non-loopback address
without TLS also sends the logs unencrypted, and evaluation warns about
it (see ` suppressExposureWarning `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"192.0.2.10"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.udp\.port



Port of the listener\. A port below 1024 gives the VictoriaLogs unit
` CAP_NET_BIND_SERVICE ` (and turns off ` PrivateUsers `, since a
capability inside a user namespace does not count for binding); the
unit keeps its empty capability set otherwise\.



*Type:*
integer between 1 and 65535 (both inclusive)



*Default:*

```nix
514
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.logs\.syslog\.udp\.suppressExposureWarning



Silences the evaluation warning that this listener accepts unencrypted,
unauthenticated syslog from the network (an address other than
loopback)\. Set it once you have confirmed that a firewall or a trusted
network restricts who can reach the port; same idea as
` suppressDynamicUserWarning `
(docs/decisions/0009-dynamicuser-warning-not-assertion\.md)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.package



The victoria-metrics package to use\. Defaults to pkgs\.victoriametrics\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.extraFlags



Extra command-line flags passed straight through to victoria-metrics,
for anything not worth promoting to its own typed option\.

Flags that change addressing or auth (` -http.pathPrefix* `, ` -tls* `,
` -httpAuth.* `) are rejected at build time: the module’s readiness
check and self-push use plain http on the known address and path\.
Put nginx in front of the service instead\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.mcp\.package



The mcp-victoriametrics package to use\. Defaults to this flake’s own packages\.mcp-victoriametrics\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-metrics itself does when the flag is omitted
entirely (a 1 month default for this binary, NOT unbounded) – matching
upstream’s own default rather than imposing an opinionated one\.

The minimum is 1 day: a shorter value (` 1h `, ` 23h `, ` 0 `) makes
victoria-metrics refuse to start, and evaluation warns about it\. A bare
number means months, so ` 1 ` is one month, not one day\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.selfMonitoring\.enable



Whether victoria-metrics pushes its own ` /metrics ` page into the local
VictoriaMetrics instance\.

 - On by default whenever ` services.victoriaStack.metrics.enable ` is
   true (there is then a database to push into)\.
 - Off by default when the metrics database is not enabled on this
   host, so logs-only or traces-only setups need no change\.
 - Set it to ` false ` to opt a service out\. Setting it to ` true `
   without ` metrics.enable ` is an error: there is nothing to push to\.



*Type:*
boolean



*Default:*

```nix
config.services.victoriaStack.metrics.enable
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.selfMonitoring\.interval



How often victoria-metrics pushes its own metrics (` -pushmetrics.interval `)\.
Only used when ` selfMonitoring.enable ` is true\. The series carry a
` job ` label naming the service, so the four services stay apart\.



*Type:*
string matching the pattern (\[0-9]+(ms|s|m|h))+



*Default:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.metrics\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary itself prunes snapshots older
than this (not the ` schedule ` timer, which only creates them)\.
Same format as ` retentionPeriod `: a number with one optional
unit (` s `, ` h `, ` d `, ` w `, ` M `, ` y `; a bare number is months),
or several ` s `/` h `/` d `/` w ` parts such as ` 1d12h `; ` 0 ` disables
pruning\.
` null ` disables automatic pruning (it passes
` -snapshotsMaxAge=0 `; leaving the flag out would keep each
binary’s own 3d default): snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.nginx\.enable



Whether to enable a single nginx vhost reverse-proxying to vmauth: ` /victoria/ ` proxies
the READ routes only (not writes), plus ` /grafana/ ` when Grafana is
enabled; everything else under ` /victoria/ ` is a 404\. Requires
` vmauth.enable = true ` – see docs/decisions/0002-opt-in-everything\.md

Note: behind nginx, vmauth sees nginx’s address instead of the real
client’s (its real-IP setting is Enterprise-only); nginx’s own log has
the real client\. See docs/architecture\.md, “Client addresses behind a
reverse proxy”\.
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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.nginx\.extraReadPaths



nginx’s ` /victoria/ ` is reads-only (docs/decisions/0025): only
` /victoria/{metrics,logs,traces,mcp}/... ` is proxied to vmauth,
everything else under it is a 404\. List the FIRST path segment
of any additional READ route you added through
` vmauth.extraReadUrlMap ` (e\.g\. ` "custom-route" ` for
` /victoria/custom-route/... `) to let it through too\. Writes
belong on vmauth’s own doors (` vmauth.https ` / ` vmauth.http `),
not here\.



*Type:*
list of string matching the pattern \[A-Za-z0-9_\.-]+



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "custom-route"
]
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.nginx\.maxRequestBodySize



Largest request body nginx accepts on ` /victoria/ ` (nginx’s
` client_max_body_size `)\. A larger request is refused at once with a 413,
judged from its Content-Length before any body is read\. Reads need tiny
bodies (the backends themselves refuse queries over 16 KiB), so the
default has ample headroom\. nginx also streams bodies straight through
(` proxy_request_buffering off `), so vmauth checks the credential first
and no temporary file is written\.

` "0" ` means unlimited and removes that protection: any client could
make nginx carry an arbitrarily large body before vmauth rejects it\.



*Type:*
string matching the pattern \[0-9]+\[kKmMgG]?



*Default:*

```nix
"8m"
```



*Example:*

```nix
"1m"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.package



The victoria-traces package to use\. Defaults to pkgs\.victoriatraces\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.extraFlags



Extra command-line flags passed straight through to victoria-traces,
for anything not worth promoting to its own typed option\.

Flags that change addressing or auth (` -http.pathPrefix* `, ` -tls* `,
` -httpAuth.* `) are rejected at build time: the module’s readiness
check and self-push use plain http on the known address and path\.
Put nginx in front of the service instead\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.mcp\.package



The mcp-victoriatraces package to use\. Defaults to this flake’s own packages\.mcp-victoriatraces\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionMaxDiskSpaceUsageBytes



` -retention.maxDiskSpaceUsageBytes ` – the maximum disk space
victoria-traces may use at ` dataDir ` before older per-day
partitions are dropped, in addition to ` retentionPeriod `\.
Mutually exclusive with ` retentionMaxDiskUsagePercent `\. ` null `
(the default) omits the flag\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?(\[KMGT]i?B)?



*Default:*

```nix
null
```



*Example:*

```nix
"500GB"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionMaxDiskUsagePercent



` -retention.maxDiskUsagePercent ` – like
` retentionMaxDiskSpaceUsageBytes `, but as a percentage of the
filesystem holding ` dataDir `\. Mutually exclusive with it\.
` null ` (the default) omits the flag\.



*Type:*
null or integer between 1 and 100 (both inclusive)



*Default:*

```nix
null
```



*Example:*

```nix
80
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.retentionPeriod



How long to retain data for\. ` null ` (the default) means
whatever victoria-traces itself does when the flag is omitted
entirely (a 7 day default for this binary, NOT unbounded) – matching
upstream’s own default rather than imposing an opinionated one\.

The minimum is 1 day: a shorter value (` 1h `, ` 23h `, ` 0 `) makes
victoria-traces refuse to start, and evaluation warns about it\. A bare
number means months, so ` 1 ` is one month, not one day\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
null
```



*Example:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.selfMonitoring\.enable

Whether victoria-traces pushes its own ` /metrics ` page into the local
VictoriaMetrics instance\.

 - On by default whenever ` services.victoriaStack.metrics.enable ` is
   true (there is then a database to push into)\.
 - Off by default when the metrics database is not enabled on this
   host, so logs-only or traces-only setups need no change\.
 - Set it to ` false ` to opt a service out\. Setting it to ` true `
   without ` metrics.enable ` is an error: there is nothing to push to\.



*Type:*
boolean



*Default:*

```nix
config.services.victoriaStack.metrics.enable
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.selfMonitoring\.interval



How often victoria-traces pushes its own metrics (` -pushmetrics.interval `)\.
Only used when ` selfMonitoring.enable ` is true\. The series carry a
` job ` label naming the service, so the four services stay apart\.



*Type:*
string matching the pattern (\[0-9]+(ms|s|m|h))+



*Default:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.traces\.snapshots\.maxAge



` -snapshotsMaxAge ` – the binary itself prunes snapshots older
than this (not the ` schedule ` timer, which only creates them)\.
Same format as ` retentionPeriod `: a number with one optional
unit (` s `, ` h `, ` d `, ` w `, ` M `, ` y `; a bare number is months),
or several ` s `/` h `/` d `/` w ` parts such as ` 1d12h `; ` 0 ` disables
pruning\.
` null ` disables automatic pruning (it passes
` -snapshotsMaxAge=0 `; leaving the flag out would keep each
binary’s own 3d default): snapshots then accumulate under ` dataDir ` until deleted
through the service’s own snapshot-delete API (never with
` rm `/` cp `/` rsync ` – snapshots are hard links into live data,
and touching them directly can corrupt them)\.

Only takes effect while ` snapshots.enable ` is true\.

NOTE: a snapshot never leaves this host’s disk\. It protects
against logical data loss (a bad query, an operator mistake),
NOT disk failure – shipping one off-host needs VictoriaMetrics’
separate ` vmbackup ` tool, which this option does not wire up\.



*Type:*
null or string matching the pattern \[0-9]+(\\\.\[0-9]+)?\[shdwMy]?|(\[0-9]+(\\\.\[0-9]+)?\[shdw])+



*Default:*

```nix
"30d"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.package



The victoriametrics package vmauth’s binary is bundled in\. Defaults (via mkDefault) to config\.services\.victoriaStack\.metrics\.package – see docs/decisions/0007-package-override-options\.md\.



*Type:*
package

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.accessLog



Whether vmauth writes a log line for every request from a
credentialed user (the admin user, read tokens and write tokens)\.

 - ` false ` (the default): vmauth logs a sender’s address only when
   a request FAILS (a rejected credential, or a path with no
   route)\. A request that succeeds – including every normal write
   from a collector – leaves no log line at all, so the journal
   cannot tell you where a successful write came from\.
 - ` true `: every request gets a log line, successful ones
   included, and it carries the sender’s real network address
   (the address the connection came from, which the sender cannot
   fake the way it can fake labels in the data)\. Use it to notice a
   valid token being used from a machine you don’t recognise\. The
   cost is one extra journal line per request\.

The unauthenticated ingest door (` requireAuthForWrites = false `)
always logs, independent of this option\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.adminPasswordFile



Path (as a plain string – see ` writeTokensFile `’s description
for why not a Nix path literal) to a file containing the
plaintext password for vmauth’s Basic Auth “admin” user (read +
MCP paths, same access as any ` readTokensFile ` entry, just a
different credential type)\. An empty or whitespace-only file
creates no admin user and logs a warning; vmauth keeps running
with the other credentials\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.caFile



vmauth’s ` -backend.TLSCAFile ` – CA bundle for verifying
backend TLS certificates\. A real Nix path is fine here (unlike
the credential options below): a CA bundle is public by
nature, not a runtime-staged secret\. It is still staged through
systemd ` LoadCredential= ` like every other TLS file, so the file’s
owner and mode don’t matter to vmauth’s dynamic user\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.certFile



vmauth’s ` -backend.TLSCertFile ` – client certificate for
mTLS to HTTPS backends\. Plain string; see ` writeTokensFile `\.
Staged via ` LoadCredential= ` at runtime\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.backendTls\.keyFile



vmauth’s ` -backend.TLSKeyFile ` – the client private key
paired with ` certFile `, for mTLS to HTTPS backends\. Plain string;
see ` writeTokensFile ` (a private key must not reach the Nix
store)\. Staged via ` LoadCredential= ` at runtime\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraFlags



Extra command-line flags passed straight through to vmauth,
appended last, for anything not worth promoting to its own
typed option\. Same shape as the storage services’ ` extraFlags `\.

Flags that change addressing or auth are rejected at build time:
` -http.pathPrefix* `, ` -tls* `, ` -httpAuth.* `, and
` -httpListenAddr* ` / ` -httpInternalListenAddr* ` (the module owns the
listeners; its ` -tls* ` arrays are positional with them)\. The module’s
readiness check and self-push use plain http on the known address and
path\. For TLS use ` https `, for listeners ` listenAddress `,
` internalListenAddress `, ` https ` and ` http `, and put nginx in front
for a path prefix or extra auth\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-maxConcurrentRequests=100"
]
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraReadUrlMap



Extra vmauth url_map entries for the read/admin tier, appended after
the auto-derived ones\. Not validated against the read allow-list of
ADR 0021 (a pattern that matches every path only draws a warning)\.

Like every route this module builds, an entry drops the caller’s
` Authorization ` header before forwarding (vmauth would otherwise pass
every token and admin password to the backend); set your own
` headers ` on the entry if that route needs one\.

A token scoped with ` backends ` receives only those ` src_paths ` of
these entries that start, at a path boundary, with its backends’
prefixes (` /metrics `, ` /logs `, ` /traces `, ` /mcp/<backend> `)\. Entries
without ` src_paths `, or paths containing ` | `, are dropped for scoped
tokens\.



*Type:*
list of (attribute set)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.extraWriteUrlMap



Like every route this module builds, these drop the caller’s
` Authorization ` header before forwarding\. A token scoped with
` backends ` receives only those ` src_paths ` that start, at a path
boundary, with its backends’ ingest prefixes (` /opentelemetry `,
` /insert/journald `, ` /insert/opentelemetry/v1/traces `); entries
without ` src_paths `, or paths containing ` | `, are dropped for scoped
tokens\.

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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.http\.enable



Whether to enable a second, plain-HTTP public listener on vmauth (e\.g\. ` 0.0.0.0 ` open for writes, or ` 127.0.0.1 ` as a target for ` tailscale serve `)\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.http\.ipAddress



Address the plain-HTTP listener binds\. ` 127.0.0.1 ` keeps it local (a place for ` tailscale serve ` to forward into)\. An IPv6 address is bracketed automatically\.



*Type:*
string



*Default:*

```nix
"0.0.0.0"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.http\.port



Port of the plain-HTTP listener\.



*Type:*
integer between 1 and 65535 (both inclusive)



*Default:*

```nix
8080
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.enable



Whether to enable a public HTTPS listener on vmauth, meant for collectors’ writes (` writeEndpoint = "https://host:<port>" `)\.



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.acmeCertName



Reuse a certificate NixOS already manages: the name of an entry in
` security.acme.certs ` (typically the one nginx’s ` enableACME `
uses)\. The operator defines the entry; this module reads
` fullchain.pem `/` key.pem ` from its directory and orders vmauth
after it\. Add ` "vmauth.service" ` to that cert’s ` reloadServices `
so renewals restart vmauth (a warning says so if it is missing)\.
Mutually exclusive with ` certFile `/` keyFile `\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"victoria-stack.example.com"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.certFile



Path (plain string; see ` writeTokensFile `) to the PEM certificate
chain\. Staged through systemd ` LoadCredential= `, so it never enters
the Nix store\. Set together with ` keyFile `, or use ` acmeCertName `
instead\. vmauth reads a copy (` LoadCredential= `) at start (ACME
renewals use ` reloadServices `, see ` acmeCertName `)\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.ipAddress



Address the HTTPS listener binds\. An IPv6 address (contains ` : `) is bracketed automatically\.



*Type:*
string



*Default:*

```nix
"0.0.0.0"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.keyFile



Path (plain string; see ` writeTokensFile `) to the PEM private key matching ` certFile `\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.https\.port



Port of the HTTPS listener\.



*Type:*
integer between 1 and 65535 (both inclusive)



*Default:*

```nix
8443
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.idleConnTimeout



vmauth’s ` -http.idleConnTimeout `\. vmauth’s own default of ` 1m ` sits
right on top of a typical collector’s OTLP export interval
(confirmed in production: ~52-60s), producing intermittent
“connection reset by peer” retries as vmauth force-closes
connections collectors are about to reuse\. This module’s default of
5m gives real headroom\.



*Type:*
string matching the pattern \[0-9]+(ms|s|m|h)



*Default:*

```nix
"5m"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.internalListenAddress



Address of the loopback-only listener that serves vmauth’s OWN pages:
` /health `, ` /metrics `, ` /flags `, ` /debug/pprof/ ` and ` /-/reload `
(` -httpInternalListenAddr `)\. No data listener – the internal one or
the public ` https `/` http ` doors – serves them, so a public door never
exposes vmauth’s statistics, flags or profiler\. Keep it on loopback
(an address that is not loopback exposes them again)\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4208"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.listenAddress



The internal data listener: nginx and local callers reach vmauth
here\. Public write doors are separate listeners (` https `, ` http `)\.
Never serves vmauth’s own diagnostic pages (see ` internalListenAddress `)\.



*Type:*
string



*Default:*

```nix
"127.0.0.1:4204"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.maxConcurrentPerUserRequests



vmauth’s ` -maxConcurrentPerUserRequests ` – the limit on
concurrent requests per configured user\. ` null ` (the default)
omits the flag entirely, matching vmauth’s own upstream
default\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.maxConcurrentRequests



vmauth’s ` -maxConcurrentRequests ` – the global limit on
concurrent requests across all configured users\. ` null ` (the
default) omits the flag entirely, matching vmauth’s own
upstream default\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.readTokensFile



Path (as a plain string – see ` writeTokensFile `’s description
for why not a Nix path literal) to a YAML file (typically
sops-nix rendered) containing a ` tokens: ` list of objects, each a
bearer token authorized for read + MCP paths – same shape as
` writeTokensFile ` (inline ` # ` comments; optional ` backends `
list scoping a token to those backends’ raw API *and* that
signal’s MCP route, e\.g\. ` backends: ["traces"] ` reaches
` /traces/* ` and ` /mcp/traces ` only)\. Deliberately a SEPARATE file
from ` writeTokensFile ` – see
docs/decisions/0003-vmauth-two-credential-tiers\.md for why\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.selfMonitoring\.enable



Whether vmauth pushes its own ` /metrics ` page into the local
VictoriaMetrics instance\.

 - On by default whenever ` services.victoriaStack.metrics.enable ` is
   true (there is then a database to push into)\.
 - Off by default when the metrics database is not enabled on this
   host, so logs-only or traces-only setups need no change\.
 - Set it to ` false ` to opt a service out\. Setting it to ` true `
   without ` metrics.enable ` is an error: there is nothing to push to\.



*Type:*
boolean



*Default:*

```nix
config.services.victoriaStack.metrics.enable
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



## services\.victoriaStack\.vmauth\.selfMonitoring\.interval



How often vmauth pushes its own metrics (` -pushmetrics.interval `)\.
Only used when ` selfMonitoring.enable ` is true\. The series carry a
` job ` label naming the service, so the four services stay apart\.



*Type:*
string matching the pattern (\[0-9]+(ms|s|m|h))+



*Default:*

```nix
"30s"
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)



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
doors; without the key the token reaches every enabled backend\.
` backends: [] `, only unknown names, or only backends that are not
enabled give NO access: vmauth logs a warning naming the entry
number, leaves that token out of its configuration (callers get
the same 401 as for an unknown token) and keeps running; an unknown
name next to valid ones is ignored\. An entry with an empty ` token `
is skipped with a warning too\. See
docs/decisions/0030-vmauth-token-entries-warn-dont-break\.md\.

```yaml
tokens:
  - token: "collector-host-a-secret"   # unscoped
  - token: "tracing-only-host-secret"
    backends: ["traces"]               # scoped
```

**Breaking change:** entries used to be bare strings
(` - some-token `)\. That format is now rejected at vmauth start
with a message saying so; migrate each line to ` - token: some-token `\.
See docs/decisions/0003-vmauth-two-credential-tiers\.md\. Required
when ` requireAuthForWrites = true ` and at least one storage
service is enabled – left unset in that combination, every
write/ingest path through vmauth rejects every request with no
credential able to open it (vmauth itself starts and reports
healthy regardless, so this fails silently until writes are
actually attempted)\.

Writing this file, or renaming a new file over it, restarts vmauth automatically,
since vmauth reads its secret files only at start; the same holds for
` writeTokensFile `, ` readTokensFile `, ` adminPasswordFile `, ` https.certFile `, ` https.keyFile `, ` backendTls.certFile `,
` backendTls.keyFile ` and ` backendTls.caFile ` (unless it is a Nix store
path)\. A secrets manager that instead swaps a symlinked directory
(sops-nix) does not trigger that watch, so it must restart vmauth itself:
with sops-nix, list ` vmauth.service ` in the secret’s ` restartUnits `\. A file
that is invalid after the replacement makes vmauth fail at start with the
validation message (it fails closed)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [/nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options\.nix](file:///nix/store/dzavd0hza09vkg78di8xsf9nyi97vkkp-source/nixosModule/victoriaStack/options.nix)


