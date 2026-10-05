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

        nixosTests = import ./tests {
          inherit pkgs;
          nixosModule = self;
        };
      in
      {
        checks = nixosTests;

        formatter = pkgs.nixfmt-tree;
      }
    );
}
