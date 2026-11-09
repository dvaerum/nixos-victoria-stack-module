{
  lib,
  buildGo127Module,
  fetchFromGitHub,
}:

# nixpkgs' `victoriametrics` builds only the single-node tag (v<version>);
# the cluster binaries live under the separate `v<version>-cluster` tag and
# have no nixpkgs package. vmauth is built from the same tag (its source is
# identical to the single-node tag's), so all four binaries come from one
# derivation and cannot skew; the weekly dependency workflow bumps the version
# to the latest `-cluster` tag, independent of nixpkgs (docs/decisions/0033).
buildGo127Module (finalAttrs: {
  pname = "victoriametrics-cluster";
  version = "1.156.0";

  src = fetchFromGitHub {
    owner = "VictoriaMetrics";
    repo = "VictoriaMetrics";
    tag = "v${finalAttrs.version}-cluster";
    hash = "sha256-uZYZTScJLvLvuMBYHmPCjqzY39BjbXtr0WWR0bwaxN0=";
  };

  # vendor/ is committed upstream, so modules come from it directly.
  vendorHash = null;

  # buildGo127Module because go.mod requires Go 1.27.x (same builder as
  # nixpkgs' victoriametrics). cgo mirrors nixpkgs' workaround for
  # https://github.com/VictoriaMetrics/VictoriaMetrics/issues/11683.
  env.CGO_ENABLED = 1;

  subPackages = [
    "app/vminsert"
    "app/vmselect"
    "app/vmstorage"
    "app/vmauth"
  ];

  postPatch = ''
    # Relax go version to major.minor, as nixpkgs' victoriametrics does.
    sed -i -E 's/^(go[[:space:]]+[[:digit:]]+\.[[:digit:]]+)\.[[:digit:]]+$/\1/' go.mod
    sed -i -E 's/^(## explicit; go[[:space:]]+[[:digit:]]+\.[[:digit:]]+)\.[[:digit:]]+$/\1/' vendor/modules.txt
  '';

  # `-version` prints exactly buildinfo.Version.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=${finalAttrs.version}"
  ];

  meta = {
    description = "VictoriaMetrics cluster components (vminsert, vmselect, vmstorage, vmauth)";
    homepage = "https://github.com/VictoriaMetrics/VictoriaMetrics";
    license = lib.licenses.asl20;
    maintainers = [ ];
  };
})
