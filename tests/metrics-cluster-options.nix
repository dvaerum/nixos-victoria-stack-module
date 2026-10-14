{ pkgs, nixosModule }:

# The option layout, port layout and build-time assertions of the metrics cluster
# (vminsert, vmselect, vmstorage): evaluation only.
let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;
  ownMessages = lib.filter (lib.hasInfix "services.victoriaStack");
  cluster = import ../nixosModule/victoriaStack/metrics-cluster.nix { inherit lib; };

  stack = module: (evalWith { services.victoriaStack = module; }).config;

  failedOf =
    module: ownMessages (map (a: a.message) (lib.filter (a: !a.assertion) (stack module).assertions));

  metricsCluster = extra: {
    metrics = {
      enable = true;
    }
    // extra;
  };

  mkCheck =
    name: ok: detail:
    pkgs.runCommand name { } (if ok then "echo OK > $out" else throw "${name}: ${detail}");

  accepts =
    name: module:
    let
      failed = failedOf module;
    in
    mkCheck name (failed == [ ]) "expected no failed assertions, got ${builtins.toJSON failed}";

  # Exactly one failed assertion, and it contains every given substring.
  rejects =
    name: module: substrings:
    let
      failed = failedOf module;
    in
    mkCheck name (lib.length failed == 1 && lib.all (s: lib.hasInfix s (lib.head failed)) substrings)
      "expected one failed assertion containing ${builtins.toJSON substrings}, got ${builtins.toJSON failed}";

  slug =
    s:
    lib.replaceStrings
      [
        "="
        "/"
        ":"
        "."
        "["
        "]"
        " "
        ";"
        "-"
      ]
      [
        ""
        ""
        ""
        ""
        ""
        ""
        ""
        ""
        ""
      ]
      s;

  table =
    name: checks:
    pkgs.runCommand name { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${name} wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  addrsOf = m: {
    select = m.listenAddress;
    insert = m.insert.listenAddress;
    storage = m.storage.listenAddress;
  };

  # Collisions: the first address is `metrics.insert.listenAddress` unless a row says otherwise.
  collisionRows = {
    "insert-and-a-syslog-tcp-port" = {
      module = metricsCluster { insert.listenAddress = "127.0.0.1:4209"; } // {
        logs = {
          enable = true;
          syslog.tcp = {
            enable = true;
            ipAddress = "127.0.0.1";
            port = 4209;
          };
        };
      };
      mentions = [
        "services.victoriaStack.metrics.insert.listenAddress (127.0.0.1:4209)"
        "services.victoriaStack.logs.syslog.tcp"
      ];
    };
    "storage-and-select-on-one-port" = {
      module = metricsCluster { storage.listenAddress = "127.0.0.1:4201"; };
      mentions = [
        "services.victoriaStack.metrics.listenAddress (127.0.0.1:4201)"
        "services.victoriaStack.metrics.storage.listenAddress (127.0.0.1:4201)"
      ];
    };
    "an-mcp-port-equal-to-insert" = {
      module = metricsCluster {
        mcp.enable = true;
        mcp.listenAddress = "127.0.0.1:4209";
      };
      mentions = [
        "services.victoriaStack.metrics.insert.listenAddress (127.0.0.1:4209)"
        "services.victoriaStack.metrics.mcp.listenAddress (127.0.0.1:4209)"
      ];
    };
    "select-on-the-vminsert-rpc-port" = {
      module = metricsCluster { listenAddress = "127.0.0.1:4211"; };
      mentions = [
        "services.victoriaStack.metrics.listenAddress (127.0.0.1:4211)"
        "vmstorage -vminsertAddr (fixed, internal) (127.0.0.1:4211)"
      ];
    };
    "insert-on-the-vmselect-rpc-port" = {
      module = metricsCluster { insert.listenAddress = "127.0.0.1:4212"; };
      mentions = [
        "services.victoriaStack.metrics.insert.listenAddress (127.0.0.1:4212)"
        "vmstorage -vmselectAddr (fixed, internal) (127.0.0.1:4212)"
      ];
    };
    "storage-on-a-vmauth-door-port" = {
      module = metricsCluster { storage.listenAddress = "127.0.0.1:4204"; };
      mentions = [
        "services.victoriaStack.metrics.storage.listenAddress (127.0.0.1:4204)"
        "services.victoriaStack.vmauth.listenAddress"
      ];
    };
    "wildcard-colon-port-covers-select" = {
      module = metricsCluster { insert.listenAddress = ":4201"; };
      mentions = [
        "services.victoriaStack.metrics.insert.listenAddress (:4201)"
        "services.victoriaStack.metrics.listenAddress (127.0.0.1:4201)"
      ];
    };
    "ipv4-wildcard-covers-the-vminsert-rpc-port" = {
      module = metricsCluster { storage.listenAddress = "0.0.0.0:4211"; };
      mentions = [ "vmstorage -vminsertAddr (fixed, internal)" ];
    };
    "ipv6-wildcard-covers-the-vmselect-rpc-port" = {
      module = metricsCluster { insert.listenAddress = "[::]:4212"; };
      mentions = [ "vmstorage -vmselectAddr (fixed, internal)" ];
    };
    "localhost-clashes-with-loopback" = {
      module = metricsCluster { insert.listenAddress = "localhost:4210"; };
      mentions = [ "services.victoriaStack.metrics.storage.listenAddress (127.0.0.1:4210)" ];
    };
  };

  acceptedRows = {
    "defaults" = metricsCluster { };
    "ipv6-insert" = metricsCluster { insert.listenAddress = "[::1]:4209"; };
    "ipv6-storage-wildcard" = metricsCluster { storage.listenAddress = "[::]:4310"; };
    "wildcard-insert-on-a-free-port" = metricsCluster { insert.listenAddress = "0.0.0.0:4309"; };
    "bare-colon-port-storage" = metricsCluster { storage.listenAddress = ":4310"; };
    "same-port-on-another-address" = metricsCluster { insert.listenAddress = "127.0.0.2:4201"; };
    "a-udp-syslog-port-may-equal-insert" = metricsCluster { } // {
      logs = {
        enable = true;
        syslog.udp = {
          enable = true;
          ipAddress = "127.0.0.1";
          port = 4209;
        };
      };
    };
    "another-ports-for-all-three" = metricsCluster {
      listenAddress = "127.0.0.1:4401";
      insert.listenAddress = "127.0.0.1:4409";
      storage.listenAddress = "127.0.0.1:4410";
    };
  };

  malformedRows = {
    "insert-with-a-semicolon" = {
      module = metricsCluster { insert.listenAddress = "127.0.0.1:4209; rm"; };
      option = "metrics.insert.listenAddress";
    };
    "storage-with-a-space" = {
      module = metricsCluster { storage.listenAddress = "127.0.0.1 :4210"; };
      option = "metrics.storage.listenAddress";
    };
    "insert-with-a-quote" = {
      module = metricsCluster { insert.listenAddress = "\"127.0.0.1\":4209"; };
      option = "metrics.insert.listenAddress";
    };
    "storage-with-a-dollar" = {
      module = metricsCluster { storage.listenAddress = "$HOME:4210"; };
      option = "metrics.storage.listenAddress";
    };
  };

  flagRows =
    let
      common = [
        "-http.pathPrefix=/x"
        "-tls"
        "--tls=true"
        "-tlsCertFile=/run/fake-cert.pem"
        "-httpAuth.username=someone"
        "-httpListenAddr=:4999"
        "--httpListenAddr=:4999"
        "-httpListenAddr.useProxyProtocol=true"
      ];
      bad = {
        select = common ++ [
          "-storageNode=127.0.0.1:4211"
          "--storageNode=127.0.0.1:4211"
        ];
        insert = common ++ [
          "-storageNode=127.0.0.1:4212"
          "--storageNode=127.0.0.1:4212"
        ];
        storage = common ++ [
          "-vminsertAddr=127.0.0.1:1"
          "--vmselectAddr=127.0.0.1:1"
          "-storageDataPath=/x"
          "-retentionPeriod=3"
        ];
      };
      optionOf = {
        select = "metrics.extraFlags";
        insert = "metrics.insert.extraFlags";
        storage = "metrics.storage.extraFlags";
      };
      moduleOf =
        proc: flags:
        metricsCluster (
          if proc == "select" then { extraFlags = flags; } else { ${proc}.extraFlags = flags; }
        );
    in
    lib.concatMapAttrs (
      proc: flags:
      lib.listToAttrs (
        map (
          f:
          lib.nameValuePair "${proc}-rejects${slug f}" {
            module = moduleOf proc [ f ];
            mentions = [
              "services.victoriaStack.${optionOf.${proc}} contains `${f}`"
            ];
          }
        ) flags
      )
    ) bad;

  okFlags = {
    select = [
      "-search.maxUniqueTimeseries=300000"
      "-enableTCP6"
    ];
    insert = [
      "-maxLabelsPerTimeseries=60"
      "-enableTCP6"
    ];
    storage = [
      "-dedup.minScrapeInterval=30s"
      "-enableTCP6"
    ];
  };

in
{
  defaults-table =
    let
      d = module: (stack module).services.victoriaStack.metrics;
      clustered = d (metricsCluster { });
    in
    table "cluster-options-defaults-table" {
      "select is 4201" = clustered.listenAddress == "127.0.0.1:4201";
      "insert is 4209" = clustered.insert.listenAddress == "127.0.0.1:4209";
      "storage is 4210" = clustered.storage.listenAddress == "127.0.0.1:4210";
      "vminsert rpc is 4211" = cluster.rpc.vminsertAddr == "127.0.0.1:4211";
      "vmselect rpc is 4212" = cluster.rpc.vmselectAddr == "127.0.0.1:4212";
      "all five addresses are different" =
        lib.length (lib.unique (lib.attrValues (addrsOf clustered) ++ lib.attrValues cluster.rpc)) == 5;
    };

  # The per-process helper the units will use.
  process-table =
    let
      m =
        (stack (metricsCluster {
          insert.listenAddress = "[::1]:4209";
          storage.extraFlags = [ "-enableTCP6" ];
        })).services.victoriaStack.metrics;
      mDefault = (stack (metricsCluster { })).services.victoriaStack.metrics;
      p = cluster.processes m;
      pDefault = cluster.processes mDefault;
      storageV6 =
        (stack (metricsCluster {
          storage.listenAddress = "[::1]:4210";
        })).services.victoriaStack.metrics;
    in
    table "cluster-options-process-table" {
      "select is the read address" = pDefault.select.listenAddr == "127.0.0.1:4201";
      "insert address" = pDefault.insert.listenAddr == "127.0.0.1:4209";
      "storage address" = pDefault.storage.listenAddr == "127.0.0.1:4210";
      "ipv4 process gets no -enableTCP6" = cluster.tcp6Flags pDefault.insert == [ ];
      "ipv6 insert gets -enableTCP6" = cluster.tcp6Flags p.insert == [ "-enableTCP6" ];
      "ipv6 insert does not leak to select" = cluster.tcp6Flags p.select == [ ];
      "ipv6 insert does not leak to storage" = cluster.tcp6Flags p.storage == [ ];
      "ipv6 storage gets it" =
        cluster.tcp6Flags (cluster.processes storageV6).storage == [ "-enableTCP6" ];
      "the operator's own -enableTCP6 stands" =
        cluster.tcp6Flags {
          listenAddr = "[::1]:4210";
          extraFlags = [ "-enableTCP6" ];
        } == [ ];
      "ownership lists differ per process" =
        pDefault.storage.ownedNames != pDefault.insert.ownedNames
        && pDefault.storage.ownedPrefixes != pDefault.insert.ownedPrefixes;
    };

  # extraFlags: a flag the module renders itself is rejected per process, others pass.
  flags-independent-per-process = rejects "cluster-options-flags-independent-per-process" (
    metricsCluster
      {
        storage.extraFlags = [ "-vminsertAddr=127.0.0.1:1" ];
        insert.extraFlags = [ "-maxLabelsPerTimeseries=60" ];
        extraFlags = [ "-search.maxUniqueTimeseries=300000" ];
      }
  ) [ "services.victoriaStack.metrics.storage.extraFlags contains `-vminsertAddr=127.0.0.1:1`" ];

  flags-both-bad-two-messages =
    let
      failed = failedOf (metricsCluster {
        storage.extraFlags = [ "-vminsertAddr=127.0.0.1:1" ];
        insert.extraFlags = [ "-storageNode=127.0.0.1:1" ];
      });
    in
    mkCheck "cluster-options-flags-both-bad-two-messages" (
      lib.length failed == 2
      && lib.any (lib.hasInfix "metrics.storage.extraFlags contains `-vminsertAddr") failed
      && lib.any (lib.hasInfix "metrics.insert.extraFlags contains `-storageNode") failed
    ) "got ${builtins.toJSON failed}";

  flags-do-nothing-without-metrics = accepts "cluster-options-flags-do-nothing-without-metrics" {
    metrics = {
      enable = false;
      insert.listenAddress = "not an address;";
      storage.listenAddress = "127.0.0.1:4201";
      storage.extraFlags = [ "-vminsertAddr=127.0.0.1:1" ];
    };
  };

  # The cluster replaced the single-node path (docs/decisions/0033): no switch
  # and no second package option survive, and the one package is the cluster
  # one, at the version of the package vmauth is taken from.
  mode-option-is-gone-and-package-is-the-cluster =
    let
      evaluated = evalWith {
        services.victoriaStack = metricsCluster { } // {
          vmauth.enable = true;
        };
      };
      m = evaluated.options.services.victoriaStack.metrics;
      c = evaluated.config.services.victoriaStack;
    in
    table "cluster-options-mode-gone-and-package-is-the-cluster" {
      "no metrics.mode option" = !(m ? mode);
      "no metrics.clusterPackage option" = !(m ? clusterPackage);
      "metrics.package is the cluster package" = c.metrics.package.pname == "victoriametrics-cluster";
      "metrics.package is exactly the flake's package" =
        c.metrics.package.outPath == (pkgs.callPackage ../packages/victoriametrics-cluster/package.nix { })
        .outPath;
      "metrics.package has the version of pkgs.victoriametrics" =
        c.metrics.package.version == pkgs.victoriametrics.version;
      "vmauth.package stays pkgs.victoriametrics" =
        c.vmauth.package.outPath == pkgs.victoriametrics.outPath;
    };
}
// lib.mapAttrs' (
  n: r:
  lib.nameValuePair "collision-${n}" (rejects "cluster-options-collision-${n}" r.module r.mentions)
) collisionRows
// lib.mapAttrs' (
  n: m: lib.nameValuePair "accepts-${n}" (accepts "cluster-options-accepts-${n}" m)
) acceptedRows
// lib.mapAttrs' (
  n: r:
  lib.nameValuePair "malformed-${n}" (
    rejects "cluster-options-malformed-${n}" r.module [
      "services.victoriaStack.${r.option}"
      "is not an"
    ]
  )
) malformedRows
// lib.mapAttrs' (
  n: r: lib.nameValuePair "flag-${n}" (rejects "cluster-options-flag-${n}" r.module r.mentions)
) flagRows
// lib.concatMapAttrs (
  proc: flags:
  lib.listToAttrs (
    map (
      f:
      lib.nameValuePair "flag-${proc}-accepts${slug f}" (
        accepts "cluster-options-flag-${proc}-accepts${slug f}" (
          metricsCluster (
            if proc == "select" then { extraFlags = [ f ]; } else { ${proc}.extraFlags = [ f ]; }
          )
        )
      )
    ) flags
  )
) okFlags
