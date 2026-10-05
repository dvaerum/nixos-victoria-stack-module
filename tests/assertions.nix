{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  # Deliberately NOT the full `lib.nixosSystem`/`eval-config.nix` machinery:
  # that pulls in nixos/modules/module-list.nix wholesale, which produces a
  # wall of unrelated assertions (bootloader, filesystems, etc.) for a
  # minimal test module and would drown out the one assertion each of these
  # checks actually cares about. `assertions`/`warnings` as options are
  # defined in the small, standalone lib/modules/generic/assertions.nix --
  # evaluating just that plus our own module is enough to inspect
  # `config.assertions` as data, and is near-instant (pure evaluation, no
  # derivation realization), matching this group's own design goal (see
  # PLAN.md's `assertions` test group: fast, eval-only, no container boot).
  evalWith =
    extraModule:
    lib.evalModules {
      modules = [
        (pkgs.path + "/lib/modules/generic/assertions.nix")
        nixosModule.nixosModules.victoriaStack
        extraModule
      ];
    };

  # A `checks`-compatible derivation: builds successfully (passes) when a
  # failed assertion whose message contains `expectMessageSubstring` is
  # present in `config.assertions`; fails the build (with the full
  # assertions list for debugging) otherwise.
  mkAssertionFiresCheck =
    {
      name,
      module,
      expectMessageSubstring,
    }:
    let
      evaluated = evalWith module;
      matching = builtins.filter (
        a: !a.assertion && lib.hasInfix expectMessageSubstring a.message
      ) evaluated.config.assertions;
    in
    pkgs.runCommand "assertions-${name}" { } (
      if matching != [ ] then
        "echo OK > $out"
      else
        throw ''
          expected a failed assertion containing "${expectMessageSubstring}" for check "${name}", but none was found.
          Actual config.assertions: ${builtins.toJSON evaluated.config.assertions}
        ''
    );

  # The inverse: builds successfully when NO failed assertion exists at all
  # -- the control case confirming a legitimate configuration doesn't
  # spuriously trip either assertion.
  mkNoAssertionsFireCheck =
    { name, module }:
    let
      evaluated = evalWith module;
      failed = builtins.filter (a: !a.assertion) evaluated.config.assertions;
    in
    pkgs.runCommand "assertions-${name}" { } (
      if failed == [ ] then
        "echo OK > $out"
      else
        throw ''
          expected no failed assertions for check "${name}", but found some.
          Failed: ${builtins.toJSON failed}
        ''
    );
in
{
  nginx-requires-vmauth = mkAssertionFiresCheck {
    name = "nginx-requires-vmauth";
    expectMessageSubstring = "vmauth";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        # Forced off: vmauth would otherwise auto-enable (mkDefault true)
        # whenever a backend is on, which is exactly the case this
        # assertion needs to NOT be satisfied by auto-enable alone.
        vmauth.enable = lib.mkForce false;
        nginx.enable = true;
      };
    };
  };

  mcp-requires-own-backend = mkAssertionFiresCheck {
    name = "mcp-requires-own-backend";
    expectMessageSubstring = "mcp";
    module = {
      services.victoriaStack.metrics = {
        enable = false;
        mcp.enable = true;
      };
    };
  };

  # Control: nginx + vmauth both on, mcp + its own backend both on -- no
  # assertion should fire.
  valid-configuration-no-assertions = mkNoAssertionsFireCheck {
    name = "valid-configuration-no-assertions";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        vmauth.enable = true;
        nginx.enable = true;
      };
    };
  };

  # Control: mcp.enable = true with vmauth.enable = false while the mcp's
  # own backend IS enabled -- this is a legitimate, deliberately
  # NOT-asserted-against configuration (see docs/decisions/0002), so it
  # must NOT trip the mcp-requires-own-backend assertion (only the
  # mcp-requires-own-backend one, scoped to the metrics.enable=false case
  # above, should ever fire for mcp).
  mcp-without-vmauth-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "mcp-without-vmauth-is-not-an-assertion-failure";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        mcp.enable = true;
      };
      services.victoriaStack.vmauth.enable = lib.mkForce false;
    };
  };
}
