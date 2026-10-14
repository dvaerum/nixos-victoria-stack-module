{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  # tests/lib.nix is a helper the groups import; every other tests/*.nix is a group.
  helpers = [
    "default.nix"
    "lib.nix"
  ];
  testFiles = lib.filter (f: !(lib.elem f helpers)) (
    lib.filter (lib.hasSuffix ".nix") (lib.attrNames (builtins.readDir ./.))
  );

  # One registration per line in tests/default.nix: `<group> = import ./<file>.nix ...`.
  registrations = lib.concatMap (
    line:
    let
      m = builtins.match " *([a-z0-9-]+) = import \\./([a-z0-9-]+\\.nix) .*" line;
    in
    lib.optional (m != null) {
      group = builtins.elemAt m 0;
      file = builtins.elemAt m 1;
    }
  ) (lib.splitString "\n" (builtins.readFile ./default.nix));
  registeredGroups = map (r: r.group) registrations;
  registeredFiles = map (r: r.file) registrations;

  exposed = lib.attrNames nixosModule.testSections.${pkgs.stdenv.hostPlatform.system};

  problems =
    lib.optional (
      registrations == [ ]
    ) "no group registration found in tests/default.nix (parser out of date?)"
    ++ map (f: "tests/${f} is not registered in tests/default.nix") (
      lib.subtractLists registeredFiles testFiles
    )
    ++ map (g: "group ${g} is registered but not exposed in testSections") (
      lib.subtractLists exposed registeredGroups
    )
    ++ map (g: "testSections exposes ${g}, which tests/default.nix does not register") (
      lib.subtractLists registeredGroups exposed
    );
in
{
  # `gate.sh --sections` builds groups by name; a test file left out of
  # tests/default.nix would silently never run in either gate.
  registration-matches-files = pkgs.runCommand "test-sections-registration" { } (
    if problems == [ ] then
      "touch $out"
    else
      ''
        cat >&2 <<'EOT'
        ${lib.concatStringsSep "\n" problems}
        EOT
        exit 1
      ''
  );
}
