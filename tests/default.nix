{ pkgs, nixosModule }:
let
  inherit (pkgs) lib;

  groups = {
    assertions = import ./assertions.nix { inherit pkgs nixosModule; };
    storage = import ./storage.nix { inherit pkgs nixosModule; };
    vmauth = import ./vmauth.nix { inherit pkgs nixosModule; };
    grafana = import ./grafana.nix { inherit pkgs nixosModule; };
    # Other groups (nginx, mcp, collector, full) land phase-by-phase per
    # PLAN.md's task list, each adding its own import here as its phase
    # lands.
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
