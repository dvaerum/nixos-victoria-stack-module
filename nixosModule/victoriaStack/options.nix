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
      # (confirmed per-binary via --help, not assumed to match): metrics
      # and logs default to unbounded; traces defaults to 7 days.
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
      retentionPeriodNullBehavior = "effectively unbounded for this binary";
    };

    logs = mkStorageServiceOptions {
      name = "victorialogs";
      binaryName = "victoria-logs";
      defaultListenAddress = "127.0.0.1:4202";
      defaultMcpPort = 4206;
      retentionPeriodNullBehavior = "effectively unbounded for this binary";
    };

    traces = mkStorageServiceOptions {
      name = "victoriatraces";
      binaryName = "victoria-traces";
      defaultListenAddress = "127.0.0.1:4203";
      defaultMcpPort = 4207;
      # Confirmed from victoria-traces' own --help/upstream docs: unlike
      # metrics/logs, omitting -retentionPeriod does NOT mean unbounded --
      # it defaults to 7 days. See traces.nix's own ExecStart comment and
      # docs/decisions/0020.
      retentionPeriodNullBehavior = "a 7 day default for this binary, NOT unbounded -- unlike metrics/logs";
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
          service is enabled.
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
