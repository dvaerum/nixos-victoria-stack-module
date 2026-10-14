{ pkgs, ... }:

let
  mcp-victoriatraces = pkgs.callPackage ../packages/mcp-victoriatraces/package.nix { };
in
{
  # All three MCP servers forward the headers listed in MCP_PASSTHROUGH_HEADERS
  # (the module sets Authorization); the upstream traces binary needs
  # passthrough.patch for that.
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
