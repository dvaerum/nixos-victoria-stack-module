# Run via the flake, not directly: `nix build .#optionsDoc` (what
# update-docs.yml actually does) -- that resolves `pkgs` from this
# project's own pinned flake.lock nixpkgs. The `pkgs ? import <nixpkgs>
# {}` default below only exists as a fallback for a bare
# `nix-build generate-doc.nix` invocation outside the flake, which pulls
# from NIX_PATH/channels instead and is NOT what produces the real,
# reproducible docs/options.md CI commits.
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

  # Declarations must not embed the store path of this checkout: it changes
  # on every commit, which made CI regenerate docs/options.md on every push.
  repoRoot = toString ./. + "/";
  nixpkgsRev = (lib.importJSON ./flake.lock).nodes.nixpkgs.locked.rev;

  optionsDoc = nixosOptionsDoc {
    # `_module` is the module system's own plumbing, not part of this API.
    options = removeAttrs eval.options [ "_module" ];
    # The locked revision makes any nixpkgs declaration link resolve.
    revision = nixpkgsRev;
    transformOptions =
      opt:
      opt
      // {
        declarations = map (
          d:
          let
            rel = lib.removePrefix repoRoot (toString d);
          in
          if lib.hasPrefix repoRoot (toString d) then
            {
              name = rel;
              url = "https://github.com/dvaerum/nixos-victoria-stack-module/blob/main/${rel}";
            }
          else
            d
        ) opt.declarations;
      };
  };
in
runCommand "options-doc.md" { } ''
  cat ${optionsDoc.optionsCommonMark} >> $out
''
