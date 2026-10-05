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
  authBlock = ''
    otelcol.auth.headers "write_token" {
      header {
        key   = "Authorization"
        value = sys.env("VICTORIA_WRITE_TOKEN")
      }
    }
  '';

  queueBlock = ''
    otelcol.storage.file "queue" {
      directory = "${toString cfg.queue.directory}"
    }
  '';

  metricsSection = lib.optionalString cfg.metrics.enable ''
    // Metrics: host metrics -> OTLP
    prometheus.exporter.unix "host" {
      enable_collectors = ["systemd"]
      systemd {}
    }

    prometheus.scrape "host" {
      targets    = prometheus.exporter.unix.host.targets
      forward_to = [otelcol.receiver.prometheus.host.receiver]
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

    // host_type label, promoted to a real VictoriaMetrics label by the
    // gateway's own relabelConfig.
    otelcol.processor.attributes "add_host_type" {
      action {
        key    = "host.type"
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
      }
      sending_queue {
        storage    = otelcol.storage.file.queue.handler
        sizer      = "bytes"
        queue_size = ${toString cfg.queue.maxSizeBytes}
      }
    }
  '';

  tracesExporter = lib.optionalString cfg.traces.enable ''
    // Resolves to /insert/opentelemetry/v1/traces.
    otelcol.exporter.otlphttp "traces" {
      client {
        endpoint = "${cfg.writeEndpoint}/insert/opentelemetry"
        auth     = otelcol.auth.headers.write_token.handler
      }
      sending_queue {
        storage    = otelcol.storage.file.queue.handler
        sizer      = "bytes"
        queue_size = ${toString cfg.queue.maxSizeBytes}
      }
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
