{ pkgs, ... }:

let
  mcp-victoriatraces = pkgs.callPackage ../packages/mcp-victoriatraces/package.nix { };
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
}
