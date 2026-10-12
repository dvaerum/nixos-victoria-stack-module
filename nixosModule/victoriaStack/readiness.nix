# The ExecStartPost readiness probe shared by every unit of the module. The
# deadline (the unit's startupTimeout, or the 90s constant of vmauth and the MCP
# servers) bounds how long a LIVE but unready process is waited for; a main
# process that dies ends the probe at once (readiness.sh).
{ lib, pkgs }:
let
  startupTimeout = import ./startup-timeout.nix { inherit lib; };
  execEscape = import ./exec-escape.nix { inherit lib; };

  probe = pkgs.writeShellApplication {
    name = "victoria-stack-readiness";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.wait4x
    ];
    text = builtins.readFile ./readiness.sh;
  };
in
{
  # kind: "http" (target is a URL) | "tcp" (target is host:port);
  # timeout: a startup-timeout.nix duration such as "5m" or "90s".
  command =
    {
      unit,
      kind,
      target,
      timeout,
    }:
    lib.escapeShellArgs (
      [ (lib.getExe probe) ]
      ++ map execEscape.escape [
        unit
        (toString (startupTimeout.seconds timeout))
        kind
        target
      ]
    );
}
