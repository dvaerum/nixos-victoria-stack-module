{ ... }:

{
  imports = [
    ./options.nix
    ./assertions.nix
    ./metrics.nix
    ./metrics-cluster-units.nix
    ./logs.nix
    ./traces.nix
    ./vmauth.nix
    ./grafana.nix
    ./nginx.nix
    ./mcp.nix
  ];
}
