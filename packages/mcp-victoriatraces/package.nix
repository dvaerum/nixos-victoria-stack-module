{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mcp-victoriatraces";
  version = "1.5.0";

  src = fetchFromGitHub {
    # The old VictoriaMetrics-Community owner path 301-redirects here.
    owner = "VictoriaMetrics";
    repo = "mcp-victoriatraces";
    tag = "v${finalAttrs.version}";
    hash = "sha256-As1ERHKytCmFRqg3ndcSQFBFg0MBs6M5zyaGUmIntuU=";
  };

  # The pinned upstream release lacks MCP_PASSTHROUGH_HEADERS, which mcp-victoriametrics and
  # mcp-victorialogs have; drop once upstream ships it.
  patches = [ ./passthrough.patch ];

  vendorHash = null;

  subPackages = [ "cmd/mcp-victoriatraces" ];

  meta = {
    description = "Model Context Protocol (MCP) server for VictoriaTraces";
    homepage = "https://github.com/VictoriaMetrics/mcp-victoriatraces";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "mcp-victoriatraces";
  };
})
