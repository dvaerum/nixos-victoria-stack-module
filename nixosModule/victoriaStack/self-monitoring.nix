# Shared by the 3 storage services and vmauth: all four binaries have the
# same -pushmetrics.* flag family, which makes the service itself push its
# own /metrics page to a URL on an interval -- no extra unit or timer.
{ lib }:
{
  # The flags for one service, as RAW strings (the caller does any shell
  # escaping its own ExecStart construction needs); empty unless enabled AND the metrics database
  # exists to push into (assertions.nix reports the missing-metrics case, so
  # this must not throw before that message can be shown).
  mkFlags =
    {
      selfMonitoring, # services.victoriaStack.<svc>.selfMonitoring
      metricsEnabled,
      metricsUrl, # services.victoriaStack.metrics.effectiveUrl (only read when enabled)
      job,
    }:
    lib.optionals (selfMonitoring.enable && metricsEnabled) [
      "-pushmetrics.url=${metricsUrl}/api/v1/import/prometheus"
      "-pushmetrics.interval=${selfMonitoring.interval}"
      # Without a per-service job, series like the Go runtime's would
      # collide across the four services.
      "-pushmetrics.extraLabel=job=\"${job}\""
    ];
}
