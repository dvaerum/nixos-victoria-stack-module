{ pkgs, nixosModule }:

# `logs.syslog.listeners` (docs/decisions/0035): any number of named syslog
# listeners, each with its own address, port and tenant. The slots (udp, tcp,
# tls) are sugar over the same list; tests/syslog.nix keeps covering them.
let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    evalWith
    mkCert
    syslogSend
    ;

  mkTableCheck =
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

  tenants = {
    team-a.accountId = 1;
    team-b = {
      accountId = 2;
      projectId = 5;
    };
  };

  # The stack with `syslog` on it; `extra` is merged over services.victoriaStack.
  stack =
    syslog: extra:
    evalWith {
      services.victoriaStack = lib.recursiveUpdate {
        inherit tenants;
        logs = {
          enable = true;
          inherit syslog;
        };
      } extra;
    };

  execStart = e: e.config.systemd.services.victorialogs.serviceConfig.ExecStart;
  unquote = f: builtins.unsafeDiscardStringContext (lib.removeSuffix "'" (lib.removePrefix "'" f));
  flagsOf =
    syslog:
    map unquote (
      lib.filter (lib.hasInfix "-syslog.") (lib.splitString " " (execStart (stack syslog { })))
    );
  flagsWith = pre: syslog: lib.filter (lib.hasPrefix pre) (flagsOf syslog);

  failedOf =
    e:
    lib.filter (lib.hasInfix "services.victoriaStack") (
      map (a: a.message) (lib.filter (a: !a.assertion) e.config.assertions)
    );
  fires =
    syslog: extra: sub:
    lib.any (lib.hasInfix sub) (failedOf (stack syslog extra));
  quiet = syslog: extra: failedOf (stack syslog extra) == [ ];
  # Warnings about syslog only: the stack raises others of its own.
  syslogWarnings =
    syslog: extra:
    lib.filter (lib.hasInfix "syslog") (
      lib.filter (lib.hasInfix "services.victoriaStack") (stack syslog extra).config.warnings
    );

  certs = {
    certFile = "/run/fake-cert.pem";
    keyFile = "/run/fake-key.pem";
  };
  udp =
    ip: extra:
    {
      transport = "udp";
      ipAddress = ip;
    }
    // extra;
  tcp =
    ip: extra:
    {
      transport = "tcp";
      ipAddress = ip;
    }
    // extra;
  tls =
    ip: extra:
    {
      transport = "tls";
      ipAddress = ip;
    }
    // certs
    // extra;
  withTenant = t: { tenant = t; };

  # The fleet of the module's own documentation: two teams, same transports,
  # different addresses.
  fleet = {
    team-a-udp = udp "192.0.2.10" (withTenant "team-a");
    team-b-udp = udp "192.0.2.11" (withTenant "team-b");
    team-a-tcp = tcp "192.0.2.10" ({ port = 1514; } // withTenant "team-a");
    team-b-tcp = tcp "192.0.2.11" ({ port = 1514; } // withTenant "team-b");
    team-b-tls = tls "192.0.2.11" (withTenant "team-b");
  };
  fields = ''{"source":"syslog"}'';
in
{
  # --- options ---

  listener-option-defaults =
    let
      cfg =
        (stack {
          listeners = {
            u = udp "192.0.2.10" { };
            t = tcp "192.0.2.10" { };
            s = tls "192.0.2.10" { };
          };
        } { }).config.services.victoriaStack.logs.syslog.listeners;
    in
    mkTableCheck "syslog-listeners-option-defaults" {
      "no listeners by default" =
        (evalWith {
          services.victoriaStack.logs.enable = true;
        }).config.services.victoriaStack.logs.syslog.listeners == { };
      "udp port 514" = cfg.u.port == 514;
      "tcp port 514" = cfg.t.port == 514;
      "tls port 6514" = cfg.s.port == 6514;
      "extraFields default" = cfg.u.extraFields == { source = "syslog"; };
      "tenant null" = cfg.u.tenant == null;
      "openFirewall off" = !cfg.u.openFirewall && !cfg.t.openFirewall && !cfg.s.openFirewall;
      "exposure warning on" = !cfg.u.suppressExposureWarning;
      "no listener changes the unit" =
        flagsOf { } == [ ] && !(lib.hasInfix "-syslog." (execStart (stack { } { })));
      "transport has no default" =
        !(builtins.tryEval (
          builtins.deepSeq
            (stack {
              listeners.x = {
                ipAddress = "192.0.2.10";
              };
            } { }).config.systemd.services.victorialogs.serviceConfig.ExecStart
            true
        )).success;
      "transport must be udp, tcp or tls" =
        !(builtins.tryEval (
          builtins.deepSeq
            (stack {
              listeners.x = {
                transport = "sctp";
                ipAddress = "192.0.2.10";
              };
            } { }).config.systemd.services.victorialogs.serviceConfig.ExecStart
            true
        )).success;
    };

  # --- rendering ---

  one-listener-per-transport-renders-the-slot-flags =
    let
      flags = flagsOf {
        listeners = {
          dev-udp = udp "192.0.2.10" { };
          dev-tcp = tcp "192.0.2.10" { };
          dev-tls = tls "192.0.2.10" { };
        };
      };
    in
    mkTableCheck "syslog-listeners-one-per-transport" {
      "exact flags" =
        flags == [
          "-syslog.listenAddr.tcp=192.0.2.10:514"
          "-syslog.listenAddr.tcp=192.0.2.10:6514"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.tls=false"
          "-syslog.tls=true"
          "-syslog.tlsCertFile="
          "-syslog.tlsCertFile=%d/syslog-tls-cert-dev-tls"
          "-syslog.tlsKeyFile="
          "-syslog.tlsKeyFile=%d/syslog-tls-key-dev-tls"
          "-syslog.listenAddr.udp=192.0.2.10:514"
          "-syslog.extraFields.udp=${fields}"
        ];
      "an IPv6 address is bracketed and turns on -enableTCP6" =
        let
          e = stack { listeners.v6 = udp "2001:db8::1" { port = 5514; }; } { };
        in
        lib.hasInfix "-syslog.listenAddr.udp=[2001:db8::1]:5514" (execStart e)
        && lib.hasInfix "-enableTCP6" (execStart e);
      "empty extraFields renders no flag" =
        flagsOf { listeners.q = udp "192.0.2.10" { extraFields = { }; }; } == [
          "-syslog.listenAddr.udp=192.0.2.10:514"
        ];
      "extraFields are JSON, escaped for systemd" =
        flagsWith "-syslog.extraFields." {
          listeners.q = udp "192.0.2.10" {
            extraFields = {
              note = "50%h$HOME";
            };
          };
        } == [ ''-syslog.extraFields.udp={"note":"50%%h$$HOME"}'' ];
    };

  # Entry N of every array of a transport belongs to the same listener.
  two-teams-render-aligned-positional-arrays =
    let
      flags = flagsOf { listeners = fleet; };
      arr =
        name:
        map (lib.removePrefix "-syslog.${name}=") (flagsWith "-syslog.${name}=" { listeners = fleet; });
      addrOwner = {
        "192.0.2.10:1514" = "team-a-tcp";
        "192.0.2.11:1514" = "team-b-tcp";
        "192.0.2.11:6514" = "team-b-tls";
        "192.0.2.10:514" = "team-a-udp";
        "192.0.2.11:514" = "team-b-udp";
      };
      tenantIdOf = {
        team-a = "1:0";
        team-b = "2:5";
      };
      alignedFor =
        transport:
        let
          addrs = arr "listenAddr.${transport}";
          ids = arr "tenantID.${transport}";
        in
        lib.length addrs == lib.length ids
        && lib.all (i: lib.elemAt ids i == tenantIdOf.${fleet.${addrOwner.${lib.elemAt addrs i}}.tenant}) (
          lib.range 0 (lib.length addrs - 1)
        );
    in
    mkTableCheck "syslog-listeners-aligned-arrays" {
      "exact flags" =
        flags == [
          "-syslog.listenAddr.tcp=192.0.2.10:1514"
          "-syslog.listenAddr.tcp=192.0.2.11:1514"
          "-syslog.listenAddr.tcp=192.0.2.11:6514"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.tenantID.tcp=1:0"
          "-syslog.tenantID.tcp=2:5"
          "-syslog.tenantID.tcp=2:5"
          "-syslog.tls=false"
          "-syslog.tls=false"
          "-syslog.tls=true"
          "-syslog.tlsCertFile="
          "-syslog.tlsCertFile="
          "-syslog.tlsCertFile=%d/syslog-tls-cert-team-b-tls"
          "-syslog.tlsKeyFile="
          "-syslog.tlsKeyFile="
          "-syslog.tlsKeyFile=%d/syslog-tls-key-team-b-tls"
          "-syslog.listenAddr.udp=192.0.2.10:514"
          "-syslog.listenAddr.udp=192.0.2.11:514"
          "-syslog.extraFields.udp=${fields}"
          "-syslog.extraFields.udp=${fields}"
          "-syslog.tenantID.udp=1:0"
          "-syslog.tenantID.udp=2:5"
        ];
      "tcp: entry N of the tenant array is the tenant of address N" = alignedFor "tcp";
      "udp: entry N of the tenant array is the tenant of address N" = alignedFor "udp";
      "every tcp array has one entry per tcp listener" = lib.all (n: lib.length (arr n) == 3) [
        "listenAddr.tcp"
        "extraFields.tcp"
        "tenantID.tcp"
        "tls"
        "tlsCertFile"
        "tlsKeyFile"
      ];
      "the tls arrays are not rendered for udp" =
        !(lib.any (lib.hasSuffix ".udp") (
          lib.filter (lib.hasPrefix "-syslog.tls") (flagsOf {
            listeners = fleet;
          })
        ));
    };

  # tls listeners are tcp listeners with TLS on: they share the tcp arrays with
  # plain tcp ones, so the order of names decides the positions.
  mixed-plain-and-tls-tcp-stay-aligned =
    let
      flags =
        names:
        flagsOf {
          listeners = {
            ${names.tls} = tls "192.0.2.10" { port = 6514; } // withTenant "team-a";
            ${names.plain} = tcp "192.0.2.11" { port = 5514; } // withTenant "team-b";
          };
        };
    in
    mkTableCheck "syslog-listeners-mixed-tcp-tls" {
      "tls name first" =
        flags {
          tls = "a-tls";
          plain = "b-plain";
        } == [
          "-syslog.listenAddr.tcp=192.0.2.10:6514"
          "-syslog.listenAddr.tcp=192.0.2.11:5514"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.tenantID.tcp=1:0"
          "-syslog.tenantID.tcp=2:5"
          "-syslog.tls=true"
          "-syslog.tls=false"
          "-syslog.tlsCertFile=%d/syslog-tls-cert-a-tls"
          "-syslog.tlsCertFile="
          "-syslog.tlsKeyFile=%d/syslog-tls-key-a-tls"
          "-syslog.tlsKeyFile="
        ];
      "plain name first" =
        flags {
          tls = "b-tls";
          plain = "a-plain";
        } == [
          "-syslog.listenAddr.tcp=192.0.2.11:5514"
          "-syslog.listenAddr.tcp=192.0.2.10:6514"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.extraFields.tcp=${fields}"
          "-syslog.tenantID.tcp=2:5"
          "-syslog.tenantID.tcp=1:0"
          "-syslog.tls=false"
          "-syslog.tls=true"
          "-syslog.tlsCertFile="
          "-syslog.tlsCertFile=%d/syslog-tls-cert-b-tls"
          "-syslog.tlsKeyFile="
          "-syslog.tlsKeyFile=%d/syslog-tls-key-b-tls"
        ];
      "no tls listener: no tls array" =
        !(lib.any (lib.hasPrefix "-syslog.tls") (flagsOf {
          listeners = {
            a = tcp "192.0.2.10" { };
            b = tcp "192.0.2.11" { };
          };
        }));
    };

  tenant-on-one-of-several-listeners =
    let
      two = flagsWith "-syslog.tenantID." {
        listeners = {
          a = udp "192.0.2.10" { };
          b = udp "192.0.2.11" (withTenant "team-b");
          c = udp "192.0.2.12" { };
        };
      };
    in
    mkTableCheck "syslog-listeners-tenant-on-one" {
      "blank entries are 0:0, in position" =
        two == [
          "-syslog.tenantID.udp=0:0"
          "-syslog.tenantID.udp=2:5"
          "-syslog.tenantID.udp=0:0"
        ];
      "no tenant anywhere: no tenant flag" =
        flagsWith "-syslog.tenantID." {
          listeners = {
            a = udp "192.0.2.10" { };
            b = tcp "192.0.2.11" { };
          };
        } == [ ];
      "a tenant on udp adds nothing to tcp" =
        flagsWith "-syslog.tenantID." {
          listeners = {
            a = udp "192.0.2.10" (withTenant "team-a");
            b = tcp "192.0.2.11" { };
          };
        } == [ "-syslog.tenantID.udp=1:0" ];
    };

  # The slots and the listeners are one mechanism: the same configuration
  # written either way renders the same unit.
  slot-and-listener-render-byte-identical-units =
    let
      viaSlots = stack {
        udp = {
          enable = true;
          ipAddress = "192.0.2.10";
          port = 5514;
          tenant = "team-a";
          extraFields = {
            source = "edge";
          };
        };
        tcp = {
          enable = true;
          ipAddress = "192.0.2.10";
          port = 5515;
        };
        tls = {
          enable = true;
          ipAddress = "192.0.2.10";
          tenant = "team-b";
        }
        // certs;
      } { };
      viaListeners = stack {
        listeners = {
          udp = udp "192.0.2.10" {
            port = 5514;
            tenant = "team-a";
            extraFields = {
              source = "edge";
            };
          };
          tcp = tcp "192.0.2.10" { port = 5515; };
          tls = tls "192.0.2.10" { tenant = "team-b"; };
        };
      } { };
      unit = e: e.config.systemd.services.victorialogs;
    in
    mkTableCheck "syslog-listeners-slot-equivalence" {
      "ExecStart is byte-identical" = execStart viaSlots == execStart viaListeners;
      "the flags are present" =
        lib.hasInfix "%d/syslog-tls-cert" (execStart viaSlots)
        && lib.hasInfix "-syslog.tenantID.udp=1:0" (execStart viaSlots);
      "LoadCredential is identical" =
        (unit viaSlots).serviceConfig.LoadCredential == (unit viaListeners).serviceConfig.LoadCredential;
      "the whole service config is identical" =
        (unit viaSlots).serviceConfig == (unit viaListeners).serviceConfig;
    };

  # Order: the slots (udp, tcp, tls) first, then the listeners by name.
  order-is-slots-then-listeners-by-name =
    let
      addrs =
        syslog:
        map (lib.removePrefix "-syslog.listenAddr.tcp=") (flagsWith "-syslog.listenAddr.tcp=" syslog);
      named = n1: n2: {
        listeners = {
          ${n1} = tcp "192.0.2.1" { };
          ${n2} = tcp "192.0.2.2" { };
        };
      };
    in
    mkTableCheck "syslog-listeners-order" {
      "sorted by name" =
        addrs (named "a" "b") == [
          "192.0.2.1:514"
          "192.0.2.2:514"
        ];
      "renaming changes the order" =
        addrs (named "z" "b") == [
          "192.0.2.2:514"
          "192.0.2.1:514"
        ];
      "digits sort before letters" =
        addrs (named "a" "1") == [
          "192.0.2.2:514"
          "192.0.2.1:514"
        ];
      "slots come before listeners, whatever the names" =
        addrs {
          tcp = {
            enable = true;
            ipAddress = "192.0.2.9";
          };
          listeners.aaa = tcp "192.0.2.1" { };
        } == [
          "192.0.2.9:514"
          "192.0.2.1:514"
        ];
      "the tls slot sits after the tcp slot and before the listeners" =
        addrs {
          tls = {
            enable = true;
            ipAddress = "192.0.2.8";
          }
          // certs;
          tcp = {
            enable = true;
            ipAddress = "192.0.2.9";
          };
          listeners.aaa = tcp "192.0.2.1" { };
        } == [
          "192.0.2.9:514"
          "192.0.2.8:6514"
          "192.0.2.1:514"
        ];
    };

  # --- the unit: credentials, capability, firewall ---

  tls-listeners-get-their-own-credentials =
    let
      unit =
        (stack {
          listeners = {
            one = tls "192.0.2.10" {
              certFile = "/run/s/one.pem";
              keyFile = "/run/s/one.key";
            };
            two = tls "192.0.2.11" {
              port = 7514;
              certFile = "/run/s/50%two.pem";
              keyFile = "/run/s/two.key";
            };
          };
        } { }).config.systemd;
    in
    mkTableCheck "syslog-listeners-credentials" {
      "one credential pair per tls listener, % escaped" =
        unit.services.victorialogs.serviceConfig.LoadCredential == [
          "syslog-tls-cert-one:/run/s/one.pem"
          "syslog-tls-cert-two:/run/s/50%%two.pem"
          "syslog-tls-key-one:/run/s/one.key"
          "syslog-tls-key-two:/run/s/two.key"
        ];
      "a path unit watches every file" =
        lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "victorialogs-secret-watch-" n) unit.paths) == [
          "victorialogs-secret-watch-syslog-tls-cert-one"
          "victorialogs-secret-watch-syslog-tls-cert-two"
          "victorialogs-secret-watch-syslog-tls-key-one"
          "victorialogs-secret-watch-syslog-tls-key-two"
        ];
      "no tls listener: no credential" =
        !(
          (stack { listeners.a = tcp "192.0.2.10" { }; } { })
          .config.systemd.services.victorialogs.serviceConfig
            ? LoadCredential
        );
    };

  low-port-from-a-listener-gives-the-capability =
    let
      sc = syslog: (stack syslog { }).config.systemd.services.victorialogs.serviceConfig;
      low = sc { listeners.dev = udp "192.0.2.10" { port = 514; }; };
      lowTls = sc { listeners.dev = tls "192.0.2.10" { port = 443; }; };
      high = sc {
        listeners = {
          a = udp "192.0.2.10" { port = 1024; };
          b = tcp "192.0.2.10" { port = 5514; };
        };
      };
      oneOfMany = sc {
        listeners = {
          a = udp "192.0.2.10" { port = 5514; };
          b = tcp "192.0.2.10" { port = 5514; };
          c = udp "192.0.2.11" { port = 514; };
        };
      };
    in
    mkTableCheck "syslog-listeners-low-port-capability" {
      "udp 514" =
        (low.AmbientCapabilities or null) == [ "CAP_NET_BIND_SERVICE" ]
        && (low.PrivateUsers or null) == false;
      "bounding set" = low.CapabilityBoundingSet == [ "CAP_NET_BIND_SERVICE" ];
      "tls 443" = (lowTls.AmbientCapabilities or null) == [ "CAP_NET_BIND_SERVICE" ];
      "one low port among high ones" =
        (oneOfMany.AmbientCapabilities or null) == [ "CAP_NET_BIND_SERVICE" ];
      "port 1024 and up keep the empty set" =
        !(high ? AmbientCapabilities) && high.CapabilityBoundingSet == "" && high.PrivateUsers == true;
      "no listener: the empty set" =
        let
          none = sc { };
        in
        !(none ? AmbientCapabilities) && none.CapabilityBoundingSet == "";
    };

  open-firewall-opens-exactly-the-listeners-port =
    let
      fw =
        syslog:
        let
          c = (stack syslog { }).config.networking.firewall;
        in
        {
          tcp = c.allowedTCPPorts;
          udp = c.allowedUDPPorts;
        };
      open = {
        openFirewall = true;
      };
    in
    mkTableCheck "syslog-listeners-open-firewall" {
      "default opens nothing" =
        fw { listeners = fleet; } == {
          tcp = [ ];
          udp = [ ];
        };
      "udp opens a udp port" =
        fw { listeners.a = udp "192.0.2.10" (open // { port = 5514; }); } == {
          tcp = [ ];
          udp = [ 5514 ];
        };
      "tcp opens a tcp port" =
        fw { listeners.a = tcp "192.0.2.10" (open // { port = 5515; }); } == {
          tcp = [ 5515 ];
          udp = [ ];
        };
      "tls opens a tcp port" =
        fw { listeners.a = tls "192.0.2.10" open; } == {
          tcp = [ 6514 ];
          udp = [ ];
        };
      "only the listeners that ask" =
        fw {
          listeners = {
            a = udp "192.0.2.10" (open // { port = 5514; });
            b = udp "192.0.2.11" { port = 5515; };
            c = tcp "192.0.2.10" (open // { port = 5516; });
            d = tcp "192.0.2.11" { port = 5517; };
          };
        } == {
          tcp = [ 5516 ];
          udp = [ 5514 ];
        };
    };

  # --- assertions ---

  listener-names-are-validated =
    let
      bad = name: fires { listeners.${name} = udp "192.0.2.10" { }; } { } "is not a valid listener name";
    in
    mkTableCheck "syslog-listeners-bad-names" {
      "upper case" = bad "Team-A";
      "underscore" = bad "team_a";
      "leading hyphen" = bad "-a";
      "trailing hyphen" = bad "a-";
      "space" = bad "a b";
      "64 characters" = bad (lib.concatStrings (lib.genList (_: "a") 64));
      "the message names the listener" = fires {
        listeners."Team-A" = udp "192.0.2.10" { };
      } { } ''"Team-A" is not a valid listener name'';
      "lower case, digits and hyphens are fine" = quiet {
        listeners = {
          team-1-a = udp "192.0.2.10" { port = 5514; };
          "9" = udp "192.0.2.11" { port = 5514; };
        };
      } { };
    };

  listener-names-must-differ-from-enabled-slots =
    let
      slotTcp = {
        enable = true;
        ipAddress = "192.0.2.10";
      };
    in
    mkTableCheck "syslog-listeners-name-vs-slot" {
      "a listener named like an enabled slot" = fires {
        tcp = slotTcp;
        listeners.tcp = tcp "192.0.2.11" { };
      } { } "is also the name of the `tcp` slot";
      "the same name is fine while the slot is off" = quiet {
        listeners.tcp = tcp "192.0.2.11" { };
      } { };
      "other names are fine next to the slot" = quiet {
        tcp = slotTcp;
        listeners.other = tcp "192.0.2.11" { };
      } { };
    };

  listener-needs-logs-and-address = mkTableCheck "syslog-listeners-needs" {
    "logs.enable" =
      lib.any (lib.hasInfix "listeners.dev is defined but services.victoriaStack.logs.enable is not true")
        (
          failedOf (evalWith {
            services.victoriaStack.logs.syslog.listeners.dev = udp "192.0.2.10" { };
          })
        );
    "ipAddress" = fires {
      listeners.dev = {
        transport = "udp";
      };
    } { } "services.victoriaStack.logs.syslog.listeners.dev.ipAddress is not set";
    "an address is enough" = quiet { listeners.dev = udp "192.0.2.10" { }; } { };
    "an unparsable address is refused like any address option" = fires {
      listeners.dev = udp "192.0.2.10; rm" { };
    } { } "listeners.dev.ipAddress";
  };

  listener-tenant-must-be-declared = mkTableCheck "syslog-listeners-tenant" {
    "unknown tenant" = fires {
      listeners.dev = udp "192.0.2.10" (withTenant "nope");
    } { } ''services.victoriaStack.logs.syslog.listeners.dev.tenant is "nope"'';
    "the message lists the declared tenants" = fires {
      listeners.dev = udp "192.0.2.10" (withTenant "nope");
    } { } "team-a, team-b";
    "declared tenant" = quiet { listeners.dev = udp "192.0.2.10" (withTenant "team-a"); } { };
    "null is the default tenant" = quiet { listeners.dev = udp "192.0.2.10" (withTenant null); } { };
  };

  listener-tls-needs-a-certificate =
    let
      nocert = {
        transport = "tls";
        ipAddress = "192.0.2.10";
      };
    in
    mkTableCheck "syslog-listeners-tls-files" {
      "tls without either file" = fires {
        listeners.dev = nocert;
      } { } "listeners.dev needs a certificate";
      "tls with only the cert" = fires {
        listeners.dev = nocert // {
          certFile = "/run/c.pem";
        };
      } { } "listeners.dev needs a certificate";
      "tls with only the key" = fires {
        listeners.dev = nocert // {
          keyFile = "/run/c.key";
        };
      } { } "listeners.dev needs a certificate";
      "tls with both" = quiet { listeners.dev = tls "192.0.2.10" { }; } { };
      "a % in the path is allowed and escaped, as for the slot" = quiet {
        listeners.dev = tls "192.0.2.10" {
          certFile = "/run/50%c.pem";
          keyFile = "/run/50%c.key";
        };
      } { };
      "certFile on a udp listener" = fires {
        listeners.dev = udp "192.0.2.10" { certFile = "/run/c.pem"; };
      } { } "listeners.dev.certFile and .keyFile are for transport \"tls\" only";
      "keyFile on a tcp listener" = fires {
        listeners.dev = tcp "192.0.2.10" { keyFile = "/run/c.key"; };
      } { } "listeners.dev.certFile and .keyFile are for transport \"tls\" only";
    };

  listener-collisions =
    let
      http = {
        metrics.enable = true;
      };
      # Fires the shared listenAddress collision message.
      collide = syslog: extra: fires syslog extra "same listenAddress";
    in
    mkTableCheck "syslog-listeners-collisions" {
      "two tcp on one address and port" = collide {
        listeners = {
          a = tcp "192.0.2.10" { port = 5514; };
          b = tcp "192.0.2.10" { port = 5514; };
        };
      } { };
      "two udp on one address and port" = collide {
        listeners = {
          a = udp "192.0.2.10" { port = 5514; };
          b = udp "192.0.2.10" { port = 5514; };
        };
      } { };
      "a tls and a tcp on one address and port" = collide {
        listeners = {
          a = tcp "192.0.2.10" { port = 6514; };
          b = tls "192.0.2.10" { port = 6514; };
        };
      } { };
      "the message names both listeners" = fires {
        listeners = {
          a = tcp "192.0.2.10" { port = 5514; };
          b = tcp "192.0.2.10" { port = 5514; };
        };
      } { } "listeners.b";
      "an IPv4 wildcard over a specific address" = collide {
        listeners = {
          a = tcp "0.0.0.0" { port = 5514; };
          b = tcp "192.0.2.10" { port = 5514; };
        };
      } { };
      "an IPv6 wildcard over a specific address" = collide {
        listeners = {
          a = udp "::" { port = 5514; };
          b = udp "192.0.2.10" { port = 5514; };
        };
      } { };
      "a specific address over the wildcard" = collide {
        listeners = {
          a = udp "192.0.2.10" { port = 5514; };
          b = udp "0.0.0.0" { port = 5514; };
        };
      } { };
      "a listener and an enabled slot" = collide {
        udp = {
          enable = true;
          ipAddress = "192.0.2.10";
          port = 5514;
        };
        listeners.a = udp "192.0.2.10" { port = 5514; };
      } { };
      "tcp on the VictoriaLogs http port" = collide {
        listeners.a = tcp "127.0.0.1" { port = 4202; };
      } { };
      "tcp wildcard over the http port" = collide {
        listeners.a = tcp "0.0.0.0" { port = 4202; };
      } { };
      "tcp on the vmauth https door" =
        collide
          {
            listeners.a = tcp "192.0.2.10" { port = 8443; };
          }
          {
            vmauth.https = {
              enable = true;
              ipAddress = "192.0.2.10";
              port = 8443;
              certFile = "/run/c.pem";
              keyFile = "/run/c.key";
            };
            vmauth.readTokensFile = "/run/read.yaml";
          };
      # Controls: what shares an address and port without a clash.
      "udp and tcp share address and port" =
        !(collide {
          listeners = {
            a = udp "192.0.2.10" { port = 514; };
            b = tcp "192.0.2.10" { port = 514; };
          };
        } { });
      "udp on the http port number" =
        !(collide {
          listeners.a = udp "127.0.0.1" { port = 4202; };
        } { });
      "udp wildcard next to a tcp listener" =
        !(collide {
          listeners = {
            a = udp "0.0.0.0" { port = 5514; };
            b = tcp "192.0.2.10" { port = 5514; };
          };
        } { });
      "two tcp on different addresses" =
        !(collide {
          listeners = {
            a = tcp "192.0.2.10" { port = 5514; };
            b = tcp "192.0.2.11" { port = 5514; };
          };
        } { });
      "two tcp on different ports" =
        !(collide {
          listeners = {
            a = tcp "192.0.2.10" { port = 5514; };
            b = tcp "192.0.2.10" { port = 5515; };
          };
        } { });
      "a wildcard does not cover another family" =
        !(collide {
          listeners = {
            a = tcp "0.0.0.0" { port = 5514; };
            b = tcp "2001:db8::1" { port = 5514; };
          };
        } { });
      "the metrics listener is unaffected" =
        !(collide { listeners.a = udp "192.0.2.10" { port = 5514; }; } http);
    };

  # --- extraFlags ownership ---

  extra-flags-ownership =
    let
      rejected =
        syslog: flag:
        lib.any (lib.hasInfix "`${flag}`") (
          lib.filter (lib.hasInfix "extraFlags contains") (
            failedOf (stack syslog { logs.extraFlags = [ flag ]; })
          )
        );
      free = syslog: flag: !(rejected syslog flag);
      tcpOnly = {
        listeners.a = tcp "192.0.2.10" { };
      };
      udpOnly = {
        listeners.a = udp "192.0.2.10" { };
      };
      tlsOnly = {
        listeners.a = tls "192.0.2.10" { };
      };
      msg =
        syslog: flag:
        lib.concatStrings (
          lib.filter (lib.hasInfix "extraFlags contains") (
            failedOf (stack syslog { logs.extraFlags = [ flag ]; })
          )
        );
    in
    mkTableCheck "syslog-listeners-extra-flags-ownership" {
      "tenantID.tcp with a tcp listener" = rejected tcpOnly "-syslog.tenantID.tcp=1:0";
      "tenantID.tcp, double dash" = rejected tcpOnly "--syslog.tenantID.tcp=1:0";
      "tenantID.tcp with a tls listener" = rejected tlsOnly "-syslog.tenantID.tcp=1:0";
      "tenantID.udp with a udp listener" = rejected udpOnly "-syslog.tenantID.udp=1:0";
      "listenAddr.tcp with a tcp listener" = rejected tcpOnly "-syslog.listenAddr.tcp=:7514";
      "listenAddr.udp with a udp listener" = rejected udpOnly "-syslog.listenAddr.udp=:7514";
      "extraFields.udp with a udp listener" = rejected udpOnly "-syslog.extraFields.udp={}";
      "tls array with a tcp listener" = rejected tcpOnly "-syslog.tls=true";
      "tls array with a tls listener" = rejected tlsOnly "-syslog.tls=true";
      "tls cert file with a tls listener" = rejected tlsOnly "-syslog.tlsCertFile=/run/c.pem";
      "tls key file with a tcp listener" = rejected tcpOnly "-syslog.tlsKeyFile=/run/c.key";
      # No listener of that transport: hand-written flags stay possible.
      "tenantID.tcp with no tcp listener" = free udpOnly "-syslog.tenantID.tcp=1:0";
      "tenantID.udp with only tcp listeners" = free tcpOnly "-syslog.tenantID.udp=1:0";
      "tenantID.tcp with no listener at all" = free { } "-syslog.tenantID.tcp=1:0";
      "listenAddr.tcp with no listener at all" = free { } "-syslog.listenAddr.tcp=:7514";
      "tlsMinVersion is free" = free tlsOnly "-syslog.tlsMinVersion=TLS12";
      "unix flags are free" = free tcpOnly "-syslog.listenAddr.unix=/run/x.sock";
      "the message names the listeners option" =
        lib.hasInfix "services.victoriaStack.logs.syslog.listeners" (msg tcpOnly "-syslog.tenantID.tcp=1:0")
        && lib.hasInfix "positional" (msg tcpOnly "-syslog.tenantID.tcp=1:0");
    };

  # One entry of another array reaches the first listener of its transport only.
  shared-arrays-warn-with-several-listeners =
    let
      warns =
        syslog: flag:
        lib.any (lib.hasInfix "extraFlags") (syslogWarnings syslog { logs.extraFlags = [ flag ]; });
      twoTcp = {
        listeners = {
          a = tcp "127.0.0.1" { port = 5514; };
          b = tcp "127.0.0.1" { port = 5515; };
        };
      };
      twoUdp = {
        listeners = {
          a = udp "127.0.0.1" { port = 5514; };
          b = udp "127.0.0.1" { port = 5515; };
        };
      };
    in
    mkTableCheck "syslog-listeners-shared-array-warning" {
      "two tcp listeners" = warns twoTcp "-syslog.streamFields.tcp=host";
      "two udp listeners" = warns twoUdp "-syslog.streamFields.udp=host";
      "tcp and tls listeners" = warns {
        listeners = {
          a = tcp "127.0.0.1" { port = 5514; };
          b = tls "127.0.0.1" { port = 6514; };
        };
      } "-syslog.streamFields.tcp=host";
      "the cipher suites follow the tcp listeners" = warns twoTcp "-syslog.tlsCipherSuites=x";
      "the warning names the listeners in order" = lib.hasInfix "`a`, `b`" (
        lib.concatStrings (syslogWarnings twoTcp { logs.extraFlags = [ "-syslog.streamFields.tcp=host" ]; })
      );
      "one listener per transport does not warn" =
        !(warns {
          listeners = {
            a = tcp "127.0.0.1" { port = 5514; };
            b = udp "127.0.0.1" { port = 5514; };
          };
        } "-syslog.streamFields.tcp=host");
      "a flag of the other transport does not warn" = !(warns twoTcp "-syslog.streamFields.udp=host");
    };

  # --- warnings ---

  exposure-warns-per-listener =
    let
      warnings = syslog: syslogWarnings syslog { };
      count = syslog: lib.length (lib.filter (lib.hasInfix "no authentication") (warnings syslog));
      quietOn = {
        suppressExposureWarning = true;
      };
    in
    mkTableCheck "syslog-listeners-exposure-warning" {
      "loopback listeners are quiet" =
        warnings {
          listeners = {
            a = udp "127.0.0.1" { };
            b = tcp "::1" { };
            c = tcp "127.0.0.2" { port = 5514; };
          };
        } == [ ];
      "one warning per exposed listener" =
        count {
          listeners = {
            a = udp "192.0.2.10" { };
            b = tcp "192.0.2.11" { };
            c = tcp "127.0.0.1" { port = 5514; };
            d = tls "0.0.0.0" { };
          };
        } == 3;
      "the warning names the listener and its address" =
        let
          w = lib.concatStrings (warnings {
            listeners.edge = udp "192.0.2.10" { port = 5514; };
          });
        in
        lib.hasInfix "services.victoriaStack.logs.syslog.listeners.edge" w
        && lib.hasInfix "192.0.2.10:5514" w
        && lib.hasInfix "listeners.edge.suppressExposureWarning" w
        && lib.hasInfix "unencrypted" w;
      "the tls text says that tls does not authenticate" =
        let
          w = lib.concatStrings (warnings {
            listeners.edge = tls "192.0.2.10" { };
          });
        in
        lib.hasInfix "TLS encrypts but does not authenticate" w && !(lib.hasInfix "unencrypted" w);
      "suppression is per listener" =
        count {
          listeners = {
            a = udp "192.0.2.10" quietOn;
            b = udp "192.0.2.11" { };
          };
        } == 1;
      "everything suppressed" =
        warnings {
          listeners = {
            a = udp "192.0.2.10" quietOn;
            b = tcp "192.0.2.11" quietOn;
            c = tls "192.0.2.12" quietOn;
          };
        } == [ ];
    };

  # --- the real binary ---

  # examples/syslog-tenants.nix is operator documentation: it must evaluate
  # against the option set, pass the module's own assertions and render what
  # it says.
  syslog-tenants-example-evaluates =
    let
      e = evalWith {
        imports = [ ../examples/syslog-tenants.nix ];
      };
      flags = lib.filter (lib.hasInfix "-syslog.") (lib.splitString " " (execStart e));
    in
    mkTableCheck "syslog-listeners-example" {
      "no failed assertions" = failedOf e == [ ];
      "five listeners" =
        lib.length (lib.attrNames e.config.services.victoriaStack.logs.syslog.listeners) == 5;
      "each team's tenant is rendered" =
        lib.any (lib.hasInfix "-syslog.tenantID.udp=7:0") flags
        && lib.any (lib.hasInfix "-syslog.tenantID.udp=8:0") flags;
      "the untenanted listener is 0:0" = lib.any (lib.hasInfix "-syslog.tenantID.udp=0:0") flags;
    };

  # The pinned VictoriaLogs accepts the rendered flags of several listeners of
  # one transport and really binds every one of them.
  binary-binds-every-listener =
    let
      listeners = {
        a-udp = udp "127.0.0.2" ({ port = 5514; } // withTenant "team-a");
        b-udp = udp "127.0.0.3" ({ port = 5514; } // withTenant "team-b");
        c-udp = udp "127.0.0.4" { port = 5514; };
        a-tcp = tcp "127.0.0.2" ({ port = 5514; } // withTenant "team-a");
        b-tcp = tcp "127.0.0.3" ({ port = 5514; } // withTenant "team-b");
        c-tcp = tcp "127.0.0.4" { port = 5514; };
        d-tls = tls "127.0.0.5" (
          {
            port = 5514;
          }
          // withTenant "team-a"
          // {
            certFile = "/cert.pem";
            keyFile = "/key.pem";
          }
        );
        e-tls = tls "127.0.0.6" (
          {
            port = 5514;
          }
          // withTenant "team-b"
          // {
            certFile = "/cert.pem";
            keyFile = "/key.pem";
          }
        );
      };
      e = stack { inherit listeners; } { };
      cert = mkCert "syslog-listeners-probe" "IP:127.0.0.5,IP:127.0.0.6";
      flags = lib.replaceStrings [ "%d/" ] [ "@creds@/" ] (
        lib.concatStringsSep "\n" (flagsOf {
          inherit listeners;
        })
      );
      expected = lib.concatMap (
        name:
        let
          l = listeners.${name};
        in
        [ "${if l.transport == "udp" then "udp" else "tcp"} ${l.ipAddress}:${toString l.port}" ]
      ) (lib.attrNames listeners);
    in
    assert execStart e != "";
    pkgs.runCommand "syslog-listeners-binary-binds-every-listener"
      {
        nativeBuildInputs = [
          pkgs.victorialogs
          pkgs.iproute2
          pkgs.curl
        ];
        passAsFile = [ "flags" ];
        inherit flags;
      }
      ''
        mkdir creds data
        for n in d-tls e-tls; do
          cp ${cert}/cert.pem creds/syslog-tls-cert-$n
          cp ${cert}/key.pem creds/syslog-tls-key-$n
        done
        sed -i "s|@creds@|$PWD/creds|g" "$flagsPath"
        mapfile -t args < "$flagsPath"
        victoria-logs -storageDataPath=$PWD/data -httpListenAddr=127.0.0.1:4202 "''${args[@]}" > log 2>&1 &
        pid=$!
        for _ in $(seq 60); do
          curl -sf http://127.0.0.1:4202/ping >/dev/null && break
          kill -0 $pid || { cat log; echo "victoria-logs exited"; exit 1; }
          sleep 0.5
        done
        curl -sf http://127.0.0.1:4202/ping >/dev/null || { cat log; exit 1; }
        sockets=$(ss -H -lntu)
        ok=1
        ${lib.concatMapStringsSep "\n" (x: ''
          proto=${lib.head (lib.splitString " " x)}
          addr=${lib.last (lib.splitString " " x)}
          if ! echo "$sockets" | awk -v p="$proto" -v a="$addr" '$1 == p && $5 == a { f = 1 } END { exit !f }'; then
            echo "not bound: $proto $addr"; ok=0
          fi
        '') expected}
        if [ "$(echo "$sockets" | awk '$5 ~ /^127\.0\.0\.[2-6]:5514$/' | wc -l)" != 8 ]; then
          echo "expected exactly 8 listeners"; echo "$sockets"; ok=0
        fi
        kill $pid
        [ $ok = 1 ] || { cat log; exit 1; }
        echo OK > $out
      '';

  # --- end to end ---

  # Several devices of two teams, each on the listener of its own address: the
  # listener the packet reaches decides the tenant, read back through vmauth's
  # read tier with each team's token.
  syslog-listeners-route-each-device-to-its-tenant =
    let
      cert = mkCert "syslog-listeners-e2e" "IP:127.0.0.11,IP:127.0.0.12";
      send = "${syslogSend}/bin/syslog-send";
      lowPort = 514;
      listeners = {
        a-udp = udp "127.0.0.11" (
          {
            port = 5514;
            openFirewall = true;
          }
          // withTenant "team-a"
        );
        b-udp = udp "127.0.0.12" (
          {
            port = 5514;
            extraFields = {
              source = "router-b";
            };
          }
          // withTenant "team-b"
        );
        a-tcp = tcp "127.0.0.11" ({ port = 5514; } // withTenant "team-a");
        b-tcp = tcp "127.0.0.12" ({ port = 5514; } // withTenant "team-b");
        a-tls = tls "127.0.0.11" (
          {
            port = 6514;
            certFile = "/var/lib/syslog-tls/cert.pem";
            keyFile = "/var/lib/syslog-tls/key.pem";
          }
          // withTenant "team-a"
        );
        plain-tcp = tcp "127.0.0.13" {
          port = lowPort;
          openFirewall = true;
        };
        plain-udp = udp "127.0.0.13" { port = 5514; };
      };
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-syslog-listeners-route-each-device-to-its-tenant";

      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        environment.systemPackages = [
          syslogSend
          pkgs.iproute2
          pkgs.iptables
        ];
        systemd.tmpfiles.rules = [
          "d /var/lib/syslog-tls 0700 root root -"
          "C /var/lib/syslog-tls/cert.pem 0600 root root - ${cert}/cert.pem"
          "C /var/lib/syslog-tls/key.pem 0600 root root - ${cert}/key.pem"
        ];
        services.victoriaStack = {
          inherit tenants;
          logs = {
            enable = true;
            syslog = { inherit listeners; };
          };
          vmauth.readTokensFile = "${pkgs.writeText "syslog-listeners-read-tokens.yaml" ''
            tokens:
              - token: team-a-read-token # gitleaks:allow
                tenant: team-a
              - token: team-b-read-token # gitleaks:allow
                tenant: team-b
              - token: default-read-token # gitleaks:allow
          ''}";
        };
      };

      testScript = ''
        ${testLib.waitActivePython}
        import json
        import shlex

        TOKENS = {"a": "team-a-read-token", "b": "team-b-read-token", "0": "default-read-token"}
        URL = "http://127.0.0.1:4204/logs/select/logsql/query"

        def read_cmd(who, marker):
            return f"curl -sf -H 'Authorization: Bearer {TOKENS[who]}' {URL} --data-urlencode {shlex.quote('query=_msg:' + marker)}"

        def rows_of(who, marker):
            return [json.loads(l) for l in machine.succeed(read_cmd(who, marker)).splitlines() if l.strip()]

        # (listener, protocol, host, port, tenant that must see it, source label)
        DEVICES = [
            ("a-udp", "udp", "127.0.0.11", 5514, "a", "syslog"),
            ("b-udp", "udp", "127.0.0.12", 5514, "b", "router-b"),
            ("a-tcp", "tcp", "127.0.0.11", 5514, "a", "syslog"),
            ("b-tcp", "tcp", "127.0.0.12", 5514, "b", "syslog"),
            ("a-tls", "tls", "127.0.0.11", 6514, "a", "syslog"),
            ("plain-tcp", "tcp", "127.0.0.13", ${toString lowPort}, "0", "syslog"),
            ("plain-udp", "udp", "127.0.0.13", 5514, "0", "syslog"),
        ]

        def send_cmd(proto, host, port, marker):
            extra = "--cacert ${cert}/cert.pem" if proto == "tls" else ""
            return f"${send} --proto {proto} --host {host} --port {port} --format 5424 {extra} {marker}"

        def deliver(round_name):
            for name, proto, host, port, owner, source in DEVICES:
                marker = f"SYSLOGLISTENERS{round_name}{name.upper().replace('-', "")}"
                # UDP has no delivery guarantee: resend until the owner sees it.
                machine.wait_until_succeeds(
                    f"{send_cmd(proto, host, port, marker)}; sleep 1; {read_cmd(owner, marker)} | grep -F {marker}",
                    timeout=90,
                )
                mine = rows_of(owner, marker)
                assert len(mine) >= 1, (name, mine)
                assert mine[0]["source"] == source, (name, mine[0])
                for other in TOKENS:
                    if other != owner:
                        seen = rows_of(other, marker)
                        assert seen == [], f"{name} leaked to tenant {other}: {seen}"

        start_all()
        wait_active(machine, "victorialogs.service")
        wait_active(machine, "vmauth.service")
        machine.wait_for_open_port(4204)
        machine.wait_until_succeeds("ss -H -ltn | grep -F 127.0.0.11:6514")

        # Every listener is bound.
        sockets = machine.succeed("ss -H -lntu")
        for name, proto, host, port, owner, source in DEVICES:
            assert f"{host}:{port}" in sockets, (name, sockets)

        deliver("ONE")

        # The unit comes back with the same routing.
        machine.systemctl("restart victorialogs.service")
        wait_active(machine, "victorialogs.service")
        deliver("TWO")

        # Port 514 works with the capability alone.
        pid = machine.succeed("systemctl show -p MainPID --value victorialogs.service").strip()
        status = machine.succeed(f"cat /proc/{pid}/status")
        caps = {l.split(":")[0]: l.split(":")[1].strip() for l in status.splitlines() if l.startswith("Cap")}
        for k in ("CapBnd", "CapEff", "CapAmb"):
            assert caps[k] == "0000000000000400", (k, caps)

        # openFirewall opens exactly the ports of the listeners that ask.
        rules = machine.succeed("iptables -S nixos-fw")
        assert "-p tcp -m tcp --dport ${toString lowPort} -j nixos-fw-accept" in rules, rules
        assert "-p udp -m udp --dport 5514 -j nixos-fw-accept" in rules, rules
        assert "--dport 6514" not in rules, rules
        assert "-p tcp -m tcp --dport 5514" not in rules, rules
      '';
    };
}
