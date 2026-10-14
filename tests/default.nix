{ pkgs, nixosModule }:
let
  inherit (pkgs) lib;

  groups = {
    assertions = import ./assertions.nix { inherit pkgs nixosModule; };
    tenants = import ./tenants.nix { inherit pkgs nixosModule; };
    tenant-isolation = import ./tenant-isolation.nix { inherit pkgs nixosModule; };
    tenant-isolation-metrics = import ./tenant-isolation-metrics.nix { inherit pkgs nixosModule; };
    tenant-mcp = import ./tenant-mcp.nix { inherit pkgs nixosModule; };
    listen = import ./listen.nix { inherit pkgs nixosModule; };
    docs = import ./docs.nix { inherit pkgs nixosModule; };
    storage = import ./storage.nix { inherit pkgs nixosModule; };
    cluster-package = import ./victoriametrics-cluster.nix { inherit pkgs nixosModule; };
    cluster-options = import ./metrics-cluster-options.nix { inherit pkgs nixosModule; };
    cluster-units = import ./metrics-cluster-units.nix { inherit pkgs nixosModule; };
    cluster-snapshots = import ./metrics-cluster-snapshots.nix { inherit pkgs nixosModule; };
    cluster-frontends = import ./metrics-cluster-frontends.nix { inherit pkgs nixosModule; };
    vmauth = import ./vmauth.nix { inherit pkgs nixosModule; };
    vmauth-cluster = import ./vmauth-cluster.nix { inherit pkgs nixosModule; };
    grafana = import ./grafana.nix { inherit pkgs nixosModule; };
    grafana-tenant-orgs = import ./grafana-tenant-orgs.nix { inherit pkgs nixosModule; };
    nginx = import ./nginx.nix { inherit pkgs nixosModule; };
    mcp = import ./mcp.nix { inherit pkgs nixosModule; };
    mcp-passthrough = import ./mcp-passthrough.nix { inherit pkgs nixosModule; };
    escaping = import ./escaping.nix { inherit pkgs nixosModule; };
    syslog = import ./syslog.nix { inherit pkgs nixosModule; };
    collector = import ./collector.nix { inherit pkgs nixosModule; };
    testlib = import ./testlib.nix { inherit pkgs nixosModule; };
    restart-backoff = import ./restart-backoff.nix { inherit pkgs nixosModule; };
    full = import ./full.nix { inherit pkgs nixosModule; };
  };
in
# Flatten { groupName = { checkName = drv; ... }; ... } into the flat
# attrset `checks.<system>` needs, prefixed so e.g. assertions-nginx-x and
# storage-nginx-x (if that ever collided) can't clash.
lib.foldl' lib.mergeAttrs { } (
  lib.mapAttrsToList (
    groupName: checksInGroup:
    lib.mapAttrs' (checkName: lib.nameValuePair "${groupName}-${checkName}") checksInGroup
  ) groups
)
