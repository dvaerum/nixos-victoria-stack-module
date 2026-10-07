# None of the 3 storage binaries default to unbounded retention when
# -retentionPeriod is omitted (traces: 7d, logs: 7d, metrics: 1M --
# docs/decisions/0020); retentionPeriod = null means "don't pass the flag".
import ./storage-common.nix {
  name = "traces";
  unitName = "victoriatraces";
  binaryName = "victoria-traces";
  packageAttr = "victoriatraces";
  defaultDataDir = /var/lib/victoriatraces;
  description = "VictoriaTraces distributed tracing storage";
  limitNOFILE = 1048576;
}
