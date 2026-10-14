# No limitNOFILE: nixpkgs' own victorialogs module doesn't set one either
# (docs/decisions/0015).
import ./storage-common.nix {
  name = "logs";
  unitName = "victorialogs";
  binaryName = "victoria-logs";
  packageFor = pkgs: pkgs.victorialogs;
  snapshotCreatePath = "/internal/partition/snapshot/create";
  defaultDataDir = /var/lib/victorialogs;
  description = "VictoriaLogs log storage";
  supportsSyslog = true;
}
