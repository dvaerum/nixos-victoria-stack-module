{ lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    ;

  # The binaries' own duration grammar: a number with one optional unit (s, h,
  # d, w, M, y; a bare number is months), or several s/h/d/w parts. A
  # lower-case `m` (minutes) is refused by them, "30days" dies at start.
  # Shared by -retentionPeriod and -snapshotsMaxAge, which parse alike.
  durationRegex = "[0-9]+(\\.[0-9]+)?[shdwMy]?|([0-9]+(\\.[0-9]+)?[shdw])+";

  # The one place the restart-on-replacement rule and its watched-file list are
  # written; interpolated into every option that names a watched secret file
  # (the list mirrors `watchedSecrets` in vmauth.nix).
  secretReplacementNote = ''
    Writing this file, or renaming a new file over it, restarts vmauth automatically,
    since vmauth reads its secret files only at start; the same holds for
    `writeTokensFile`, `readTokensFile`, `adminPasswordFile`, `https.certFile`, `https.keyFile`, `backendTls.certFile`,
    `backendTls.keyFile` and `backendTls.caFile` (unless it is a Nix store
    path). A secrets manager that instead swaps a symlinked directory
    (sops-nix) does not trigger that watch, so it must restart vmauth itself:
    with sops-nix, list `vmauth.service` in the secret's `restartUnits`. A file
    that is invalid after the replacement makes vmauth fail at start with the
    validation message (it fails closed).
  '';

  # Not lib.mkPackageOption: it resolves its default from `pkgs.<name>`, which
  # is wrong for the MCP packages (this flake's own packages/*, not nixpkgs).
  # Every package option is instead a plain `types.package` with no literal
  # default; the default is set with `lib.mkDefault` where `pkgs` is in scope
  # (storage-common.nix, mcp.nix, vmauth.nix).
  mkPackageOption' =
    description:
    mkOption {
      type = types.package;
      inherit description;
    };

  # Same two options on all 4 services whose binary has the -pushmetrics.*
  # flags (metrics, logs, traces, vmauth) -- see self-monitoring.nix.
  mkSelfMonitoringOptions = binaryName: {
    enable = mkOption {
      type = types.bool;
      # The real default is set with mkDefault in assertions.nix (like
      # vmauth.enable): on whenever the metrics database is enabled.
      default = false;
      defaultText = lib.literalExpression "config.services.victoriaStack.metrics.enable";
      description = ''
        Whether ${binaryName} pushes its own `/metrics` page into the local
        VictoriaMetrics instance.

        - On by default whenever `services.victoriaStack.metrics.enable` is
          true (there is then a database to push into).
        - Off by default when the metrics database is not enabled on this
          host, so logs-only or traces-only setups need no change.
        - Set it to `false` to opt a service out. Setting it to `true`
          without `metrics.enable` is an error: there is nothing to push to.
      '';
    };

    interval = mkOption {
      type = types.strMatching "([0-9]+(ms|s|m|h))+";
      default = "30s";
      description = ''
        How often ${binaryName} pushes its own metrics (`-pushmetrics.interval`).
        Only used when `selfMonitoring.enable` is true. The series carry a
        `job` label naming the service, so the four services stay apart.
      '';
    };
  };

  # Shared option shape for metrics/logs/traces -- each storage service is an
  # independent systemd unit built directly on the relevant victoria-family
  # binary (see docs/decisions/0001), not a wrapper around nixpkgs' own
  # services.victoriametrics/victorialogs/victoriatraces modules.
  mkStorageServiceOptions =
    {
      name, # "victoriametrics" | "victorialogs" | "victoriatraces"
      defaultListenAddress,
      defaultMcpPort,
      binaryName,
      # Each binary's own default when retentionPeriod is omitted, confirmed
      # per binary via its `-help` (metrics 1 month, logs and traces 7 days;
      # none is unbounded).
      retentionPeriodNullBehavior,
      # -retention.maxDisk* exists on victoria-logs/victoria-traces only
      # (confirmed via each binary's own `-help`); an option for a flag
      # the binary rejects would render a crash-looping unit, so it is
      # not declared on metrics.
      supportsDiskRetention ? false, # victoria-logs / victoria-traces only
    }:
    {
      enable = mkEnableOption name;

      package = mkPackageOption' "The ${binaryName} package to use. Defaults to pkgs.${name}.";

      dataDir = mkOption {
        type = types.path;
        default = /var/lib/${name};
        defaultText = lib.literalExpression "/var/lib/${name}";
        description = ''
          Directory the ${binaryName} binary stores its data in
          (`-storageDataPath`). Changing this away from the default
          `/var/lib/${name}` -- e.g. to point at an externally-mounted
          dataset -- requires `dynamicUser = false` (static user); see
          `suppressDynamicUserWarning` and
          docs/decisions/0009-dynamicuser-warning-not-assertion.md for why
          this is a warning, not a hard assertion.
        '';
      };

      dynamicUser = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to run ${binaryName} under a systemd `DynamicUser`
          (nixpkgs' own default behavior for these binaries) or a static,
          stable system user. `DynamicUser`'s `StateDirectory` handling
          tries to migrate a pre-existing `dataDir` into a private
          DynamicUser-managed copy on every start, which fails outright
          ("Device or resource busy") once `dataDir` is itself an
          externally-managed mount (e.g. a ZFS dataset) -- confirmed on two
          independent real deployments. Set this to `false` whenever
          `dataDir` is not the default `/var/lib/${name}` path.
        '';
      };

      suppressDynamicUserWarning = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Silence the build-time warning emitted when `dataDir` has been
          customized away from `/var/lib/...` while `dynamicUser` is still
          `true`. Use once you've deliberately confirmed this combination
          is what you want (it almost never is -- see `dynamicUser`'s own
          description).
        '';
      };

      manageTmpfiles = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this module re-asserts `dataDir`'s ownership/mode (via
          `systemd.tmpfiles.rules`) on every boot, when `dynamicUser =
          false` (the static-user branch). The default is self-healing:
          it catches drift or manual mistakes automatically, which is
          central to why the static-user path works at all for an
          externally-managed mount (docs/decisions/0001). Set to `false`
          to manage the directory's ownership/mode entirely yourself
          outside this module -- a plain escape hatch for a real reason
          this module can't anticipate, not a config mismatch, so there is
          deliberately no warning attached to disabling it.
        '';
      };

      listenAddress = mkOption {
        type = types.str;
        default = defaultListenAddress;
        description = ''
          Address ${binaryName} listens on. Defaults to loopback-only --
          `services.victoriaStack.vmauth` is the sanctioned way to reach it
          from outside this host. Override to `0.0.0.0:<port>` to bypass
          vmauth entirely and expose it directly, if that's deliberately
          what you want.
        '';
      };

      effectiveUrl = mkOption {
        type = types.str;
        internal = true;
        description = ''
          Internal: the base URL consumers (vmauth, Grafana, the MCP servers,
          the self-monitoring push) actually connect to for this backend.
          `http://` plus `listenAddress` today, with a wildcard address
          (`:port`, `0.0.0.0:port`, `[::]:port`) mapped to loopback because it
          is not something to connect to (set via mkDefault in
          storage-common.nix), funneled through one
          option specifically so that external/remote-backend support
          (docs/decisions/0019 -- explicitly out of scope for now) only
          ever needs to override ONE definition per service later,
          instead of every consumer call site across the module tree.
        '';
      };

      retentionPeriod = mkOption {
        type = types.nullOr (types.strMatching durationRegex);
        default = null;
        example = "30d";
        description = ''
          How long to retain data for. `null` (the default) means
          whatever ${binaryName} itself does when the flag is omitted
          entirely (${retentionPeriodNullBehavior}) -- matching
          upstream's own default rather than imposing an opinionated one.
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "-search.maxUniqueTimeseries=300000" ];
        description = ''
          Extra command-line flags passed straight through to ${binaryName},
          for anything not worth promoting to its own typed option.

          Flags that change addressing or auth (`-http.pathPrefix*`, `-tls*`,
          `-httpAuth.*`) are rejected at build time: the module's readiness
          check and self-push use plain http on the known address and path.
          Put nginx in front of the service instead.
        '';
      };

    }
    // lib.optionalAttrs supportsDiskRetention {
      retentionMaxDiskSpaceUsageBytes = mkOption {
        # A number with an optional KB/MB/GB/TB/KiB/MiB/GiB/TiB suffix, the
        # binaries' own size grammar (a bare `G` or `B` is refused by them).
        type = types.nullOr (types.strMatching "[0-9]+(\\.[0-9]+)?([KMGT]i?B)?");
        default = null;
        example = "500GB";
        description = ''
          `-retention.maxDiskSpaceUsageBytes` -- the maximum disk space
          ${binaryName} may use at `dataDir` before older per-day
          partitions are dropped, in addition to `retentionPeriod`.
          Mutually exclusive with `retentionMaxDiskUsagePercent`. `null`
          (the default) omits the flag.
        '';
      };

      retentionMaxDiskUsagePercent = mkOption {
        type = types.nullOr (types.ints.between 1 100);
        default = null;
        example = 80;
        description = ''
          `-retention.maxDiskUsagePercent` -- like
          `retentionMaxDiskSpaceUsageBytes`, but as a percentage of the
          filesystem holding `dataDir`. Mutually exclusive with it.
          `null` (the default) omits the flag.
        '';
      };
    }
    // {
      selfMonitoring = mkSelfMonitoringOptions binaryName;

      snapshots = {
        enable = mkEnableOption "periodic on-disk snapshot creation (a systemd timer calling ${binaryName}'s own snapshot API)";

        schedule = mkOption {
          type = types.str;
          default = "daily";
          description = ''
            systemd `OnCalendar` expression for how often to create a
            snapshot. `daily` is systemd's own shorthand for midnight.
          '';
        };

        maxAge = mkOption {
          type = types.nullOr (types.strMatching durationRegex);
          default = "30d";
          description = ''
            `-snapshotsMaxAge` -- the binary itself prunes snapshots older
            than this (not the `schedule` timer, which only creates them).
            Same format as `retentionPeriod`: a number with one optional
            unit (`s`, `h`, `d`, `w`, `M`, `y`; a bare number is months),
            or several `s`/`h`/`d`/`w` parts such as `1d12h`; `0` disables
            pruning.
            `null` disables automatic pruning (it passes
            `-snapshotsMaxAge=0`; leaving the flag out would keep each
            binary's own 3d default): snapshots then accumulate under `dataDir` until deleted
            through the service's own snapshot-delete API (never with
            `rm`/`cp`/`rsync` -- snapshots are hard links into live data,
            and touching them directly can corrupt them).

            Only takes effect while `snapshots.enable` is true.

            NOTE: a snapshot never leaves this host's disk. It protects
            against logical data loss (a bad query, an operator mistake),
            NOT disk failure -- shipping one off-host needs VictoriaMetrics'
            separate `vmbackup` tool, which this option does not wire up.
          '';
        };
      };

      mcp = {
        enable = mkEnableOption "an MCP (Model Context Protocol) server fronting this ${name} instance";

        package = mkPackageOption' "The mcp-${name} package to use. Defaults to this flake's own packages.mcp-${name}.";

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1:${toString defaultMcpPort}";
          description = ''
            Address the MCP server listens on. Defaults to loopback-only
            (reach it via `services.victoriaStack.vmauth`'s own `/mcp/*`
            routing); override to expose it directly if `vmauth` is
            disabled and that's what you want. Requires this service's own
            `enable = true` -- there is nothing for the MCP server to proxy
            to otherwise (see docs/decisions/0002-opt-in-everything.md).

            When reached through vmauth (e.g. `/mcp/metrics`,
            `/mcp/logs`, `/mcp/traces`): request it with NO trailing
            slash -- vmauth strips exactly 2 path parts before
            forwarding, which only lands on the MCP binary's own fixed
            `/mcp` path (not `/mcp/`) when the original request has none
            either.
          '';
        };

        logLevel = mkOption {
          type = types.nullOr (
            types.enum [
              "debug"
              "info"
              "warn"
              "error"
            ]
          );
          default = null;
          description = ''
            `MCP_LOG_LEVEL` -- confirmed identical across all three
            mcp-victoria* binaries' own READMEs. `null` (the default)
            omits the env var entirely, matching each binary's own
            upstream default (`info`).
          '';
        };

        logFormat = mkOption {
          type = types.nullOr (
            types.enum [
              "text"
              "json"
            ]
          );
          default = null;
          description = ''
            `MCP_LOG_FORMAT` -- confirmed identical across all three
            mcp-victoria* binaries' own READMEs. `null` (the default)
            omits the env var entirely, matching each binary's own
            upstream default (`text`).
          '';
        };

        disabledTools = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "documentation" ];
          description = ''
            `MCP_DISABLED_TOOLS` -- confirmed identical across all three
            mcp-victoria* binaries' own READMEs (a comma-separated list
            on the wire; this option takes a real Nix list and joins it).
            `[ ]` (the default) adds nothing beyond whatever the binary
            you're configuring already disables on its own. Each binary's
            own README documents its available tool names -- e.g.
            `documentation` disables an embedded vector-database tool
            that's otherwise the dominant source of that MCP server's
            resource usage.

            metrics' own binary (unlike logs/traces) hardcodes 6 tools
            disabled by default when this is left entirely unset --
            including `test_rules`, which WRITES synthetic series into
            the live instance -- confirmed directly from its source.
            Setting this option for metrics is always additive on top
            of that upstream default set (mcp.nix unions the two), never
            a replacement for it -- so the `example` above genuinely
            disables only `documentation`, it does not silently
            re-enable `test_rules`/`export`/`flags`/etc.
          '';
        };
      };
    };
in
{
  options.services.victoriaStack = {
    metrics = mkStorageServiceOptions {
      name = "victoriametrics";
      binaryName = "victoria-metrics";
      # docs/decisions/0017: sequential 4201-4207 scheme, an explicit
      # operator decision, not any binary's own upstream default.
      defaultListenAddress = "127.0.0.1:4201";
      defaultMcpPort = 4205;
      retentionPeriodNullBehavior = "a 1 month default for this binary, NOT unbounded";
    };

    logs = mkStorageServiceOptions {
      name = "victorialogs";
      binaryName = "victoria-logs";
      defaultListenAddress = "127.0.0.1:4202";
      defaultMcpPort = 4206;
      retentionPeriodNullBehavior = "a 7 day default for this binary, NOT unbounded";
      supportsDiskRetention = true;
    };

    traces = mkStorageServiceOptions {
      name = "victoriatraces";
      binaryName = "victoria-traces";
      defaultListenAddress = "127.0.0.1:4203";
      defaultMcpPort = 4207;
      retentionPeriodNullBehavior = "a 7 day default for this binary, NOT unbounded";
      supportsDiskRetention = true;
    };

    vmauth = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run vmauth, the auth/routing gateway in front of
          whichever of metrics/logs/traces are enabled. Auto-defaults to
          `true` (via `mkDefault`, so it stays overridable) whenever any of
          those is enabled -- see
          docs/decisions/0002-opt-in-everything.md. A `true` value here has
          no effect at all if none of metrics/logs/traces is enabled (there
          is nothing to front).
        '';
      };

      package = mkPackageOption' "The victoriametrics package vmauth's binary is bundled in. Defaults (via mkDefault) to config.services.victoriaStack.metrics.package -- see docs/decisions/0007-package-override-options.md.";

      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1:4204"; # docs/decisions/0017
        description = ''
          The internal data listener: nginx and local callers reach vmauth
          here. Public write doors are separate listeners (`https`, `http`).
          Never serves vmauth's own diagnostic pages (see `internalListenAddress`).
        '';
      };

      internalListenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1:4208"; # next free number after 4201-4207, docs/decisions/0017
        description = ''
          Address of the loopback-only listener that serves vmauth's OWN pages:
          `/health`, `/metrics`, `/flags`, `/debug/pprof/` and `/-/reload`
          (`-httpInternalListenAddr`). No data listener -- the internal one or
          the public `https`/`http` doors -- serves them, so a public door never
          exposes vmauth's statistics, flags or profiler. Keep it on loopback
          (an address that is not loopback exposes them again).
        '';
      };

      idleConnTimeout = mkOption {
        # Mirrored into nginx's proxy_*_timeout (ADR 0016): only forms both
        # accept (a Go-style fraction like 1.5m is invalid nginx syntax).
        type = types.strMatching "[0-9]+(ms|s|m|h)";
        default = "5m";
        description = ''
          vmauth's `-http.idleConnTimeout`. vmauth's own default of `1m` sits
          right on top of a typical collector's OTLP export interval
          (confirmed in production: ~52-60s), producing intermittent
          "connection reset by peer" retries as vmauth force-closes
          connections collectors are about to reuse. This module's default of
          5m gives real headroom.
        '';
      };

      selfMonitoring = mkSelfMonitoringOptions "vmauth";

      accessLog = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether vmauth writes a log line for every request from a
          credentialed user (the admin user, read tokens and write tokens).

          - `false` (the default): vmauth logs a sender's address only when
            a request FAILS (a rejected credential, or a path with no
            route). A request that succeeds -- including every normal write
            from a collector -- leaves no log line at all, so the journal
            cannot tell you where a successful write came from.
          - `true`: every request gets a log line, successful ones
            included, and it carries the sender's real network address
            (the address the connection came from, which the sender cannot
            fake the way it can fake labels in the data). Use it to notice a
            valid token being used from a machine you don't recognise. The
            cost is one extra journal line per request.

          The unauthenticated ingest door (`requireAuthForWrites = false`)
          always logs, independent of this option.
        '';
      };

      maxConcurrentRequests = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          vmauth's `-maxConcurrentRequests` -- the global limit on
          concurrent requests across all configured users. `null` (the
          default) omits the flag entirely, matching vmauth's own
          upstream default.
        '';
      };

      maxConcurrentPerUserRequests = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          vmauth's `-maxConcurrentPerUserRequests` -- the limit on
          concurrent requests per configured user. `null` (the default)
          omits the flag entirely, matching vmauth's own upstream
          default.
        '';
      };

      # Public write doors (docs/decisions/0025). `listenAddress` above stays
      # the internal plain listener nginx and local callers use; these are
      # additional listeners on the same vmauth process. They share vmauth's
      # one routing/auth config, so they ALSO accept reads (still behind
      # credentials) -- restrict reachability with a firewall or Tailscale if
      # that matters.
      https = {
        enable = mkEnableOption "a public HTTPS listener on vmauth, meant for collectors' writes (`writeEndpoint = \"https://host:<port>\"`)";

        ipAddress = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Address the HTTPS listener binds. An IPv6 address (contains `:`) is bracketed automatically.";
        };

        port = mkOption {
          type = types.ints.between 1 65535;
          default = 8443;
          description = "Port of the HTTPS listener.";
        };

        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path (plain string; see `writeTokensFile`) to the PEM certificate
            chain. Staged through systemd `LoadCredential=`, so it never enters
            the Nix store. Set together with `keyFile`, or use `acmeCertName`
            instead. vmauth reads a copy (`LoadCredential=`) at start (ACME
            renewals use `reloadServices`, see `acmeCertName`).

            ${secretReplacementNote}
          '';
        };

        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path (plain string; see `writeTokensFile`) to the PEM private key matching `certFile`.

            ${secretReplacementNote}
          '';
        };

        acmeCertName = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "victoria-stack.example.com";
          description = ''
            Reuse a certificate NixOS already manages: the name of an entry in
            `security.acme.certs` (typically the one nginx's `enableACME`
            uses). The operator defines the entry; this module reads
            `fullchain.pem`/`key.pem` from its directory and orders vmauth
            after it. Add `"vmauth.service"` to that cert's `reloadServices`
            so renewals restart vmauth (a warning says so if it is missing).
            Mutually exclusive with `certFile`/`keyFile`.
          '';
        };
      };

      http = {
        enable = mkEnableOption "a second, plain-HTTP public listener on vmauth (e.g. `0.0.0.0` open for writes, or `127.0.0.1` as a target for `tailscale serve`)";

        ipAddress = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Address the plain-HTTP listener binds. `127.0.0.1` keeps it local (a place for `tailscale serve` to forward into). An IPv6 address is bracketed automatically.";
        };

        port = mkOption {
          type = types.ints.between 1 65535;
          default = 8080;
          description = "Port of the plain-HTTP listener.";
        };
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "-maxConcurrentRequests=100" ];
        description = ''
          Extra command-line flags passed straight through to vmauth,
          appended last, for anything not worth promoting to its own
          typed option. Same shape as the storage services' `extraFlags`.

          Flags that change addressing or auth are rejected at build time:
          `-http.pathPrefix*`, `-tls*`, `-httpAuth.*`, and
          `-httpListenAddr*` / `-httpInternalListenAddr*` (the module owns the
          listeners; its `-tls*` arrays are positional with them). The module's
          readiness check and self-push use plain http on the known address and
          path. For TLS use `https`, for listeners `listenAddress`,
          `internalListenAddress`, `https` and `http`, and put nginx in front
          for a path prefix or extra auth.
        '';
      };

      backendTls = {
        insecureSkipVerify = mkOption {
          type = types.bool;
          default = false;
          description = ''
            vmauth's `-backend.tlsInsecureSkipVerify` -- skip TLS
            verification when connecting to HTTPS backends. `false` (the
            default) omits the flag entirely, matching vmauth's own
            upstream default.
          '';
        };

        caFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            vmauth's `-backend.TLSCAFile` -- CA bundle for verifying
            backend TLS certificates. A real Nix path is fine here (unlike
            the credential options below): a CA bundle is public by
            nature, not a runtime-staged secret. It is still staged through
            systemd `LoadCredential=` like every other TLS file, so the file's
            owner and mode don't matter to vmauth's dynamic user.

            ${secretReplacementNote}
          '';
        };

        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            vmauth's `-backend.TLSCertFile` -- client certificate for
            mTLS to HTTPS backends. Plain string; see `writeTokensFile`.
            Staged via `LoadCredential=` at runtime.

            ${secretReplacementNote}
          '';
        };

        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            vmauth's `-backend.TLSKeyFile` -- the client private key
            paired with `certFile`, for mTLS to HTTPS backends. Plain string;
            see `writeTokensFile` (a private key must not reach the Nix
            store). Staged via `LoadCredential=` at runtime.

            ${secretReplacementNote}
          '';
        };
      };

      extraRequestHeaders = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "TenantID: foobar" ];
        description = ''
          vmauth's `headers` option -- extra HTTP request headers set (or,
          with an empty value, removed) before proxying to any enabled
          backend. Applied uniformly across every url_map entry this
          module builds (read, write, and MCP routes alike).
        '';
      };

      extraResponseHeaders = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "Server:" ];
        description = ''
          vmauth's `response_headers` option -- extra HTTP response
          headers set (or, with an empty value, removed) before returning
          the backend's response to the client. Applied uniformly across
          every url_map entry this module builds.
        '';
      };

      requireAuthForWrites = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the native ingest/write paths for enabled backends
          require a write-tier credential (`writeTokensFile`). Default
          `true`. Set to `false` to open those paths to any caller that can
          reach vmauth at all, relying on a network boundary (e.g. a
          tailnet) as the only gate instead -- a single toggle, not a
          per-path list to maintain.
        '';
      };

      writeTokensFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path (as a plain string, NOT a Nix path literal -- interpolating
          a real Nix path forces a Nix-store copy at eval time, which
          either crashes if the file doesn't exist yet on the build
          machine (the normal case: it lands at runtime via
          LoadCredential=, see docs/decisions/0008/0020) or leaks the
          plaintext secret into the world-readable store if it does) to a
          YAML file (typically sops-nix rendered) containing a `tokens:`
          list of objects, each a bearer token authorized for the
          write/ingest paths only. Each entry may carry an inline `#`
          comment (stripped automatically) naming which host/purpose it's
          for, and an optional `backends` list (any of `metrics`, `logs`,
          `traces`) scoping that one token to only those backends' ingest
          doors; without the key the token reaches every enabled backend.
          `backends: []`, only unknown names, or only backends that are not
          enabled give NO access: vmauth logs a warning naming the entry
          number, leaves that token out of its configuration (callers get
          the same 401 as for an unknown token) and keeps running; an unknown
          name next to valid ones is ignored. An entry with an empty `token`
          is skipped with a warning too. See
          docs/decisions/0030-vmauth-token-entries-warn-dont-break.md.

          ```yaml
          tokens:
            - token: "collector-host-a-secret"   # unscoped
            - token: "tracing-only-host-secret"
              backends: ["traces"]               # scoped
          ```

          **Breaking change:** entries used to be bare strings
          (`- some-token`). That format is now rejected at vmauth start
          with a message saying so; migrate each line to `- token: some-token`.
          See docs/decisions/0003-vmauth-two-credential-tiers.md. Required
          when `requireAuthForWrites = true` and at least one storage
          service is enabled -- left unset in that combination, every
          write/ingest path through vmauth rejects every request with no
          credential able to open it (vmauth itself starts and reports
          healthy regardless, so this fails silently until writes are
          actually attempted).

          ${secretReplacementNote}
        '';
      };

      readTokensFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path (as a plain string -- see `writeTokensFile`'s description
          for why not a Nix path literal) to a YAML file (typically
          sops-nix rendered) containing a `tokens:` list of objects, each a
          bearer token authorized for read + MCP paths -- same shape as
          `writeTokensFile` (inline `#` comments; optional `backends`
          list scoping a token to those backends' raw API *and* that
          signal's MCP route, e.g. `backends: ["traces"]` reaches
          `/traces/*` and `/mcp/traces` only). Deliberately a SEPARATE file
          from `writeTokensFile` -- see
          docs/decisions/0003-vmauth-two-credential-tiers.md for why.

          ${secretReplacementNote}
        '';
      };

      adminPasswordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path (as a plain string -- see `writeTokensFile`'s description
          for why not a Nix path literal) to a file containing the
          plaintext password for vmauth's Basic Auth "admin" user (read +
          MCP paths, same access as any `readTokensFile` entry, just a
          different credential type). An empty or whitespace-only file
          creates no admin user and logs a warning; vmauth keeps running
          with the other credentials.

          ${secretReplacementNote}
        '';
      };

      openIngestPaths = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          vmauth `url_map` entries for the unauthenticated-write case only
          (`requireAuthForWrites = false`). Auto-derived from whichever of
          metrics/logs/traces is enabled; override to `[ ]` to close the
          anonymous write door entirely, even with `requireAuthForWrites
          = false`. Has NO effect on write-tier bearer tokens
          (`writeTokensFile`) either way -- those always route via the
          same auto-derivation, independent of this option, since a
          credentialed tier must stay reachable regardless of how the
          anonymous door is sized (docs/decisions/0003, 0014).
        '';
      };

      extraReadUrlMap = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          Extra vmauth url_map entries for the read/admin tier, appended after
          the auto-derived ones. Not validated against the read allow-list of
          ADR 0021 (a pattern that matches every path only draws a warning).

          Like every route this module builds, an entry drops the caller's
          `Authorization` header before forwarding (vmauth would otherwise pass
          every token and admin password to the backend); set your own
          `headers` on the entry if that route needs one.

          A token scoped with `backends` receives only those `src_paths` of
          these entries that start, at a path boundary, with its backends'
          prefixes (`/metrics`, `/logs`, `/traces`, `/mcp/<backend>`). Entries
          without `src_paths`, or paths containing `|`, are dropped for scoped
          tokens.
        '';
      };

      extraWriteUrlMap = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        example = [
          {
            src_paths = [ "/write" ];
            url_prefix = "http://127.0.0.1:4201/";
          }
        ];
        description = ''
          Like every route this module builds, these drop the caller's
          `Authorization` header before forwarding. A token scoped with
          `backends` receives only those `src_paths` that start, at a path
          boundary, with its backends' ingest prefixes (`/opentelemetry`,
          `/insert/journald`, `/insert/opentelemetry/v1/traces`); entries
          without `src_paths`, or paths containing `|`, are dropped for scoped
          tokens.

          Escape hatch: extra vmauth url_map entries appended to the
          write-tier credential's url_map (the read tier is untouched --
          see `extraReadUrlMap` for that side). Never added to the
          unauthenticated `openIngestPaths` door. Same
          operator's-own-responsibility philosophy as `extraReadUrlMap`:
          entries are NOT validated against the allow-list ADR 0021
          established for the built-in routes (a pattern matching every
          path only draws a warning). Real use: VictoriaMetrics' own
          `/write` (InfluxDB line protocol) or `/api/v1/write` (Prometheus
          remote write), which this module opens no door for by default.
        '';
      };
    };

    grafana = {
      enable = mkEnableOption ''
        Grafana datasource provisioning for whichever of metrics/logs/traces
        is enabled. Configures services.grafana only for the datasources (and
        the `declarativePlugins` the metrics and logs datasources need) and,
        when `nginx.enable` is on, a default `root_url` for the `/grafana/`
        sub-path; users and passwords are left to the consumer. The
        datasources go through vmauth's read tier, never straight to a
        backend, so a Grafana Viewer can read but not write or delete. Needs
        `vmauth.enable` and `readTokenFile` -- see
        docs/decisions/0029-grafana-datasources-through-vmauth-read-tier.md
      '';

      readTokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path (as a plain string -- see `vmauth.writeTokensFile`'s
          description for why not a Nix path literal) to a file holding ONE
          bearer token, the credential Grafana's datasources send to vmauth.
          Required when `grafana.enable` is on.

          The same token must also be listed in `vmauth.readTokensFile`;
          this module does not add it for you, so a mismatch makes every
          datasource query fail with 401 (closed, never open). Keep it
          separate from your other read tokens, so it can be rotated alone.

          The file is delivered to Grafana's unit with systemd
          `LoadCredential=`, so it need not be readable by the `grafana`
          user. Replacing it restarts Grafana automatically, since Grafana
          reads it only at start.
        '';
      };
    };

    nginx = {
      enable = mkEnableOption ''
        a single nginx vhost reverse-proxying to vmauth: `/victoria/` proxies
        the READ routes only (not writes), plus `/grafana/` when Grafana is
        enabled; everything else under `/victoria/` is a 404. Requires
        `vmauth.enable = true` -- see docs/decisions/0002-opt-in-everything.md

        Note: behind nginx, vmauth sees nginx's address instead of the real
        client's (its real-IP setting is Enterprise-only); nginx's own log has
        the real client. See docs/architecture.md, "Client addresses behind a
        reverse proxy".
      '';

      domain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional FQDN for the vhost's `server_name`. `null` (the
          default) serves on plain IP/hostname with no domain-specific
          behavior -- this module deliberately has no ACME/TLS opinion
          either way.
        '';
      };

      maxRequestBodySize = mkOption {
        type = types.strMatching "[0-9]+[kKmMgG]?";
        default = "8m";
        example = "1m";
        description = ''
          Largest request body nginx accepts on `/victoria/` (nginx's
          `client_max_body_size`). A larger request is refused at once with a 413,
          judged from its Content-Length before any body is read. Reads need tiny
          bodies (the backends themselves refuse queries over 16 KiB), so the
          default has ample headroom. nginx also streams bodies straight through
          (`proxy_request_buffering off`), so vmauth checks the credential first
          and no temporary file is written.

          `"0"` means unlimited and removes that protection: any client could
          make nginx carry an arbitrarily large body before vmauth rejects it.
        '';
      };

      extraReadPaths = mkOption {
        type = types.listOf (types.strMatching "[A-Za-z0-9_.-]+");
        default = [ ];
        example = [ "custom-route" ];
        description = ''
          nginx's `/victoria/` is reads-only (docs/decisions/0025): only
          `/victoria/{metrics,logs,traces,mcp}/...` is proxied to vmauth,
          everything else under it is a 404. List the FIRST path segment
          of any additional READ route you added through
          `vmauth.extraReadUrlMap` (e.g. `"custom-route"` for
          `/victoria/custom-route/...`) to let it through too. Writes
          belong on vmauth's own doors (`vmauth.https` / `vmauth.http`),
          not here.
        '';
      };
    };
  };
}
