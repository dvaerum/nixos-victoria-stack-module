# retentionPeriod = null means "don't pass the flag"; the binary's own default
# applies (see options.nix, docs/decisions/0020).
import ./storage-common.nix {
  name = "traces";
  unitName = "victoriatraces";
  binaryName = "victoria-traces";
  packageAttr = "victoriatraces";
  snapshotCreatePath = "/internal/partition/snapshot/create";
  defaultDataDir = /var/lib/victoriatraces;
  description = "VictoriaTraces distributed tracing storage";
  limitNOFILE = 1048576;
}
