{ lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    ;
in
{
  options.services.victoriaCollector = {
    metrics.enable = mkEnableOption "shipping this host's metrics (via Alloy/OTLP) to a victoriaStack gateway";
    logs.enable = mkEnableOption "shipping this host's journal (via systemd-journal-upload) to a victoriaStack gateway";
    traces.enable = mkEnableOption ''
      shipping traces (via Alloy/OTLP) to a victoriaStack gateway. Also
      stands up a local OTLP receiver for host-local apps that already
      speak OTLP -- tied 1:1 to this toggle, since a receiver with nowhere
      to forward collected spans is a dead end (see
      docs/decisions/0002-opt-in-everything.md's same reasoning applied
      here).
    '';

    writeEndpoint = mkOption {
      type = types.str;
      example = "https://victoria-stack.example.com:8443";
      description = ''
        Base URL of the victoriaStack vmauth gateway's write/ingest paths.
        Carries its own scheme (http/https) -- not assumed here, since
        consumers differ (plain HTTP over a trusted LAN vs. HTTPS over a
        tailnet).
      '';
    };

    journaldWriteEndpoint = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Overrides `writeEndpoint` for journald-upload specifically. `null`
        (the default) means "same as `writeEndpoint`". Only needs setting
        when the two must differ, e.g. an HTTPS mount for Alloy's own OTLP
        traffic vs. a separate plain-HTTP mount for journald uploads
        specifically (systemd/systemd#39166 -- an HTTP/2-only buffer bug in
        systemd-journal-upload with no code-level fix as of this writing;
        removing TLS/ALPN/h2 from just this one hop is the only real lever).
      '';
    };

    writeTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path (as a plain string, NOT a Nix path literal -- interpolating a
        real Nix path forces a Nix-store copy at eval time, which either
        crashes if the file doesn't exist yet on the build machine, the
        normal case, since it lands at runtime via LoadCredential= (see
        docs/decisions/0008/0020), or leaks the plaintext secret into the
        world-readable store if it does) to a file containing exactly one
        bearer token (no YAML structure needed at this end -- that's
        vmauth's own `writeTokensFile` list on the gateway side)
        authorizing this host's write traffic. Required whenever the
        gateway's own `requireAuthForWrites` is `true` (the default).
      '';
    };

    hostType = mkOption {
      # Interpolated unescaped into generated Alloy config text
      # (config.alloy.nix: value = "${cfg.hostType}") -- restricted to a
      # safe charset rather than attempting to escape Alloy's own string-
      # literal syntax at generation time. A value containing a `"` would
      # otherwise break the generated syntax in a way Nix eval never
      # catches (opaque string), only Alloy's own runtime parse would --
      # a real, reproduced injection-style bug (docs/decisions/0020).
      type = types.strMatching "[A-Za-z0-9_.-]+";
      example = "server";
      description = ''
        A free-form label promoted onto every metric AND trace this host
        ships (as the `host_type` attribute, via the gateway's own
        relabel config) -- restricted to `[A-Za-z0-9_.-]+` so it can
        never break the generated Alloy config syntax it's embedded in.
        Not an enum beyond that restriction -- this module has no opinion
        about what values are meaningful; that's entirely a property of
        whatever alerting rules the consumer writes on top (see
        docs/decisions -- this module takes no position on alerting, only
        on getting the label onto the data). NOT applied to logs: that
        path goes through systemd-journal-upload directly, with no Alloy
        pipeline to attach the label in.
      '';
    };

    queue = {
      maxSizeBytes = mkOption {
        type = types.int;
        default = 1073741824; # 1GiB
        description = ''
          Size cap for Alloy's disk-backed write-back queue (per exporter),
          so a gateway outage doesn't silently drop everything past the
          small in-memory default. A constrained edge device may want a
          much smaller cap; a busier host may want more headroom -- no
          universally-right value, hence a real option rather than a fixed
          constant.
        '';
      };

      directory = mkOption {
        type = types.path;
        default = /var/lib/alloy/queue;
        description = "Directory Alloy's disk-backed write-back queue is stored in.";
      };
    };

    alloy = {
      package = mkOption {
        type = types.package;
        description = "The Alloy package to use. Defaults to pkgs.grafana-alloy, set via mkDefault in config.nix.";
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra command-line flags passed straight through to Alloy.";
      };

      tlsCaFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          CA bundle for verifying the gateway's own server certificate on
          Alloy's OTLP exporters specifically (`otelcol.exporter.otlphttp`'s
          `tls.ca_file`) -- a separate knob from `trustedCertificateFile`
          below, which only covers journald-upload's own HTTPS case (a
          different, non-Alloy code path). `null` (the default) omits the
          block entirely, matching Alloy's own default (system CA trust).
        '';
      };

      tlsInsecureSkipVerify = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Skip TLS verification on Alloy's OTLP exporters
          (`otelcol.exporter.otlphttp`'s `tls.insecure_skip_verify`).
          `false` (the default) omits the setting entirely, matching
          Alloy's own default.
        '';
      };

      retryOnFailure = {
        initialInterval = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "5s";
          description = ''
            `otelcol.exporter.otlphttp`'s `retry_on_failure.initial_interval`
            on both the metrics and traces exporters. `null` (the default)
            omits the block entirely, matching Alloy's own default (`5s`).
          '';
        };

        maxInterval = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "30s";
          description = ''
            `otelcol.exporter.otlphttp`'s `retry_on_failure.max_interval`.
            `null` (the default) omits the block entirely, matching
            Alloy's own default (`30s`).
          '';
        };

        maxElapsedTime = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "5m";
          description = ''
            `otelcol.exporter.otlphttp`'s
            `retry_on_failure.max_elapsed_time` -- how long a gateway
            outage can last before Alloy gives up on a batch entirely
            (the disk-backed `queue` block is what actually protects
            against data loss during that window, this just bounds how
            long any ONE batch keeps retrying). `null` (the default)
            omits the block entirely, matching Alloy's own default (`5m`).
          '';
        };
      };
    };

    trustedCertificateFile = mkOption {
      type = types.path;
      default = /etc/ssl/certs/ca-certificates.crt;
      description = ''
        CA bundle used to verify the gateway's own server certificate for
        journald-upload's HTTPS case. Defaults to the system's normal CA
        bundle.
      '';
    };
  };
}
