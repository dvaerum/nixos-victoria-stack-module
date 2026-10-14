# The metrics database is the cluster (docs/decisions/0033): the units come
# from metrics-cluster-units.nix, so storage-common.nix renders only the parts
# every storage service shares (static user, data directory, warnings).
import ./storage-common.nix {
  name = "metrics";
  unitName = "victoriametrics";
  binaryName = "vmstorage";
  packageFor = pkgs: pkgs.callPackage ../../packages/victoriametrics-cluster/package.nix { };
  defaultDataDir = /var/lib/victoriametrics;
  description = "VictoriaMetrics cluster storage";
  renderUnit = false;
}
