{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith mkAssertionFiresCheck;

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

  logsUnit =
    syslog:
    (evalWith {
      services.victoriaStack.logs = {
        enable = true;
        inherit syslog;
      };
    }).config.systemd.services.victorialogs;

  # The -syslog.* arguments of the unit, in order, with the shell quoting that
  # escapeShellArgs adds around them removed.
  syslogFlags =
    syslog:
    map (f: lib.removeSuffix "'" (lib.removePrefix "'" f)) (
      lib.filter (lib.hasInfix "-syslog.") (lib.splitString " " (logsUnit syslog).serviceConfig.ExecStart)
    );

  # Sends one syslog message the way a device would: RFC 3164 or 5424, over
  # UDP, TCP (newline or octet-counting framing) or TLS, with a timestamp of
  # "now" (VictoriaLogs infers the year of an RFC 3164 stamp).
  syslogSend =
    pkgs.writers.writePython3Bin "syslog-send"
      {
        flakeIgnore = [
          "E501"
          "E302"
          "E305"
          "E231"
          "E722"
        ];
      }
      ''
        import argparse
        import datetime
        import socket
        import ssl

        p = argparse.ArgumentParser()
        p.add_argument("--proto", choices=["udp", "tcp", "tls"], required=True)
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, required=True)
        p.add_argument("--format", choices=["3164", "5424", "raw"], default="3164")
        p.add_argument("--framing", choices=["newline", "octet"], default="newline")
        p.add_argument("--hostname", default="testhost")
        p.add_argument("--cacert")
        p.add_argument("--tls-max", choices=["1.2", "1.3"], default="1.3")
        p.add_argument("--client-cert")
        p.add_argument("--client-key")
        p.add_argument("message")
        a = p.parse_args()

        now = datetime.datetime.now(datetime.timezone.utc)
        if a.format == "3164":
            ts = now.strftime("%b %e %H:%M:%S")
            line = f"<34>{ts} {a.hostname} su[1234]: {a.message}"
        elif a.format == "5424":
            ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
            line = f'<165>1 {ts} {a.hostname} evntslog 4321 ID47 [exampleSDID@32473 iut="3" eventSource="Application"] {a.message}'
        else:
            line = a.message
        data = line.encode()
        if a.proto != "udp":
            data = f"{len(data)} ".encode() + data if a.framing == "octet" else data + b"\n"

        if a.proto == "udp":
            s = socket.socket(socket.AF_INET6 if ":" in a.host else socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(data, (a.host, a.port))
        else:
            s = socket.create_connection((a.host, a.port), timeout=10)
            if a.proto == "tls":
                ctx = ssl.create_default_context(cafile=a.cacert)
                if a.tls_max == "1.2":
                    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
                if a.client_cert:
                    ctx.load_cert_chain(a.client_cert, a.client_key)
                s = ctx.wrap_socket(s, server_hostname=a.host)
            s.sendall(data)
        s.close()
      '';

  # Test-script helpers: query VictoriaLogs for one marker word and return the
  # rows. Rows become searchable about a second after the send, so every query
  # goes through wait_until_succeeds.
  queryPython = ''
    import json
    import shlex

    def query_cmd(q, port=4202):
        return f"curl -sf http://127.0.0.1:{port}/select/logsql/query --data-urlencode {shlex.quote('query=' + q)}"

    def rows(machine, marker, port=4202):
        machine.wait_until_succeeds(f"{query_cmd('_msg:' + marker, port)} | grep -F {marker}", timeout=60)
        out = machine.succeed(query_cmd("_msg:" + marker, port))
        return [json.loads(l) for l in out.splitlines() if l.strip()]

    def resend_until_found(machine, send, marker, port=4202):
        # UDP has no delivery guarantee and the socket may not be up for the first datagram.
        machine.wait_until_succeeds(f"{send}; sleep 1; {query_cmd('_msg:' + marker, port)} | grep -F {marker}", timeout=90)
        return rows(machine, marker, port)

    def caps(machine):
        pid = machine.succeed("systemctl show -p MainPID --value victorialogs.service").strip()
        status = machine.succeed(f"cat /proc/{pid}/status")
        return {
            k: v.strip()
            for k, v in (l.split(":", 1) for l in status.splitlines() if l.startswith("Cap"))
        }
  '';

  send = "${syslogSend}/bin/syslog-send";
  tools = [
    syslogSend
    pkgs.iproute2
  ];

  slot = ip: port: {
    enable = true;
    ipAddress = ip;
    port = port;
  };
in
{
  # --- eval-only ---

  off-by-default-adds-no-flags-and-keeps-hardening =
    let
      unit = logsUnit { };
      sc = unit.serviceConfig;
      cfg =
        (evalWith {
          services.victoriaStack.logs.enable = true;
        }).config.services.victoriaStack.logs.syslog;
    in
    mkTableCheck "syslog-off-by-default" {
      "no slot enabled" = !cfg.udp.enable && !cfg.tcp.enable;
      "no address by default" = cfg.udp.ipAddress == null && cfg.tcp.ipAddress == null;
      "default ports are the standard ones" = cfg.udp.port == 514 && cfg.tcp.port == 514;
      "no -syslog flag" = !(lib.hasInfix "-syslog." sc.ExecStart);
      "full hardening profile" = testLib.hardeningDiff sc == [ ];
      "no ambient capability" = !(sc ? AmbientCapabilities);
    };

  # A slot with no address would render a flag with nothing to bind.
  enabled-slot-without-address-fires = mkAssertionFiresCheck {
    name = "syslog-enabled-slot-without-address-fires";
    expectMessageSubstring = "services.victoriaStack.logs.syslog.udp.ipAddress";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        syslog.udp.enable = true;
      };
    };
  };

  listen-flags-per-transport =
    let
      flags =
        syslog:
        lib.filter (lib.hasPrefix "-syslog.listenAddr.") (
          syslogFlags (lib.mapAttrs (_: s: s // { extraFields = { }; }) syslog)
        );
    in
    mkTableCheck "syslog-listen-flags" {
      "udp slot" =
        flags { udp = slot "192.0.2.10" 5514; } == [ "-syslog.listenAddr.udp=192.0.2.10:5514" ];
      "tcp slot" =
        flags { tcp = slot "192.0.2.10" 5514; } == [ "-syslog.listenAddr.tcp=192.0.2.10:5514" ];
      "udp and tcp share one port" =
        flags {
          udp = slot "192.0.2.10" 514;
          tcp = slot "192.0.2.10" 514;
        } == [
          "-syslog.listenAddr.tcp=192.0.2.10:514"
          "-syslog.listenAddr.udp=192.0.2.10:514"
        ];
      "IPv6 literal is bracketed" =
        flags { tcp = slot "2001:db8::1" 5514; } == [ "-syslog.listenAddr.tcp=[2001:db8::1]:5514" ];
      "IPv4 wildcard" = flags { udp = slot "0.0.0.0" 5514; } == [ "-syslog.listenAddr.udp=0.0.0.0:5514" ];
      "IPv6 wildcard" = flags { udp = slot "::" 5514; } == [ "-syslog.listenAddr.udp=[::]:5514" ];
      "a disabled slot renders nothing" =
        flags {
          udp = (slot "192.0.2.10" 5514) // {
            enable = false;
          };
        } == [ ];
    };

  # Every slot carries source=syslog unless told otherwise; the value is the
  # JSON object the flag requires, and systemd must not expand % or $ in it.
  extra-fields-render-as-json =
    let
      fields =
        extraFields:
        lib.filter (lib.hasPrefix "-syslog.extraFields.") (syslogFlags {
          tcp = (slot "192.0.2.10" 5514) // {
            inherit extraFields;
          };
        });
      defaulted = syslogFlags { tcp = slot "192.0.2.10" 5514; };
    in
    mkTableCheck "syslog-extra-fields" {
      "default label is source=syslog" =
        lib.elem ''-syslog.extraFields.tcp={"source":"syslog"}'' defaulted;
      "overridden" = fields { source = "router"; } == [ ''-syslog.extraFields.tcp={"source":"router"}'' ];
      "extended" =
        fields {
          source = "syslog";
          site = "lab";
        } == [ ''-syslog.extraFields.tcp={"site":"lab","source":"syslog"}'' ];
      "empty renders no flag" = fields { } == [ ];
      # systemd reads C escapes inside quotes, so the JSON's own backslash would
      # arrive as a bare quote and the binary would die parsing it.
      "backslashes of the JSON are doubled for systemd" =
        fields { note = ''a"b''; } == [ ''-syslog.extraFields.tcp={"note":"a\\"b"}'' ];
      "systemd specifiers are escaped" =
        fields { note = "50%h$HOME"; } == [ ''-syslog.extraFields.tcp={"note":"50%%h$$HOME"}'' ];
    };

  # Same mechanism as vmauth (docs/decisions/0015): the unit keeps its empty
  # capability set unless a syslog port is below 1024.
  low-port-capability-table =
    let
      sc = syslog: (logsUnit syslog).serviceConfig;
      caps = syslog: {
        bounding = (sc syslog).CapabilityBoundingSet or null;
        ambient = (sc syslog).AmbientCapabilities or null;
        privateUsers = (sc syslog).PrivateUsers or null;
      };
      none = {
        bounding = "";
        ambient = null;
        privateUsers = true;
      };
      bind = {
        bounding = [ "CAP_NET_BIND_SERVICE" ];
        ambient = [ "CAP_NET_BIND_SERVICE" ];
        privateUsers = false;
      };
      cases = {
        "off" = {
          got = caps { };
          want = none;
        };
        "udp 514" = {
          got = caps { udp = slot "192.0.2.10" 514; };
          want = bind;
        };
        "tcp 514" = {
          got = caps { tcp = slot "192.0.2.10" 514; };
          want = bind;
        };
        "tcp 1023" = {
          got = caps { tcp = slot "192.0.2.10" 1023; };
          want = bind;
        };
        "IPv6 on 514" = {
          got = caps { udp = slot "::1" 514; };
          want = bind;
        };
        "tcp 1024 is not privileged" = {
          got = caps { tcp = slot "192.0.2.10" 1024; };
          want = none;
        };
        "high udp with low tcp" = {
          got = caps {
            udp = slot "192.0.2.10" 5514;
            tcp = slot "192.0.2.10" 514;
          };
          want = bind;
        };
        "port 514 on a disabled slot" = {
          got = caps {
            udp = (slot "192.0.2.10" 514) // {
              enable = false;
            };
          };
          want = none;
        };
      };
      failed = lib.filterAttrs (_: c: c.got != c.want) cases;
      onlyTwoKeysLoosened =
        testLib.hardeningDiff (sc {
          udp = slot "192.0.2.10" 514;
        }) == [
          "CapabilityBoundingSet"
          "PrivateUsers"
        ];
    in
    pkgs.runCommand "syslog-low-port-capability" { } (
      if failed == { } && onlyTwoKeysLoosened then
        "echo OK > $out"
      else
        throw "unexpected capability sets: ${builtins.toJSON failed}, only the two keys loosened: ${lib.boolToString onlyTwoKeysLoosened}"
    );

  # --- assertions, collisions, extraFlags ownership, exposure warning ---

  slot-requires-logs-enable-fires = mkAssertionFiresCheck {
    name = "syslog-slot-requires-logs-enable-fires";
    expectMessageSubstring = "services.victoriaStack.logs.syslog.tcp.enable requires";
    module = {
      services.victoriaStack.logs.syslog.tcp = slot "127.0.0.1" 5514;
    };
  };

  # Colliding listeners are named on both sides; udp never collides with a tcp
  # listener (measured: a udp socket on the HTTP port number binds fine).
  listener-collisions =
    let
      certs = {
        certFile = "/run/fake-cert.pem";
        keyFile = "/run/fake-key.pem";
      };
      messages =
        m:
        lib.filter (lib.hasInfix "same listenAddress") (
          lib.filter (lib.hasInfix "services.victoriaStack") (
            map (a: a.message) (
              builtins.filter (a: !a.assertion)
                (evalWith {
                  services.victoriaStack = lib.recursiveUpdate {
                    metrics.enable = true;
                    logs.enable = true;
                  } m;
                }).config.assertions
            )
          )
        );
      fires = m: messages m != [ ];
    in
    mkTableCheck "syslog-listener-collisions" {
      "tcp slot on the logs HTTP port" = fires { logs.syslog.tcp = slot "127.0.0.1" 4202; };
      "tcp slot wildcard over the logs HTTP port" = fires { logs.syslog.tcp = slot "0.0.0.0" 4202; };
      "tcp slot on an https door port" = fires {
        vmauth.https = {
          enable = true;
          port = 8443;
        }
        // certs;
        logs.syslog.tcp = slot "0.0.0.0" 8443;
      };
      "the message names the slot and the other listener" =
        lib.any
          (
            m:
            lib.hasInfix "services.victoriaStack.logs.syslog.tcp (127.0.0.1:4202)" m
            && lib.hasInfix "services.victoriaStack.logs.listenAddress" m
          )
          (messages {
            logs.syslog.tcp = slot "127.0.0.1" 4202;
          });
      "udp slot on the logs HTTP port does not fire" =
        !(fires { logs.syslog.udp = slot "127.0.0.1" 4202; });
      "udp slot on an http door port does not fire" =
        !(fires {
          vmauth.http = {
            enable = true;
            port = 8080;
          };
          logs.syslog.udp = slot "0.0.0.0" 8080;
        });
      "udp and tcp slots on one port do not fire" =
        !(fires {
          logs.syslog = {
            udp = slot "0.0.0.0" 514;
            tcp = slot "0.0.0.0" 514;
          };
        });
      "tcp slot on a free port does not fire" = !(fires { logs.syslog.tcp = slot "0.0.0.0" 5514; });
    };

  # -syslog.listenAddr/extraFields of a transport (and the tls arrays, which
  # belong to tcp) are positional with the slots: a flag of the same array in
  # extraFlags would misalign them. Everything else, and the unix transport,
  # stays free.
  extra-flags-ownership =
    let
      messages =
        syslog: flags:
        lib.filter (lib.hasInfix "extraFlags contains") (
          lib.filter (lib.hasInfix "services.victoriaStack") (
            map (a: a.message) (
              builtins.filter (a: !a.assertion)
                (evalWith {
                  services.victoriaStack.logs = {
                    enable = true;
                    inherit syslog;
                    extraFlags = flags;
                  };
                }).config.assertions
            )
          )
        );
      rejected = syslog: flag: lib.any (lib.hasInfix "`${flag}`") (messages syslog [ flag ]);
      free = syslog: flag: messages syslog [ flag ] == [ ];
      tcp = {
        tcp = slot "192.0.2.10" 5514;
      };
      udp = {
        udp = slot "192.0.2.10" 5514;
      };
    in
    mkTableCheck "syslog-extra-flags-ownership" {
      "tcp listenAddr with a tcp slot" = rejected tcp "-syslog.listenAddr.tcp=:6514";
      "tcp listenAddr, double dash" = rejected tcp "--syslog.listenAddr.tcp=:6514";
      "tcp extraFields with a tcp slot" = rejected tcp "-syslog.extraFields.tcp={}";
      "tls array with a tcp slot" = rejected tcp "-syslog.tls";
      "tls array with a value" = rejected tcp "-syslog.tls=true";
      "tls cert file with a tcp slot" = rejected tcp "-syslog.tlsCertFile=/run/fake-cert.pem";
      "tls key file, double dash" = rejected tcp "--syslog.tlsKeyFile=/run/fake-key.pem";
      "udp listenAddr with a udp slot" = rejected udp "-syslog.listenAddr.udp=:6514";
      "udp extraFields with a udp slot" = rejected udp "-syslog.extraFields.udp={}";
      "tcp listenAddr is free with only a udp slot" = free udp "-syslog.listenAddr.tcp=:6514";
      "tls array is free with only a udp slot" = free udp "-syslog.tls=true";
      "udp listenAddr is free with only a tcp slot" = free tcp "-syslog.listenAddr.udp=:6514";
      "tcp listenAddr is free with no slot" = free { } "-syslog.listenAddr.tcp=:6514";
      "tls flags are free with no slot" = free { } "-syslog.tlsCertFile=/run/fake-cert.pem";
      "unix socket listener is free with slots" =
        free tcp "-syslog.listenAddr.unix=/run/victorialogs/syslog.sock";
      "unixgram listener is free with slots" =
        free udp "-syslog.listenAddr.unix=unixgram:/run/victorialogs/syslog.sock";
      "timezone is free with slots" = free tcp "-syslog.timezone=UTC";
      "tlsMinVersion is free with slots" = free tcp "-syslog.tlsMinVersion=TLS12";
      "tlsCipherSuites is free with slots" = free tcp "-syslog.tlsCipherSuites=TLS_AES_128_GCM_SHA256";
      "streamFields of a slot's transport is free" = free tcp ''-syslog.streamFields.tcp=["hostname"]'';
      "a plain TLS flag is still rejected" = rejected { } "-tlsCertFile=/run/fake-cert.pem";
    };

  # The exposure warning: a listener that is reachable from the network and not
  # encrypted. The suppress option belongs to its own slot only.
  exposure-warning =
    let
      warnings =
        syslog:
        lib.filter (lib.hasInfix "services.victoriaStack.logs.syslog") (
          (evalWith {
            services.victoriaStack.logs = {
              enable = true;
              inherit syslog;
            };
          }).config.warnings
        );
      warns =
        syslog: slotName:
        lib.any (lib.hasInfix "services.victoriaStack.logs.syslog.${slotName}") (warnings syslog);
      quiet = syslog: warnings syslog == [ ];
      suppressed =
        ip:
        (slot ip 514)
        // {
          suppressExposureWarning = true;
        };
      mixed = {
        udp = suppressed "0.0.0.0";
        tcp = slot "0.0.0.0" 514;
      };
    in
    mkTableCheck "syslog-exposure-warning" {
      "plain tcp on the wildcard" = warns { tcp = slot "0.0.0.0" 514; } "tcp";
      "udp on a specific non-loopback address" = warns { udp = slot "192.0.2.10" 514; } "udp";
      "IPv6 wildcard" = warns { udp = slot "::" 514; } "udp";
      "udp on loopback" = quiet { udp = slot "127.0.0.1" 514; };
      "tcp on 127.0.0.2" = quiet { tcp = slot "127.0.0.2" 514; };
      "tcp on [::1]" = quiet { tcp = slot "[::1]" 514; };
      "udp on ::1" = quiet { udp = slot "::1" 514; };
      "tcp on localhost" = quiet { tcp = slot "localhost" 514; };
      "nothing enabled" = quiet { };
      "suppress silences its own slot" = quiet { udp = suppressed "0.0.0.0"; };
      "suppress on udp leaves the tcp warning" = warns mixed "tcp" && !(warns mixed "udp");
      "the warning names the way to silence it" =
        lib.any (lib.hasInfix "suppressExposureWarning")
          (warnings {
            udp = slot "0.0.0.0" 514;
          });
    };

  # --- real boot ---

  udp-and-tcp-ingest-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-roundtrip";

    # `main`: the defaults. `custom`: the labels overridden and extended on the
    # UDP slot only.
    containers.main = {
      imports = [ module ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog = {
          udp = slot "127.0.0.1" 5514;
          tcp = slot "127.0.0.1" 5514;
        };
      };
    };
    containers.custom = {
      imports = [ module ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog = {
          udp = (slot "127.0.0.1" 5514) // {
            extraFields = {
              source = "router";
              site = "lab";
              note = "say \"hi\" 50% $HOME";
            };
          };
          tcp = slot "127.0.0.1" 5514;
        };
      };
    };

    testScript = ''
      ${queryPython}
      start_all()
      main.wait_for_unit("victorialogs.service")
      custom.wait_for_unit("victorialogs.service")

      # udp and tcp on one port: both bound.
      main.succeed("ss -lntH | grep -F ':5514'")
      main.succeed("ss -lunH | grep -F ':5514'")

      r = resend_until_found(main, "${send} --proto udp --port 5514 --format 3164 UDPRFC3164MARK", "UDPRFC3164MARK")[0]
      assert r["format"] == "rfc3164" and r["hostname"] == "testhost" and r["app_name"] == "su", r
      assert r["proc_id"] == "1234" and r["level"] == "critical", r
      assert r["source"] == "syslog", r
      assert r["_stream"] == '{app_name="su",hostname="testhost",proc_id="1234"}', r

      main.succeed("${send} --proto tcp --port 5514 --format 3164 TCPRFC3164MARK")
      r = rows(main, "TCPRFC3164MARK")[0]
      assert r["format"] == "rfc3164" and r["source"] == "syslog", r

      main.succeed("${send} --proto tcp --port 5514 --format 5424 --framing octet TCPRFC5424MARK")
      r = rows(main, "TCPRFC5424MARK")[0]
      assert r["format"] == "rfc5424" and r["msg_id"] == "ID47" and r["app_name"] == "evntslog", r
      assert r["exampleSDID@32473.iut"] == "3" and r["source"] == "syslog", r

      r = resend_until_found(main, "${send} --proto udp --port 5514 --format 5424 UDPRFC5424MARK", "UDPRFC5424MARK")[0]
      assert r["format"] == "rfc5424" and r["source"] == "syslog", r

      # extraFields: overridden and extended on udp, untouched on tcp.
      r = resend_until_found(custom, "${send} --proto udp --port 5514 --format 5424 CUSTOMUDPMARK", "CUSTOMUDPMARK")[0]
      assert r["source"] == "router" and r["site"] == "lab", r
      assert r["note"] == 'say "hi" 50% $HOME', r
      custom.succeed("${send} --proto tcp --port 5514 --format 3164 CUSTOMTCPMARK")
      r = rows(custom, "CUSTOMTCPMARK")[0]
      assert r["source"] == "syslog" and "site" not in r, r
    '';
  };

  # The protocol-aware collision check allows a udp slot on the number of the HTTP
  # (tcp) port; this proves the kernel and VictoriaLogs agree.
  udp-slot-on-the-http-port-number-boots = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-udp-on-http-port";

    containers.machine = {
      imports = [ module ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog.udp = slot "127.0.0.1" 4202;
      };
    };

    testScript = ''
      ${queryPython}
      start_all()
      machine.wait_for_unit("victorialogs.service")
      machine.succeed("ss -lntH | grep -F '127.0.0.1:4202'")
      machine.succeed("ss -lunH | grep -F '127.0.0.1:4202'")
      resend_until_found(machine, "${send} --proto udp --port 4202 SAMEPORTMARK", "SAMEPORTMARK")
    '';
  };

  # Port 514 needs CAP_NET_BIND_SERVICE for the unprivileged DynamicUser, and
  # the kernel's own view of the process must show exactly that and nothing
  # else; on a high port the set stays empty.
  port-514-boots-with-only-net-bind-service = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-low-port";

    containers.low = {
      imports = [ module ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog = {
          udp = slot "127.0.0.1" 514;
          tcp = slot "127.0.0.1" 514;
        };
      };
    };
    containers.high = {
      imports = [ module ];
      services.victoriaStack.logs = {
        enable = true;
        syslog.udp = slot "127.0.0.1" 5514;
      };
    };

    testScript = ''
      ${queryPython}
      start_all()
      low.wait_for_unit("victorialogs.service")
      low.wait_for_open_port(514)
      low.succeed("ss -lunH | grep -F ':514'")
      resend_until_found(low, "${send} --proto udp --port 514 LOWUDPMARK", "LOWUDPMARK")
      low.succeed("${send} --proto tcp --port 514 LOWTCPMARK")
      rows(low, "LOWTCPMARK")
      c = caps(low)
      for k in ("CapBnd", "CapEff", "CapAmb"):
          assert c[k] == "0000000000000400", (k, c)

      high.wait_for_unit("victorialogs.service")
      c = caps(high)
      for k in ("CapBnd", "CapEff", "CapAmb"):
          assert c[k] == "0000000000000000", (k, c)
    '';
  };
}
