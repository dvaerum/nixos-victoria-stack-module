{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  docsCheck = pkgs.writeShellApplication {
    name = "docs-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
    ];
    text = builtins.readFile ./docs-check.sh;
  };

  # Only what the check reads, so unrelated edits do not rebuild it.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../README.md
      ../PLAN.md
      ../docs
      ../examples
      ../nixosModule
      ../tests
    ];
  };
in
{
  references-resolve-and-no-stale-names = pkgs.runCommand "docs-references-resolve" { } ''
    ${lib.getExe docsCheck} ${src}
    touch $out
  '';
}
