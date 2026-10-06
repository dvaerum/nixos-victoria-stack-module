{ lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    ;

  # Not lib.mkPackageOption: that helper resolves its default via
  # attrByPath against the real `pkgs.<name>`, correct for
  # metrics/logs/traces/vmauth (all real nixpkgs attributes), but wrong for
  # the three MCP server packages (this flake's own packages/*, not
  # anything in nixpkgs). Both cases instead declare a plain `types.package`
  # option here with no literal default, and get their actual default value
  # via `lib.mkDefault` in config.nix, where `pkgs` (and, for MCP, this
  # flake's own package derivations) are naturally in scope -- one
  # consistent mechanism for both cases rather than two different helpers.
  mkPackageOption' =
    description:
    mkOption {
      type = types.package;
      inherit description;
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
      # The real, binary-specific behavior when retentionPeriod is omitted
      # -- NOT a shared claim across all three, since it genuinely differs
      # (confirmed per-binary via each binary's own `-help` output, not
      # assumed to match, nor assumed to match each other): metrics
      # defaults to 1 month, logs to 7 days, traces to 7 days too (the
      # same 7-day number, but confirmed independently per docs/decisions
      # -- not assumed shared just because it's the same value). None of
      # the three default to unbounded.
      retentionPeriodNullBehavior,
    }:
    {
      enable = mkEnableOption name;

      package = mkPackageOption' "The ${binaryName} package to use. Defaults to pkgs.${name}, set via mkDefault in config.nix.";

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
          Internal: the base URL consumers (vmauth, Grafana) actually
          connect to for this backend. Always `http://''${listenAddress}`
          today (set via mkDefault in ${name}.nix), funneled through one
          option specifically so that external/remote-backend support
          (docs/decisions/0019 -- explicitly out of scope for now) only
          ever needs to override ONE definition per service later,
          instead of every consumer call site across the module tree.
        '';
      };

      retentionPeriod = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "30d";
        description = ''
          How long to retain data for. `null` (the default) means
          whatever ${binaryName} itself does when the flag is omitted
          entirely (${retentionPeriodNullBehavior}) -- matching
          upstream's own default rather than imposing an opinionated one.
        '';
      };

      extraOptions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "-search.maxUniqueTimeseries=300000" ];
        description = ''
          Extra command-line flags passed straight through to ${binaryName},
          for anything not worth promoting to its own typed option.
        '';
      };

      mcp = {
        enable = mkEnableOption "an MCP (Model Context Protocol) server fronting this ${name} instance";

        package = mkPackageOption' "The mcp-${name} package to use. Defaults to this flake's own packages.mcp-${name}, set via mkDefault in config.nix.";

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
            `[ ]` (the default) omits the env var entirely. Each
            binary's own README documents its available tool names --
            e.g. `documentation` disables an embedded vector-database
            tool that's otherwise the dominant source of that MCP
            server's resource usage.
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
    };

    traces = mkStorageServiceOptions {
      name = "victoriatraces";
      binaryName = "victoria-traces";
      defaultListenAddress = "127.0.0.1:4203";
      defaultMcpPort = 4207;
      # Confirmed from victoria-traces' own --help/upstream docs: omitting
      # -retentionPeriod defaults to 7 days, same as logs (confirmed
      # independently, not assumed shared just because it's the same
      # value) -- metrics defaults to 1 month. None of the 3 default to
      # unbounded. See traces.nix's own ExecStart comment and
      # docs/decisions/0020 (which fixed this specifically for traces;
      # Phase 39 fixed the same factually-wrong "unbounded" claim for
      # metrics/logs).
      retentionPeriodNullBehavior = "a 7 day default for this binary, NOT unbounded";
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
        description = "Address vmauth listens on.";
      };

      idleConnTimeout = mkOption {
        type = types.str;
        default = "5m";
        description = ''
          vmauth's `-http.idleConnTimeout`. The default of `1m` sits right
          on top of a typical collector's own OTLP export interval
          (confirmed in production: ~52-60s), producing intermittent
          "connection reset by peer" retries as vmauth force-closes
          connections collectors are about to reuse. 5m gives real headroom.
        '';
      };

      maxConcurrentRequests = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          vmauth's `-maxConcurrentRequests` -- the global limit on
          concurrent requests across all configured users. `null` (the
          default) omits the flag entirely, matching vmauth's own
          upstream default.
        '';
      };

      maxConcurrentPerUserRequests = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          vmauth's `-maxConcurrentPerUserRequests` -- the limit on
          concurrent requests per configured user. `null` (the default)
          omits the flag entirely, matching vmauth's own upstream
          default.
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
            vmauth's `-backend.tlsCAFile` -- CA bundle for verifying
            backend TLS certificates. A real Nix path is fine here (unlike
            the credential options above): a CA bundle is public by
            nature, not a runtime-staged secret.
          '';
        };

        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            vmauth's `-backend.tlsCertFile` -- client certificate for
            mTLS to HTTPS backends. Path as a plain string, staged via
            `LoadCredential=` at runtime, same reasoning as
            `adminPasswordFile` above -- paired with a private key, worth
            treating with the same care even though a certificate alone
            isn't secret.
          '';
        };

        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            vmauth's `-backend.tlsKeyFile` -- the client private key
            paired with `certFile`, for mTLS to HTTPS backends. Path as a
            plain string, NOT a Nix path literal -- this is a real private
            key; the exact same eval-crash/Nix-store-leak risk as
            `adminPasswordFile` applies (docs/decisions/0020), staged via
            `LoadCredential=` at runtime.
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
          list of bearer tokens authorized for the write/ingest paths
          only. Each entry may carry an inline `#` comment (stripped
          automatically) naming which host/purpose it's for. See
          docs/decisions/0003-vmauth-two-credential-tiers.md. Required
          when `requireAuthForWrites = true` and at least one storage
          service is enabled -- left unset in that combination, every
          write/ingest path through vmauth rejects every request with no
          credential able to open it (vmauth itself starts and reports
          healthy regardless, so this fails silently until writes are
          actually attempted).
        '';
      };

      readTokensFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path (as a plain string -- see `writeTokensFile`'s description
          for why not a Nix path literal) to a YAML file (typically
          sops-nix rendered) containing a `tokens:` list of bearer tokens
          authorized for read + MCP paths. Deliberately a SEPARATE file
          from `writeTokensFile` -- see
          docs/decisions/0003-vmauth-two-credential-tiers.md for why.
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
          different credential type).
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
        description = "Extra vmauth url_map entries for the read/admin tier, appended after the auto-derived ones.";
      };
    };

    grafana.enable = mkEnableOption ''
      Grafana datasource provisioning for whichever of metrics/logs/traces
      is enabled. Does NOT configure services.grafana itself (left entirely
      to the consumer) and never routes through vmauth -- see
      docs/decisions/0010-grafana-direct-loopback-own-auth.md
    '';

    nginx = {
      enable = mkEnableOption ''
        a single nginx vhost reverse-proxying to vmauth, covering every
        currently-enabled service plus Grafana (if enabled). Requires
        `vmauth.enable = true` -- see docs/decisions/0002-opt-in-everything.md
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
    };
  };
}
