{ lib, cfg }:

let
  needsAlloyOtlp = cfg.metrics.enable || cfg.traces.enable;

  # Shared bearer-token auth handler for whichever OTLP exporters are
  # enabled -- the token itself never appears in this rendered text (it's
  # read purely via sys.env() at Alloy's own runtime, from an environment
  # variable supplied by the systemd unit's EnvironmentFile=, which points
  # at a sops-rendered, non-store path -- docs/decisions/0006). Only
  # emitted when at least one OTLP exporter needs it; logs' write path
  # goes through systemd-journal-upload instead, which doesn't use Alloy
  # at all (docs/decisions/0005).
  #
  # "Bearer " + ...: vmauth's bearer_token auth expects the standard
  # `Authorization: Bearer <token>` header -- VICTORIA_WRITE_TOKEN itself
  # holds just the raw token (matching its name), unlike
  # systemd-journal-upload's own rendered Header= drop-in, which already
  # bakes "Bearer " in at render time (config.nix). Found by actually
  # running Alloy against a real vmauth for the first time (previously
  # blocked locally by missing uid-range): every write got a real but
  # silent 401, "Dropping data" -- confirmed by checking vmauth's own
  # real bearer-token docs, which specify the "Bearer " prefix is part of
  # the Authorization header value, not implied.
  authBlock = ''
    otelcol.auth.headers "write_token" {
      header {
        key   = "Authorization"
        value = "Bearer " + sys.env("VICTORIA_WRITE_TOKEN")
      }
    }
  '';

  queueBlock = ''
    otelcol.storage.file "queue" {
      directory = "${toString cfg.queue.directory}"
    }
  '';

  # Both inert unless configured (docs/decisions/0020) -- indented to
  # nest correctly inside each exporter's own block below.
  tlsBlock = lib.optionalString (cfg.alloy.tlsCaFile != null || cfg.alloy.tlsInsecureSkipVerify) ''
    tls {
    ${lib.optionalString (
      cfg.alloy.tlsCaFile != null
    ) "  ca_file = \"/run/credentials/alloy.service/tls-ca\""}
    ${lib.optionalString cfg.alloy.tlsInsecureSkipVerify "  insecure_skip_verify = true"}
    }
  '';

  retryOnFailureBlock =
    let
      r = cfg.alloy.retryOnFailure;
    in
    lib.optionalString (r.initialInterval != null || r.maxInterval != null || r.maxElapsedTime != null)
      ''
        retry_on_failure {
        ${lib.optionalString (r.initialInterval != null) "  initial_interval = \"${r.initialInterval}\""}
        ${lib.optionalString (r.maxInterval != null) "  max_interval = \"${r.maxInterval}\""}
        ${lib.optionalString (r.maxElapsedTime != null) "  max_elapsed_time = \"${r.maxElapsedTime}\""}
        }
      '';

  alloyStringList = names: "[" + lib.concatMapStringsSep ", " (n: ''"${n}"'') names + "]";

  metricsSection = lib.optionalString cfg.metrics.enable ''
    // Metrics: host metrics -> OTLP
    prometheus.exporter.unix "host" {
      enable_collectors = ${alloyStringList ([ "systemd" ] ++ cfg.metrics.extraCollectors)}
      ${lib.optionalString (
        cfg.metrics.disabledCollectors != [ ]
      ) "disable_collectors = ${alloyStringList cfg.metrics.disabledCollectors}"}
      systemd {}
    }

    prometheus.scrape "host" {
      targets    = prometheus.exporter.unix.host.targets
      forward_to = [otelcol.receiver.prometheus.host.receiver]
      ${lib.optionalString (
        cfg.metrics.scrapeInterval != null
      ) ''scrape_interval = "${cfg.metrics.scrapeInterval}"''}
    }

    otelcol.receiver.prometheus "host" {
      output {
        metrics = [otelcol.processor.filter.keep_current_systemd_state.input]
      }
    }

    // node_systemd_unit_state is one-hot (5 states per unit, one real
    // ActiveState value) -- keep only the currently-true datapoint before
    // it ever reaches VictoriaMetrics, 5 series/unit becomes 1.
    otelcol.processor.filter "keep_current_systemd_state" {
      error_mode = "ignore"

      metric_conditions {
        context = "datapoint"
        conditions = [
          `metric.name == "node_systemd_unit_state" and datapoint.value_double != 1.0`,
        ]
      }

      output {
        metrics = [otelcol.processor.transform.systemd_state_to_number.input]
      }
    }

    // Replaces the surviving datapoint's value with a numeric state code
    // and drops the now-redundant "state" label (a label value changing
    // is a new series, not a mutation -- the unit would otherwise
    // accumulate one series per state it ever visited).
    otelcol.processor.transform "systemd_state_to_number" {
      error_mode = "ignore"

      metric_statements {
        context    = "datapoint"
        conditions = [`metric.name == "node_systemd_unit_state"`]
        statements = [
          `set(datapoint.value_int, 0) where datapoint.attributes["state"] == "active"`,
          `set(datapoint.value_int, 1) where datapoint.attributes["state"] == "activating"`,
          `set(datapoint.value_int, 2) where datapoint.attributes["state"] == "deactivating"`,
          `set(datapoint.value_int, 3) where datapoint.attributes["state"] == "inactive"`,
          `set(datapoint.value_int, 4) where datapoint.attributes["state"] == "failed"`,
          `delete_key(datapoint.attributes, "state")`,
        ]
      }

      output {
        metrics = [otelcol.processor.attributes.add_host_type.input]
      }
    }

    // host_type: becomes the VictoriaMetrics label of the same name as it
    // is. Spelled with an underscore on purpose -- a name with a dot would be
    // stored verbatim and only a quoted selector could match it.
    otelcol.processor.attributes "add_host_type" {
      action {
        key    = "host_type"
        value  = "${cfg.hostType}"
        action = "upsert"
      }

      output {
        metrics = [otelcol.processor.transform.rename_scrape_meta.input]
      }
    }

    // Prometheus's own scrape meta-metrics (up, scrape_duration_seconds,
    // etc.) also get generated independently by the gateway's own
    // self-monitoring scrape jobs -- same names, unrelated meanings.
    // Renaming this collector's own copies with an "alloy_" prefix avoids
    // an unfiltered query silently mixing the two.
    otelcol.processor.transform "rename_scrape_meta" {
      error_mode = "ignore"

      metric_statements {
        context = "metric"
        statements = [
          `set(metric.name, Concat(["alloy_", metric.name], "")) where metric.name == "up" or metric.name == "scrape_duration_seconds" or metric.name == "scrape_samples_scraped" or metric.name == "scrape_samples_post_metric_relabeling" or metric.name == "scrape_series_added"`,
        ]
      }

      output {
        metrics = [otelcol.processor.batch.default.input]
      }
    }
  '';

  tracesSection = lib.optionalString cfg.traces.enable ''
    // Traces: local OTLP receiver, for any app on this host that already
    // speaks OTLP. Tied 1:1 to traces.enable -- a receiver with nowhere
    // to forward collected spans is a dead end.
    otelcol.receiver.otlp "local" {
      grpc {
        endpoint = "127.0.0.1:4317"
      }
      http {
        endpoint = "127.0.0.1:4318"
      }
      output {
        traces = [otelcol.processor.attributes.add_host_type_traces.input]
      }
    }

    // host_type attribute on every trace span, same label this module
    // already attaches to metrics -- a fleet-identification label that
    // silently only covered one of two eligible signal types was more
    // surprising than useful (docs/decisions/0020).
    otelcol.processor.attributes "add_host_type_traces" {
      action {
        key    = "host_type"
        value  = "${cfg.hostType}"
        action = "upsert"
      }

      output {
        traces = [otelcol.processor.batch.default.input]
      }
    }
  '';

  batchSection = lib.optionalString needsAlloyOtlp ''
    otelcol.processor.batch "default" {
      output {
        ${lib.optionalString cfg.metrics.enable "metrics = [otelcol.exporter.otlphttp.metrics.input]"}
        ${lib.optionalString cfg.traces.enable "traces  = [otelcol.exporter.otlphttp.traces.input]"}
      }
    }
  '';

  metricsExporter = lib.optionalString cfg.metrics.enable ''
    // Base path + OTLP's own default /v1/<signal> suffixing lines up with
    // the gateway's own routing table: resolves to
    // /opentelemetry/v1/metrics.
    otelcol.exporter.otlphttp "metrics" {
      client {
        endpoint = "${cfg.writeEndpoint}/opentelemetry"
        auth     = otelcol.auth.headers.write_token.handler
        ${tlsBlock}
      }
      sending_queue {
        storage    = otelcol.storage.file.queue.handler
        sizer      = "bytes"
        queue_size = ${toString cfg.queue.maxSizeBytes}
      }
      ${retryOnFailureBlock}
    }
  '';

  tracesExporter = lib.optionalString cfg.traces.enable ''
    // Resolves to /insert/opentelemetry/v1/traces.
    otelcol.exporter.otlphttp "traces" {
      client {
        endpoint = "${cfg.writeEndpoint}/insert/opentelemetry"
        auth     = otelcol.auth.headers.write_token.handler
        ${tlsBlock}
      }
      sending_queue {
        storage    = otelcol.storage.file.queue.handler
        sizer      = "bytes"
        queue_size = ${toString cfg.queue.maxSizeBytes}
      }
      ${retryOnFailureBlock}
    }
  '';
in
lib.concatStringsSep "\n\n" (
  lib.filter (s: s != "") [
    (lib.optionalString needsAlloyOtlp authBlock)
    metricsSection
    tracesSection
    (lib.optionalString needsAlloyOtlp queueBlock)
    batchSection
    metricsExporter
    tracesExporter
  ]
)
