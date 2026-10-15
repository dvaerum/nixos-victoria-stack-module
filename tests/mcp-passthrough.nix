{ pkgs, ... }:

let
  mcp-victoriatraces = pkgs.callPackage ../packages/mcp-victoriatraces/package.nix { };
  mcp-victoriametrics = pkgs.callPackage ../packages/mcp-victoriametrics/package.nix { };
in
{
  # mcp-victoriatraces needs passthrough.patch to forward the headers listed in
  # MCP_PASSTHROUGH_HEADERS (the module sets Authorization); this runs the real
  # binary.
  mcp-victoriatraces-forwards-listed-client-headers =
    pkgs.runCommand "mcp-victoriatraces-forwards-listed-client-headers"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 -I ${./mcp-passthrough.py} ${mcp-victoriatraces}/bin/mcp-victoriatraces
        echo OK > $out
      '';

  # mcp-victoriametrics needs tenant.patch for the `tenant` tool argument that lets a vmauth user
  # with several tenants pick one (as mcp-victorialogs/-victoriatraces do); this runs the real binary.
  mcp-victoriametrics-tenant-argument-becomes-headers =
    pkgs.runCommand "mcp-victoriametrics-tenant-argument-becomes-headers"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 -I ${./mcp-metrics-tenant.py} ${mcp-victoriametrics}/bin/mcp-victoriametrics
        echo OK > $out
      '';
}
