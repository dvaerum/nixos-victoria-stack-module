# How user-supplied text is made safe to put in an ExecStart= argument list.
# systemd reads C escapes (`\"` loses its backslash) and expands specifiers
# (`%h`) and `${VAR}` inside the quotes lib.escapeShellArgs adds, so text the
# user typed must be escaped first to reach the process literally. The
# module's own specifiers (the `%d` credentials directory) are NOT passed
# through here: they must stay raw.
#
# nixpkgs' utils.escapeSystemdExecArg is not used: it double-quotes every
# argument, which changes the rendered unit that the tests and ADR 0028
# describe, for no gain over escaping before lib.escapeShellArgs.
{ lib }:
{
  escape = lib.replaceStrings [ "\\" "%" "$" ] [ "\\\\" "%%" "$$" ];

  # systemd.services.<name>.environment: NixOS already escapes backslashes and
  # quotes there but leaves `%`, which systemd expands as a specifier.
  escapeEnvironment = lib.replaceStrings [ "%" ] [ "%%" ];
}
