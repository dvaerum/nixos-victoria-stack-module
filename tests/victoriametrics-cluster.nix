{ pkgs, nixosModule }:

let
  cluster = pkgs.callPackage ../packages/victoriametrics-cluster/package.nix { };
in
{
  # Skew guard: vmauth ships in pkgs.victoriametrics (the default of vmauth.package) and the cluster
  # binaries are built from source, so a nixpkgs bump moves one without the
  # other. Failing here is the signal to bump the cluster package.
  cluster-version-matches-vmauth-package =
    pkgs.runCommand "cluster-version-matches-vmauth-package"
      {
        clusterVersion = cluster.version;
        vmauthVersion = pkgs.victoriametrics.version;
      }
      ''
        if [ "$clusterVersion" != "$vmauthVersion" ]; then
          echo "packages/victoriametrics-cluster is $clusterVersion but pkgs.victoriametrics is $vmauthVersion: bump the cluster package (version + hash)" >&2
          exit 1
        fi
        touch $out
      '';

  cluster-binaries-build-and-report-their-version =
    pkgs.runCommand "cluster-binaries-build-and-report-their-version" { }
      ''
        want=${cluster.version}
        for bin in vminsert vmselect vmstorage; do
          got=$(${cluster}/bin/$bin -version)
          if [ "$got" != "$want" ]; then
            echo "$bin -version printed '$got', expected '$want'" >&2
            exit 1
          fi
        done
        have=$(ls ${cluster}/bin | tr '\n' ' ')
        if [ "$have" != "vminsert vmselect vmstorage " ]; then
          echo "unexpected binaries in bin/: $have" >&2
          exit 1
        fi
        touch $out
      '';
}
