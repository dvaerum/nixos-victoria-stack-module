{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  collectorModule = nixosModule.nixosModules.victoriaCollector;

  collectorConfig = {
    system.stateVersion = lib.trivial.release;
    services.victoriaCollector = {
      metrics.enable = true;
      traces.enable = true;
      hostType = "server";
      writeEndpoint = "http://127.0.0.1:4204";
    };
  };

  # The module evaluated against another nixpkgs than the one the rest of the
  # tests use.
  evalAgainst =
    nixpkgsSrc:
    import (nixpkgsSrc + "/nixos/lib/eval-config.nix") {
      inherit (pkgs) system;
      modules = [
        collectorModule
        collectorConfig
      ];
    };

  withCheckConfig = evalAgainst nixosModule.inputs.nixpkgs-alloy-check;
  withoutCheckConfig = evalAgainst pkgs.path;
in
{
  # nixpkgs' services.alloy.checkConfig runs `alloy validate` with no
  # --stability.level, which rejects otelcol.storage.file. Building the checks
  # the system carries is what a consumer's `nixos-rebuild build` does.
  system-checks-pass-on-a-nixpkgs-with-alloy-checkconfig =
    assert withCheckConfig.options.services.alloy ? checkConfig;
    pkgs.runCommand "system-checks-pass-with-alloy-checkconfig" {
      checks = withCheckConfig.config.system.checks;
    } "echo OK > $out";

  # The option must stay optional: nixpkgs releases without it must evaluate.
  evaluates-on-a-nixpkgs-without-alloy-checkconfig =
    assert !(withoutCheckConfig.options.services.alloy ? checkConfig);
    pkgs.runCommand "evaluates-without-alloy-checkconfig" {
      checks = withoutCheckConfig.config.system.checks;
      etc = withoutCheckConfig.config.environment.etc."alloy/config.alloy".source;
    } "echo OK > $out";
}
