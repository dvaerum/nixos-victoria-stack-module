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
  readmeFenced =
    lang:
    let
      pieces = lib.splitString "```${lang}\n" (builtins.readFile ../README.md);
    in
    map (piece: lib.head (lib.splitString "```" piece)) (lib.tail pieces);
  readmeBlocks = readmeFenced "nix";
  fleetBlocks = lib.filter (lib.hasInfix "fleet.") readmeBlocks;
  tenantBlocks = lib.filter (lib.hasInfix "tenant") readmeBlocks;
  tenantYamlBlocks = lib.filter (lib.hasInfix "tenant") (readmeFenced "yaml");

  evalBlock =
    block:
    let
      file = builtins.toFile "readme-snippet.nix" ''
        let
          victoria-stack-module.nixosModules = {
            victoriaStack = ${nixosModule.nixosModules.victoriaStack};
            victoriaCollector = ${nixosModule.nixosModules.victoriaCollector};
          };
        in
        ${builtins.replaceStrings [ "./fleet.nix" ] [ (toString ../examples/fleet.nix) ] block}
      '';
    in
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs) system;
      modules = [
        file
        {
          system.stateVersion = lib.trivial.release;
          # Not what the snippets are about, but a NixOS system asserts on them.
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ];
    };
  evalSnippet = block: builtins.tryEval (builtins.length (evalBlock block).config.assertions > 0);

  # The tenant snippets are the documented way to set tenants up, so they must
  # also pass the module's own assertions (an unknown tenant name, a bad port).
  failedAssertions =
    block: map (a: a.message) (lib.filter (a: !a.assertion) (evalBlock block).config.assertions);
  evalTenantSnippet = block: builtins.tryEval (builtins.deepSeq (failedAssertions block) true);
  # The tenants the README declares: its token-file snippets may name only these.
  readmeTenantNames = lib.unique (
    lib.concatMap (
      block:
      let
        r = builtins.tryEval (
          lib.attrNames (lib.attrByPath [ "services" "victoriaStack" "tenants" ] { } (evalBlock block).config)
        );
      in
      if r.success then r.value else [ ]
    ) tenantBlocks
  );
  tenantYamlFile = builtins.toFile "readme-tenant-tokens.yaml" (
    lib.concatStringsSep "\n---\n" tenantYamlBlocks
  );

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

  readme-tenant-snippets-evaluate =
    assert lib.length tenantBlocks >= 2;
    assert readmeTenantNames != [ ];
    let
      failed = lib.concatMap failedAssertions (
        lib.filter (b: (evalTenantSnippet b).success) tenantBlocks
      );
    in
    if lib.all (b: (evalTenantSnippet b).success) tenantBlocks && failed == [ ] then
      pkgs.runCommand "docs-readme-tenant-snippets-evaluate" { } "touch $out"
    else
      throw "a README tenant snippet does not evaluate as written (unknown option, missing import) or fails an assertion: ${lib.concatStringsSep " | " failed}";

  # Token-file snippets: valid YAML, only keys the render script accepts, and
  # only tenants the README's own Nix snippet declares.
  readme-tenant-token-yaml-parses =
    assert tenantYamlBlocks != [ ];
    pkgs.runCommand "docs-readme-tenant-token-yaml-parses"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.jq
        ];
      }
      ''
        yq -o=json ea '[.]' ${tenantYamlFile} > docs.json
        jq -e --argjson declared ${lib.escapeShellArg (builtins.toJSON readmeTenantNames)} '
          def known: . as $t | $declared | index([$t]) != null;
          all(.[];
            (.tokens | type == "array")
            and all(.tokens[];
              (keys - ["token", "backends", "tenant", "tenants"] | length == 0)
              and (.token | type == "string")
              and (.tenant == null or (.tenant | known))
              and ((.tenants // []) | if . == "all" then true else all(.[]; known) end)))
        ' docs.json
        touch $out
      '';

  # The ADR links the ADRs it builds on, and the README links the ADR.
  tenants-adr-links-its-related-adrs =
    pkgs.runCommand "docs-tenants-adr-links-its-related-adrs" { }
      ''
        adr=${../docs/decisions/0032-tenants-in-token-files.md}
        for n in 0003 0021 0023 0030 0031; do
          grep -qE "\]\($n-[a-z0-9-]+\.md\)" "$adr" || { echo "ADR 0032 does not link $n" >&2; exit 1; }
        done
        grep -q '0032-tenants-in-token-files.md' ${../README.md} || { echo "README does not link ADR 0032" >&2; exit 1; }
        touch $out
      '';

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
