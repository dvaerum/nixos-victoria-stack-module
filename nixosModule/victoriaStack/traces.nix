import ./storage-common.nix {
  name = "traces";
  unitName = "victoriatraces";
  binaryName = "victoria-traces";
  packageFor = pkgs: pkgs.victoriatraces;
  snapshotCreatePath = "/internal/partition/snapshot/create";
  defaultDataDir = /var/lib/victoriatraces;
  description = "VictoriaTraces distributed tracing storage";
  limitNOFILE = 1048576;
}
