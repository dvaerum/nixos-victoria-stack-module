{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mcp-victorialogs";
  version = "1.9.0";

  src = fetchFromGitHub {
    owner = "VictoriaMetrics";
    repo = "mcp-victorialogs";
    tag = "v${finalAttrs.version}";
    hash = "sha256-esfd6Eg1j2BCgee1T5tiIdSPWVEBqhI4UGDKRFYyn3s=";
  };

  vendorHash = null;

  subPackages = [ "cmd/mcp-victorialogs" ];

  meta = {
    description = "Model Context Protocol (MCP) server for VictoriaLogs";
    homepage = "https://github.com/VictoriaMetrics/mcp-victorialogs";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "mcp-victorialogs";
  };
})
