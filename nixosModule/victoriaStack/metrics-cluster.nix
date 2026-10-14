# The three processes of the metrics cluster (vminsert, vmselect, vmstorage) as
# seen by the assertions and by the unit builder: which address each one binds
# for HTTP, the fixed loopback ports the processes talk to each other on, and
# which extraFlags each one owns. Plain data over the `services.victoriaStack.metrics`
# config, so there is one definition for both.
{ lib }:
let
  listen = import ./listen.nix { inherit lib; };
in
rec {
  # Between the processes, not options: vmstorage listens for vminsert on
  # `vminsertAddr` and for vmselect on `vmselectAddr`; vminsert and vmselect
  # reach it with `-storageNode=<addr>`. Loopback only, because all three run
  # on this host.
  rpc = {
    vminsertAddr = "127.0.0.1:4211";
    vmselectAddr = "127.0.0.1:4212";
  };

  # `cfg` is `config.services.victoriaStack.metrics`.
  #   option      the option subtree whose extraFlags the process takes
  #   listenAddr  its own -httpListenAddr
  #   owned*      the flags the module renders itself, so extraFlags may not
  #               carry them (assertions.nix adds the -tls*/-http.pathPrefix*/
  #               -httpAuth.* prefixes that apply to every process); one list per
  #               process, a flag that is the module's on one is not on the others
  processes = cfg: {
    select = {
      binary = "vmselect";
      option = "metrics";
      listenAddr = cfg.listenAddress;
      inherit (cfg) extraFlags;
      ownedPrefixes = [
        "httpListenAddr"
        "storageNode"
      ];
      ownedNames = [ ];
    };
    insert = {
      binary = "vminsert";
      option = "metrics.insert";
      listenAddr = cfg.insert.listenAddress;
      inherit (cfg.insert) extraFlags;
      ownedPrefixes = [
        "httpListenAddr"
        "storageNode"
      ];
      ownedNames = [ ];
    };
    storage = {
      binary = "vmstorage";
      option = "metrics.storage";
      listenAddr = cfg.storage.listenAddress;
      inherit (cfg.storage) extraFlags;
      ownedPrefixes = [ "httpListenAddr" ];
      ownedNames = [
        "vminsertAddr"
        "vmselectAddr"
        "storageDataPath"
        "retentionPeriod"
      ];
    };
  };

  # `-enableTCP6` for one process: its own -httpListenAddr decides (the RPC
  # ports are IPv4 loopback), and the operator's own flag in that process's
  # extraFlags stands.
  tcp6Flags =
    proc:
    listen.tcp6Flags {
      addrs = [ proc.listenAddr ];
      inherit (proc) extraFlags;
    };

  # Every address the cluster binds, labelled for the collision check. The
  # read API (`metrics.listenAddress`) is listed by the caller.
  extraListeners = cfg: [
    {
      name = "services.victoriaStack.metrics.insert.listenAddress";
      addr = cfg.insert.listenAddress;
    }
    {
      name = "services.victoriaStack.metrics.storage.listenAddress";
      addr = cfg.storage.listenAddress;
    }
    {
      name = "vmstorage -vminsertAddr (fixed, internal)";
      addr = rpc.vminsertAddr;
    }
    {
      name = "vmstorage -vmselectAddr (fixed, internal)";
      addr = rpc.vmselectAddr;
    }
  ];
}
