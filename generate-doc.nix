# Just run this nix program with: nix-build generate-doc.nix

{
  pkgs ? import <nixpkgs> { },
  ...
}@args:
let
  inherit (pkgs)
    lib
    nixosOptionsDoc
    runCommand
    ;

  # Evaluate both option trees together -- same `nixosOptionsDoc` approach
  # as nixos-router-module's own generate-doc.nix, extended to two
  # separate modules/option trees in one generated doc.
  eval = lib.evalModules {
    modules = [
      ./nixosModule/victoriaStack/options.nix
      ./nixosModule/victoriaCollector/options.nix
    ];
  };

  optionsDoc = nixosOptionsDoc {
    inherit (eval) options;
  };
in
runCommand "options-doc.md" { } ''
  cat ${optionsDoc.optionsCommonMark} >> $out
''
