{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mcp-victoriametrics";
  version = "1.20.2";

  src = fetchFromGitHub {
    owner = "VictoriaMetrics";
    repo = "mcp-victoriametrics";
    tag = "v${finalAttrs.version}";
    hash = "sha256-7kN7qwsvTL0scfBxMO/nrvikiysUxPY8nSFkhJsgGDM=";
  };

  # vendor/ is committed in the upstream repo -- confirmed empirically:
  # buildGoModule's own buildPhase refuses to proceed with a non-null
  # vendorHash when a vendor/ directory already exists ("vendor folder
  # exists, please set 'vendorHash = null;'"), so the modules are taken
  # from the committed vendor tree directly rather than fetched/verified
  # against go.sum.
  vendorHash = null;

  subPackages = [ "cmd/mcp-victoriametrics" ];

  # Go 1.26+ required upstream (confirmed via the project's own README);
  # pkgs.go already satisfies this on nixpkgs-unstable (confirmed:
  # pkgs.go.version == "1.26.8" at build time) -- no toolchain override
  # needed.

  meta = {
    description = "Model Context Protocol (MCP) server for VictoriaMetrics";
    homepage = "https://github.com/VictoriaMetrics/mcp-victoriametrics";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "mcp-victoriametrics";
  };
})
