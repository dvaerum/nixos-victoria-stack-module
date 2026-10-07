import ./storage-common.nix {
  name = "metrics";
  unitName = "victoriametrics";
  binaryName = "victoria-metrics";
  packageAttr = "victoriametrics";
  defaultDataDir = /var/lib/victoriametrics;
  description = "VictoriaMetrics time series database";
  limitNOFILE = 1048576;
}
