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

  # vendor/ is committed upstream, and buildGoModule refuses a non-null
  # vendorHash when a vendor/ directory exists ("vendor folder exists, please
  # set 'vendorHash = null;'"), so the modules are taken from the committed
  # vendor tree rather than fetched/verified against go.sum.
  vendorHash = null;

  subPackages = [ "cmd/mcp-victoriametrics" ];

  # Upstream requires Go 1.26+; keep the nixpkgs Go at or above that (no
  # toolchain override).

  meta = {
    description = "Model Context Protocol (MCP) server for VictoriaMetrics";
    homepage = "https://github.com/VictoriaMetrics/mcp-victoriametrics";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "mcp-victoriametrics";
  };
})
