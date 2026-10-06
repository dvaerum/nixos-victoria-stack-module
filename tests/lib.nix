{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  # The real NixOS module tree (not a hand-rolled minimal one): our own
  # module's config.nix files reference genuine NixOS options
  # (systemd.services.*, users.users.*, systemd.tmpfiles.rules) that only
  # exist once nixos/modules/module-list.nix itself is in scope. An earlier,
  # more minimal `lib.evalModules [ assertions.nix ourModule ]` harness
  # worked fine for Phase 2 (before any config.nix touched a real option),
  # but broke the moment metrics.nix landed ("The option `systemd` does not
  # exist") -- using the real module tree is the necessary fix, not a
  # shortcut. This DOES surface some unrelated pre-existing
  # assertions/warnings from base NixOS modules in the raw list (missing
  # `system.stateVersion`, bootloader, etc.) -- callers filter to just our
  # own module's own messages (all of which start with
  # "services.victoriaStack") rather than demanding a literal empty list.
  #
  # Generalized to accept which module tree(s) to evaluate against --
  # previously hardcoded to victoriaStack only, which meant
  # tests/collector.nix had to roll its own near-identical ad-hoc harness
  # the moment it needed an eval-only check (confirmed real drift, not
  # hypothetical: two parallel copies of this exact function existed
  # before this unification). `evalWith`/`evalWithCollector` below are
  # both just `mkEvalWith` applied to a different base module list --
  # one definition, not two to keep in sync by hand.
  mkEvalWith =
    baseModules: extraModule:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs) system;
      modules = baseModules ++ [
        extraModule
        {
          # Silences the stateVersion warning noise, nothing more --
          # doesn't affect our own module's own assertions/warnings.
          system.stateVersion = lib.trivial.release;
        }
      ];
    };

  evalWith = mkEvalWith [ nixosModule.nixosModules.victoriaStack ];
  evalWithCollector = mkEvalWith [ nixosModule.nixosModules.victoriaCollector ];

  ownMessages = lib.filter (lib.hasInfix "services.victoriaStack");

  mkAssertionFiresCheck =
    {
      name,
      module,
      expectMessageSubstring,
    }:
    let
      evaluated = evalWith module;
      failedOwn = ownMessages (
        map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
      );
      matching = builtins.filter (lib.hasInfix expectMessageSubstring) failedOwn;
    in
    pkgs.runCommand "${name}" { } (
      if matching != [ ] then
        "echo OK > $out"
      else
        throw ''
          expected a failed assertion containing "${expectMessageSubstring}" for check "${name}", but none was found.
          Our own failed assertions were: ${builtins.toJSON failedOwn}
        ''
    );

  mkNoAssertionsFireCheck =
    { name, module }:
    let
      evaluated = evalWith module;
      failedOwn = ownMessages (
        map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions)
      );
    in
    pkgs.runCommand "${name}" { } (
      if failedOwn == [ ] then
        "echo OK > $out"
      else
        throw ''
          expected no failed assertions of our own for check "${name}", but found some.
          Failed: ${builtins.toJSON failedOwn}
        ''
    );

  mkWarningFiresCheck =
    {
      name,
      module,
      expectMessageSubstring,
    }:
    let
      evaluated = evalWith module;
      ownWarnings = ownMessages evaluated.config.warnings;
      matching = builtins.filter (lib.hasInfix expectMessageSubstring) ownWarnings;
    in
    pkgs.runCommand "${name}" { } (
      if matching != [ ] then
        "echo OK > $out"
      else
        throw ''
          expected a warning containing "${expectMessageSubstring}" for check "${name}", but none was found.
          Our own warnings were: ${builtins.toJSON ownWarnings}
        ''
    );

  mkNoWarningsCheck =
    { name, module }:
    let
      evaluated = evalWith module;
      ownWarnings = ownMessages evaluated.config.warnings;
    in
    pkgs.runCommand "${name}" { } (
      if ownWarnings == [ ] then
        "echo OK > $out"
      else
        throw ''
          expected no warnings of our own for check "${name}", but found some.
          Our own warnings were: ${builtins.toJSON ownWarnings}
        ''
    );
in
{
  inherit
    evalWith
    evalWithCollector
    mkAssertionFiresCheck
    mkNoAssertionsFireCheck
    mkWarningFiresCheck
    mkNoWarningsCheck
    ;
}
