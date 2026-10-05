{ ... }:

{
  imports = [
    ./options.nix
    ./assertions.nix
    ./metrics.nix
    ./logs.nix
    ./traces.nix
    ./vmauth.nix
    ./grafana.nix
    ./nginx.nix
  ];
}
