{
  description = "NixOS module: a from-scratch VictoriaMetrics/VictoriaLogs/VictoriaTraces stack with vmauth, optional Grafana/nginx/MCP wiring, and a separate fleet-wide collector agent.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
    }:
    {
      nixosModules = {
        default = { ... }: {
          imports = [ ./nixosModule ];
        };
        victoriaStack = ./nixosModule/victoriaStack;
        victoriaCollector = ./nixosModule/victoriaCollector;
      };
    }
    // utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        tests = import ./tests {
          inherit pkgs;
          nixosModule = self;
        };
      in
      {
        packages = {
          mcp-victoriametrics = pkgs.callPackage ./packages/mcp-victoriametrics/package.nix { };
          mcp-victorialogs = pkgs.callPackage ./packages/mcp-victorialogs/package.nix { };
          mcp-victoriatraces = pkgs.callPackage ./packages/mcp-victoriatraces/package.nix { };
          victoriametrics-cluster = pkgs.callPackage ./packages/victoriametrics-cluster/package.nix { };
          optionsDoc = import ./generate-doc.nix { inherit pkgs; };
        };

        apps.gate = {
          type = "app";
          program = nixpkgs.lib.getExe (
            pkgs.writeShellApplication {
              name = "gate";
              # `nix` itself comes from the caller's PATH, so it matches their daemon.
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
                pkgs.nix-eval-jobs
                pkgs.openssh
              ];
              text = builtins.readFile ./scripts/gate.sh;
            }
          );
        };

        checks = tests.checks;
        testSections = tests.groups;

        formatter = pkgs.nixfmt-tree;
      }
    );
}
