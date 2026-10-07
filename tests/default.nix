{ pkgs, nixosModule }:
let
  inherit (pkgs) lib;

  groups = {
    assertions = import ./assertions.nix { inherit pkgs nixosModule; };
    listen = import ./listen.nix { inherit pkgs nixosModule; };
    storage = import ./storage.nix { inherit pkgs nixosModule; };
    vmauth = import ./vmauth.nix { inherit pkgs nixosModule; };
    grafana = import ./grafana.nix { inherit pkgs nixosModule; };
    nginx = import ./nginx.nix { inherit pkgs nixosModule; };
    mcp = import ./mcp.nix { inherit pkgs nixosModule; };
    collector = import ./collector.nix { inherit pkgs nixosModule; };
    full = import ./full.nix { inherit pkgs nixosModule; };
  };
in
# Flatten { groupName = { checkName = drv; ... }; ... } into the flat
# attrset `checks.<system>` needs, prefixed so e.g. assertions.nginx-x and
# storage.nginx-x (if that ever collided) can't clash.
lib.foldl' lib.mergeAttrs { } (
  lib.mapAttrsToList (
    groupName: checksInGroup:
    lib.mapAttrs' (checkName: lib.nameValuePair "${groupName}-${checkName}") checksInGroup
  ) groups
)
