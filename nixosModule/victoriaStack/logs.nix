# victoria-logs' own -retentionPeriod is a real, documented flag on the
# binary itself (confirmed via `victoria-logs --help`) -- the nixpkgs
# module's lack of a first-class option for it (docs/decisions/0001) was a
# module-authoring gap, not a binary limitation. No limitNOFILE: nixpkgs'
# own victorialogs module doesn't set one either (docs/decisions/0015).
import ./storage-common.nix {
  name = "logs";
  unitName = "victorialogs";
  binaryName = "victoria-logs";
  packageAttr = "victorialogs";
  snapshotCreatePath = "/internal/partition/snapshot/create";
  defaultDataDir = /var/lib/victorialogs;
  description = "VictoriaLogs log storage";
}
