{ lib, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    ;
  common = import ./common.nix { inherit lib; };
in
{
  options.services.victoriaCollector = {
    metrics.enable = mkEnableOption "shipping this host's metrics (via Alloy/OTLP) to a victoriaStack gateway";

    # Collector names and the interval are interpolated unescaped into the
    # generated Alloy config (config.alloy.nix), so they are restricted to
    # a safe charset, same reasoning as hostType (docs/decisions/0020).
    metrics.extraCollectors = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9_]+");
      default = [ ];
      example = [
        "processes"
        "textfile"
      ];
      description = ''
        Extra node_exporter collectors to enable, on top of
        node_exporter's own default-enabled set (see the "Collectors
        list" table in Alloy's `prometheus.exporter.unix` docs for what
        that is) plus this module's own always-on `systemd` collector.
        `[ ]` (the default) changes nothing.

        Alloy ignores a collector name it does not know without an error, so
        a misspelt name does nothing: check that the metrics you expect
        actually appear.
      '';
    };

    metrics.disabledCollectors = mkOption {
      type = types.listOf (types.strMatching "[a-z0-9_]+");
      default = [ ];
      example = [
        "hwmon"
        "zfs"
      ];
      description = ''
        node_exporter collectors to disable -- e.g. an expensive one on a
        resource-constrained host. Takes precedence over `extraCollectors`
        if a name appears in both (Alloy's own `disable_collectors`
        semantics). `[ ]` (the default) changes nothing.
      '';
    };

    metrics.scrapeInterval = mkOption {
      type = types.nullOr common.durationType;
      default = null;
      example = "30s";
      description = ''
        Overrides Alloy's own `prometheus.scrape` default (60s) for the
        host-metrics scrape job. `null` (the default) omits the argument
        entirely, matching Alloy's upstream default. Must be longer than zero.
        Below 10s the module also sets `scrape_timeout` to the interval:
        Alloy's own 10s timeout default makes it exit at start when it
        exceeds the interval.
      '';
    };
    logs.enable = mkEnableOption "shipping this host's journal (via systemd-journal-upload) to a victoriaStack gateway";
    traces.enable = mkEnableOption ''
      shipping traces (via Alloy/OTLP) to a victoriaStack gateway. Also
      stands up a local OTLP receiver for host-local apps that already
      speak OTLP -- tied 1:1 to this toggle, since a receiver with nowhere
      to forward collected spans is a dead end (see
      docs/decisions/0002-opt-in-everything.md's same reasoning applied
      here).
    '';

    traces.receiver.grpcPort = mkOption {
      type = types.port;
      default = 4317;
      description = ''
        Port of the local OTLP/gRPC receiver `traces.enable` stands up (loopback
        only, for apps on this host). Change it when 4317 is already taken.
      '';
    };

    traces.receiver.httpPort = mkOption {
      type = types.port;
      default = 4318;
      description = ''
        Port of the local OTLP/HTTP receiver (loopback only). Change it when 4318
        is already taken.
      '';
    };

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

        Rotation: replacing the file's content only takes effect once
        `victoria-collector-alloy-write-token.service` (which renders it for
        Alloy) and `victoria-collector-journal-upload-token.service` (for the
        log uploader) are restarted; restarting them restarts the services that
        require them, so Alloy and systemd-journal-upload send the new token. With
        sops-nix, list both units in the secret's `restartUnits`. If a render
        unit fails, the services that require it stop rather than keep sending
        a stale or missing token.
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
      #
      # nullOr so a logs-only host can omit it; assertions.nix requires it
      # whenever metrics or traces is enabled.
      type = types.nullOr (types.strMatching "[A-Za-z0-9_.-]+");
      default = null;
      example = "server";
      description = ''
        A free-form label promoted onto every metric AND trace this host
        ships, as the `host_type` label (`{host_type="server"}` in a
        query; series stored by older versions carry `host.type`
        instead) -- restricted to `[A-Za-z0-9_.-]+` so it can
        never break the generated Alloy config syntax it's embedded in.
        Not an enum beyond that restriction -- this module has no opinion
        about what values are meaningful; that's entirely a property of
        whatever alerting rules the consumer writes on top (this module
        only gets the label onto the data). NOT applied to logs: that
        path goes through systemd-journal-upload directly, with no Alloy
        pipeline to attach the label in, so it may be omitted when only
        `logs.enable` is set; it is required whenever `metrics.enable` or
        `traces.enable` is.
      '';
    };

    queue = {
      maxSizeBytes = mkOption {
        type = types.ints.positive;
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
      dynamicUser = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether Alloy runs as a systemd `DynamicUser` (nixpkgs' own default
          for it) or as a static `alloy` user and group. A dynamic user can
          only write inside its own `StateDirectory` (`/var/lib/alloy`), so a
          `queue.directory` outside it needs `dynamicUser = false`: nothing
          would otherwise own that directory for the dynamic user, and Alloy
          would fail at run time. With a static user the module creates the
          directory for it (`manageTmpfiles`) and re-adds the sandboxing a
          dynamic user implies.
        '';
      };

      manageTmpfiles = mkOption {
        type = types.bool;
        default = true;
        description = ''
          With `dynamicUser = false`, whether this module creates
          `queue.directory` (mode 0750, owned by `alloy`) on every boot via
          `systemd.tmpfiles.rules`. The directory is only created when it is
          outside `/var/lib/alloy`: inside it, the unit's own `StateDirectory`
          already covers it. Set to `false` to manage a directory outside it
          yourself.
        '';
      };

      suppressDynamicUserWarning = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Silence the build-time warning for a dynamic user with a
          `queue.directory` outside `/var/lib/alloy` (use once you have made
          that directory writable for Alloy's runtime user yourself).
        '';
      };

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
          type = types.nullOr common.durationType;
          default = null;
          example = "5s";
          description = ''
            `otelcol.exporter.otlphttp`'s `retry_on_failure.initial_interval`
            on both the metrics and traces exporters. `null` (the default)
            omits the block entirely, matching Alloy's own default (`5s`).
          '';
        };

        maxInterval = mkOption {
          type = types.nullOr common.durationType;
          default = null;
          example = "30s";
          description = ''
            `otelcol.exporter.otlphttp`'s `retry_on_failure.max_interval`.
            `null` (the default) omits the block entirely, matching
            Alloy's own default (`30s`).
          '';
        };

        maxElapsedTime = mkOption {
          type = types.nullOr common.durationType;
          default = "0s";
          example = "5m";
          description = ''
            `otelcol.exporter.otlphttp`'s
            `retry_on_failure.max_elapsed_time` -- how long a gateway
            outage can last before Alloy gives up on a batch entirely.
            The default `"0s"` means never: a batch keeps retrying until the
            gateway is back, and the disk-backed `queue` is what bounds the
            data held (when it is full the oldest data is dropped). Alloy's
            own default is `5m`, after which it logs "Dropping data" even
            though the queue still has room -- so a longer outage would lose
            data the queue was meant to protect. Set a duration to give up
            sooner; `null` omits the setting (Alloy's own `5m`).
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
