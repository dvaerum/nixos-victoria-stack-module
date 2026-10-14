{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mcp-victoriatraces";
  version = "1.5.0";

  src = fetchFromGitHub {
    # Confirmed current location: this repo moved from
    # VictoriaMetrics-Community/mcp-victoriatraces (the org referenced in
    # the project's own README at the time this module was designed) to
    # VictoriaMetrics/mcp-victoriatraces -- the old path now 301-redirects.
    # Using the real current owner, not the stale one.
    owner = "VictoriaMetrics";
    repo = "mcp-victoriatraces";
    tag = "v${finalAttrs.version}";
    hash = "sha256-As1ERHKytCmFRqg3ndcSQFBFg0MBs6M5zyaGUmIntuU=";
  };

  # Upstream 1.5.0 lacks MCP_PASSTHROUGH_HEADERS, which mcp-victoriametrics and
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
