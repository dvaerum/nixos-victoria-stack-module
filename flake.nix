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
        packages = {
          mcp-victoriametrics = pkgs.callPackage ./packages/mcp-victoriametrics/package.nix { };
          mcp-victorialogs = pkgs.callPackage ./packages/mcp-victorialogs/package.nix { };
          mcp-victoriatraces = pkgs.callPackage ./packages/mcp-victoriatraces/package.nix { };
          optionsDoc = import ./generate-doc.nix { inherit pkgs; };
        };

        checks = nixosTests;

        formatter = pkgs.nixfmt-tree;
      }
    );
}
