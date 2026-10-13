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

  # The README's fleet snippets, evaluated the way a user pastes them: only what
  # the snippet itself imports, so a missing module import fails here (the fleet
  # example test supplies the modules itself and cannot see that).
  readmeBlocks =
    let
      pieces = lib.splitString "```nix\n" (builtins.readFile ../README.md);
    in
    map (piece: lib.head (lib.splitString "```" piece)) (lib.tail pieces);
  fleetBlocks = lib.filter (lib.hasInfix "fleet.") readmeBlocks;
  evalSnippet =
    block:
    let
      file = builtins.toFile "readme-fleet-snippet.nix" ''
        let
          victoria-stack-module.nixosModules = {
            victoriaStack = ${nixosModule.nixosModules.victoriaStack};
            victoriaCollector = ${nixosModule.nixosModules.victoriaCollector};
          };
        in
        ${builtins.replaceStrings [ "./fleet.nix" ] [ (toString ../examples/fleet.nix) ] block}
      '';
      evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (pkgs) system;
        modules = [
          file
          { system.stateVersion = lib.trivial.release; }
        ];
      };
    in
    builtins.tryEval (builtins.length evaluated.config.assertions > 0);

  # Cases docs-check must reject: each is one file added to an otherwise clean tree.
  # The words are split so this file does not trip the guard it tests.
  phase = "Pha" + "se";
  reviewer = "fre" + "sh-agent";
  narrativeCases = {
    "hyphenated phase number in a nix comment" = {
      path = "tests/x.nix";
      text = "# fixed in ${phase}-36\n";
    };
    "phase number in the README" = {
      path = "README.md";
      text = "${phase} 2 added this.\n";
    };
    "phase number in a runbook" = {
      path = "docs/runbooks/x.md";
      text = "${phase} 2 added this.\n";
    };
    "phase number in a shell script comment" = {
      path = "nixosModule/x.sh";
      text = "# ${phase} 2 added this.\n";
    };
    "a review-agent label in a comment" = {
      path = "tests/x.nix";
      text = "# found by a ${reviewer} review\n";
    };
  };
in
{
  references-resolve-and-no-stale-names = pkgs.runCommand "docs-references-resolve" { } ''
    ${lib.getExe docsCheck} ${src}
    touch $out
  '';

  readme-fleet-snippets-evaluate =
    assert fleetBlocks != [ ];
    let
      results = map evalSnippet fleetBlocks;
    in
    if lib.all (r: r.success) results then
      pkgs.runCommand "docs-readme-fleet-snippets-evaluate" { } "touch $out"
    else
      throw "a README fleet snippet does not evaluate as written (missing module import?)";

  narrative-guard-rejects-known-forms =
    pkgs.runCommand "docs-narrative-guard-rejects-known-forms"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
        clean() {
          rm -rf tree
          mkdir -p tree/docs/runbooks tree/examples tree/nixosModule tree/tests
          touch tree/README.md tree/PLAN.md
        }
        clean
        ${lib.getExe docsCheck} tree # a clean tree passes, so a rejection below is the narrative
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: case: ''
            clean
            printf '%s' ${lib.escapeShellArg case.text} > tree/${case.path}
            if ${lib.getExe docsCheck} tree 2> err; then
              echo "docs-check accepted: ${name}" >&2
              exit 1
            fi
            grep -q 'narrative' err || { echo "docs-check failed for another reason: ${name}" >&2; cat err >&2; exit 1; }
          '') narrativeCases
        )}
        touch $out
      '';
}
