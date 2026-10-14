{
  lib,
  buildGo127Module,
  fetchFromGitHub,
}:

# nixpkgs' `victoriametrics` builds only the single-node tag (v<version>);
# the cluster binaries live under the separate `v<version>-cluster` tag and
# have no nixpkgs package. The version is pinned by hand to
# pkgs.victoriametrics.version so vmauth (from that package) and these
# binaries never skew; tests/victoriametrics-cluster.nix fails when they
# diverge, and the weekly dependency workflow bumps both together.
buildGo127Module (finalAttrs: {
  pname = "victoriametrics-cluster";
  version = "1.153.0";

  src = fetchFromGitHub {
    owner = "VictoriaMetrics";
    repo = "VictoriaMetrics";
    tag = "v${finalAttrs.version}-cluster";
    hash = "sha256-/h677p/ozlm1UGfIird5T6xKMR6dddO8R8TrPCxxlF4=";
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
    description = "VictoriaMetrics cluster components (vminsert, vmselect, vmstorage)";
    homepage = "https://github.com/VictoriaMetrics/VictoriaMetrics";
    license = lib.licenses.asl20;
    maintainers = [ ];
  };
})
