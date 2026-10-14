{ pkgs, nixosModule }:

# The declared tenants table: names, number ranges and the build-time
# assertions. How token entries use them is in tenant-isolation.nix.
let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith mkAssertionFiresCheck mkNoAssertionsFireCheck;

  tenantsModule = tenants: { services.victoriaStack.tenants = tenants; };
  tenant = accountId: { inherit accountId; };
  repeat = n: c: lib.concatStrings (lib.genList (_: c) n);

  acceptCases = {
    empty-table = { };
    one-character-name.a = tenant 1;
    sixty-three-character-name.${"a" + repeat 61 "b" + "c"} = tenant 1;
    digits-and-inner-hyphen.a1-b2 = tenant 1;
    all-digits-name."123" = tenant 1;
    account-zero-with-project-one.t = {
      accountId = 0;
      projectId = 1;
    };
    maximum-numbers.t = {
      accountId = 4294967295;
      projectId = 4294967295;
    };
    same-account-different-projects = {
      a = tenant 5;
      b = {
        accountId = 5;
        projectId = 1;
      };
    };
    two-different-pairs = {
      a = tenant 1;
      b = tenant 2;
    };
    name-containing-all.all-hands = tenant 1;
  };

  # Each case: the table and a fragment the failed assertion must contain.
  nameRule = name: "services.victoriaStack.tenants: \"${name}\" is not a valid tenant name";
  rejectCases = {
    uppercase = {
      tenants.Foo = tenant 1;
      fragment = nameRule "Foo";
    };
    underscore = {
      tenants.a_b = tenant 1;
      fragment = nameRule "a_b";
    };
    leading-hyphen = {
      tenants."-a" = tenant 1;
      fragment = nameRule "-a";
    };
    trailing-hyphen = {
      tenants."a-" = tenant 1;
      fragment = nameRule "a-";
    };
    single-hyphen = {
      tenants."-" = tenant 1;
      fragment = nameRule "-";
    };
    sixty-four-characters = {
      tenants.${repeat 64 "a"} = tenant 1;
      fragment = nameRule (repeat 64 "a");
    };
    empty-name = {
      tenants."" = tenant 1;
      fragment = nameRule "";
    };
    space-in-name = {
      tenants."a b" = tenant 1;
      fragment = nameRule "a b";
    };
    dot-in-name = {
      tenants."a.b" = tenant 1;
      fragment = nameRule "a.b";
    };
    reserved-all = {
      tenants.all = tenant 1;
      fragment = "services.victoriaStack.tenants.all: \"all\" is reserved";
    };
    duplicate-pair = {
      tenants = {
        alpha = tenant 3;
        beta = tenant 3;
      };
      fragment = "services.victoriaStack.tenants.alpha and services.victoriaStack.tenants.beta both use accountId 3, projectId 0";
    };
    duplicate-pair-explicit-project = {
      tenants = {
        alpha = {
          accountId = 3;
          projectId = 9;
        };
        beta = {
          accountId = 3;
          projectId = 9;
        };
      };
      fragment = "both use accountId 3, projectId 9";
    };
    default-tenant-alias = {
      tenants.zero = tenant 0;
      fragment = "services.victoriaStack.tenants.zero has accountId 0 and projectId 0";
    };
  };

  # The type refuses these before any assertion runs. tryEval tells a refusal
  # (success = false) apart from a value that evaluates.
  typeAccepts =
    attrs:
    (builtins.tryEval (
      builtins.deepSeq
        (evalWith (tenantsModule {
          t = attrs;
        })).config.services.victoriaStack.tenants.t
        true
    )).success;
  typeCases = {
    account-id-above-32-bit = {
      accountId = 4294967296;
    };
    account-id-negative = {
      accountId = -1;
    };
    account-id-string = {
      accountId = "7";
    };
    account-id-float = {
      accountId = 1.5;
    };
    project-id-above-32-bit = {
      accountId = 1;
      projectId = 4294967296;
    };
    project-id-negative = {
      accountId = 1;
      projectId = -1;
    };
    account-id-missing = { };
    unknown-field = {
      accountId = 1;
      mcp = true;
    };
  };

  typeRefusals =
    let
      wrongly = lib.filterAttrs (_: attrs: typeAccepts attrs) typeCases;
    in
    pkgs.runCommand "tenants-type-refuses-bad-numbers-and-unknown-fields" { } (
      if typeAccepts { accountId = 4294967295; } && typeAccepts { accountId = 0; } && wrongly == { } then
        "echo OK > $out"
      else
        throw "accepted but should be refused: ${builtins.toJSON (lib.attrNames wrongly)}"
    );

  projectDefault =
    let
      value =
        (evalWith (tenantsModule {
          t = tenant 1;
        })).config.services.victoriaStack.tenants.t.projectId;
    in
    pkgs.runCommand "tenants-project-id-defaults-to-zero" { } (
      if value == 0 then "echo OK > $out" else throw "projectId defaulted to ${toString value}"
    );
in
lib.mapAttrs' (
  n: tenants:
  lib.nameValuePair "accepts-${n}" (mkNoAssertionsFireCheck {
    name = "tenants-accepts-${n}";
    module = tenantsModule tenants;
  })
) acceptCases
// lib.mapAttrs' (
  n: c:
  lib.nameValuePair "rejects-${n}" (mkAssertionFiresCheck {
    name = "tenants-rejects-${n}";
    module = tenantsModule c.tenants;
    expectMessageSubstring = c.fragment;
  })
) rejectCases
// {
  type-refuses-bad-numbers-and-unknown-fields = typeRefusals;
  project-id-defaults-to-zero = projectDefault;
}
