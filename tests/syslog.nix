{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    evalWith
    mkAssertionFiresCheck
    mkNoWarningsCheck
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
                print(s.version())
            s.sendall(data)
            # Close the way a well-behaved sender does. Closing a TLS 1.3 socket
            # with unread session tickets resets the connection, and the reset
            # discards the message the server had not read yet.
            if a.proto == "tls":
                s = s.unwrap()
            s.shutdown(socket.SHUT_WR)
            s.settimeout(3)
            try:
                while s.recv(4096):
                    pass
            except OSError:
                # The data is already sent; a peer that resets while draining
                # (it refused the stream) changes nothing for the sender.
                pass
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
    pkgs.openssl
  ];

  # Throwaway server certificates (the SAN must cover the address the client
  # dials); generated at build time, never committed.
  mkCert =
    cn: san:
    pkgs.runCommand "syslog-test-cert-${cn}" { nativeBuildInputs = [ pkgs.openssl ]; } ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
        -subj "/CN=${cn}" -addext "subjectAltName=${san}" \
        -keyout $out/key.pem -out $out/cert.pem
    '';
  certOne = mkCert "syslog-test-one" "IP:127.0.0.1";
  certTwo = mkCert "syslog-test-two" "IP:127.0.0.1";
  certHosts = mkCert "syslog-test-hosts" "DNS:exposed,DNS:sealed,IP:127.0.0.1";
  certStack = mkCert "syslog-test-stack" "DNS:stack,IP:127.0.0.1";

  # The end-to-end scenario's stack, written the way a user would: logs behind
  # vmauth with a read token, and all three syslog slots open to the network.
  # `suppress` is the plain slots' suppressExposureWarning.
  scenarioServices = suppress: {
    logs = {
      enable = true;
      syslog = {
        udp = (slot "0.0.0.0" 514) // {
          openFirewall = true;
          suppressExposureWarning = suppress;
        };
        tcp = (slot "0.0.0.0" 514) // {
          openFirewall = true;
          suppressExposureWarning = suppress;
        };
        tls =
          (slot "0.0.0.0" 6514)
          // runtimeCert
          // {
            openFirewall = true;
            extraFields = {
              source = "edge";
              site = "lab";
            };
          };
      };
    };
    vmauth.readTokensFile = "${pkgs.writeText "syslog-e2e-read-tokens.yaml" ''
      tokens:
        - token: syslog-e2e-read-token # gitleaks:allow
    ''}";
  };

  scenarioStack = suppress: {
    virtualisation.vlans = [ 1 ];
    imports = [
      module
      (tlsFilesFrom certStack)
    ];
    environment.systemPackages = tools;
    services.victoriaStack = scenarioServices suppress;
  };

  # The files sit at a runtime path, root-only like a secrets manager leaves
  # them, so the unit can only read them through LoadCredential=.
  tlsFilesFrom = cert: {
    systemd.tmpfiles.rules = [
      "d /var/lib/syslog-tls 0700 root root -"
      "C /var/lib/syslog-tls/cert.pem 0600 root root - ${cert}/cert.pem"
      "C /var/lib/syslog-tls/key.pem 0600 root root - ${cert}/key.pem"
    ];
  };
  runtimeCert = {
    certFile = "/var/lib/syslog-tls/cert.pem";
    keyFile = "/var/lib/syslog-tls/key.pem";
  };
  tlsSlot =
    ip: port:
    (slot ip port)
    // {
      certFile = "/run/fake-cert.pem";
      keyFile = "/run/fake-key.pem";
    };

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
        "tls 514" = {
          got = caps { tls = tlsSlot "192.0.2.10" 514; };
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
      tlsOnly = {
        tls = tlsSlot "192.0.2.10" 6514;
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
      "tls array with only a tls slot" = rejected tlsOnly "-syslog.tls=true";
      "tcp listenAddr with only a tls slot" = rejected tlsOnly "-syslog.listenAddr.tcp=:7514";
      "tlsMinVersion is free with a tls slot" = free tlsOnly "-syslog.tlsMinVersion=TLS12";
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

  # --- tls slot ---

  # The tls arrays are positional with the tcp listeners: a plain tcp slot gets
  # blanks, the tls slot the credential paths (never the file's own path, which
  # the unit may not be able to read).
  tls-flags-use-credentials-and-blank-for-plain-listeners =
    let
      two = {
        tcp = (slot "192.0.2.10" 5514) // {
          extraFields = { };
        };
        tls = tlsSlot "192.0.2.10" 6514;
      };
      only = {
        tls = tlsSlot "192.0.2.10" 6514;
      };
      sc = syslog: (logsUnit syslog).serviceConfig;
    in
    mkTableCheck "syslog-tls-flags" {
      "plain tcp then tls, every array positional" =
        syslogFlags two == [
          "-syslog.listenAddr.tcp=192.0.2.10:5514"
          "-syslog.listenAddr.tcp=192.0.2.10:6514"
          "-syslog.extraFields.tcp="
          ''-syslog.extraFields.tcp={"source":"syslog"}''
          "-syslog.tls=false"
          "-syslog.tls=true"
          "-syslog.tlsCertFile="
          "-syslog.tlsCertFile=%d/syslog-tls-cert"
          "-syslog.tlsKeyFile="
          "-syslog.tlsKeyFile=%d/syslog-tls-key"
        ];
      "tls alone" =
        lib.filter (lib.hasPrefix "-syslog.tls") (syslogFlags only) == [
          "-syslog.tls=true"
          "-syslog.tlsCertFile=%d/syslog-tls-cert"
          "-syslog.tlsKeyFile=%d/syslog-tls-key"
        ];
      "no tls flag without a tls slot" =
        lib.filter (lib.hasPrefix "-syslog.tls") (syslogFlags {
          tcp = slot "192.0.2.10" 5514;
        }) == [ ];
      "credentials are staged by LoadCredential" =
        (sc only).LoadCredential == [
          "syslog-tls-cert:/run/fake-cert.pem"
          "syslog-tls-key:/run/fake-key.pem"
        ];
      "no credential without a tls slot" = !((sc { tcp = slot "192.0.2.10" 5514; }) ? LoadCredential);
      "the files' own paths are not in ExecStart" = !(lib.hasInfix "/run/fake-" (sc only).ExecStart);
      "the tls slot listens on 6514 by default" = lib.hasInfix ":6514" (sc only).ExecStart;
    };

  tls-slot-assertions =
    let
      failed =
        syslog:
        lib.filter (lib.hasInfix "services.victoriaStack.logs.syslog.tls") (
          lib.filter (lib.hasInfix "services.victoriaStack") (
            map (a: a.message) (
              builtins.filter (a: !a.assertion)
                (evalWith {
                  services.victoriaStack.logs = {
                    enable = true;
                    inherit syslog;
                  };
                }).config.assertions
            )
          )
        );
      files = {
        certFile = "/run/fake-cert.pem";
        keyFile = "/run/fake-key.pem";
      };
    in
    mkTableCheck "syslog-tls-slot-assertions" {
      "enabled without files fires" = failed { tls = slot "192.0.2.10" 6514; } != [ ];
      "enabled with only a cert fires" =
        failed {
          tls = (slot "192.0.2.10" 6514) // {
            certFile = "/run/fake-cert.pem";
          };
        } != [ ];
      "enabled with only a key fires" =
        failed {
          tls = (slot "192.0.2.10" 6514) // {
            keyFile = "/run/fake-key.pem";
          };
        } != [ ];
      "files without an enabled slot are fine" = failed { tls = files; } == [ ];
      "one file without an enabled slot fires" =
        failed {
          tls = {
            certFile = "/run/fake-cert.pem";
          };
        } != [ ];
      "enabled without an address fires" =
        failed {
          tls = files // {
            enable = true;
          };
        } != [ ];
      "enabled with both files is fine" = failed { tls = tlsSlot "192.0.2.10" 6514; } == [ ];
    };

  # A TLS listener is encrypted, so it does not trigger the exposure warning
  # (it still has no authentication: that lives in the option text and the ADR).
  tls-slot-does-not-warn-on-the-wildcard = mkNoWarningsCheck {
    name = "syslog-tls-slot-does-not-warn-on-the-wildcard";
    module = {
      services.victoriaStack.logs = {
        enable = true;
        syslog.tls = tlsSlot "0.0.0.0" 6514;
      };
    };
  };

  tls-slot-collides-with-tcp-slot-on-one-port =
    let
      fires =
        syslog:
        lib.any (lib.hasInfix "same listenAddress") (
          map (a: a.message) (
            builtins.filter (a: !a.assertion)
              (evalWith {
                services.victoriaStack.logs = {
                  enable = true;
                  inherit syslog;
                };
              }).config.assertions
          )
        );
    in
    mkTableCheck "syslog-tls-collides-with-tcp" {
      "same port" = fires {
        tcp = slot "0.0.0.0" 6514;
        tls = tlsSlot "127.0.0.1" 6514;
      };
      "default ports differ" =
        !(fires {
          tcp = slot "0.0.0.0" 514;
          tls = tlsSlot "0.0.0.0" 6514;
        });
      "udp next to tls on one port" =
        !(fires {
          udp = slot "0.0.0.0" 6514;
          tls = tlsSlot "0.0.0.0" 6514;
        });
    };

  # The unit only sees a copy of the files (LoadCredential=), so a replaced
  # file must restart it; like vmauth's watchers, and only while a tls slot exists.
  tls-secret-watchers-exist-only-with-a-tls-slot =
    let
      eval =
        syslog:
        (evalWith {
          services.victoriaStack.logs = {
            enable = true;
            inherit syslog;
          };
        }).config;
      watchers =
        syslog:
        lib.filterAttrs (n: _: lib.hasPrefix "victorialogs-secret-watch-" n) (eval syslog).systemd.paths;
      withTls = watchers { tls = tlsSlot "192.0.2.10" 6514; };
      restart = (eval { tls = tlsSlot "192.0.2.10" 6514; }).systemd.services.victorialogs-secret-restart;
    in
    mkTableCheck "syslog-tls-secret-watchers" {
      "one watcher per file" =
        lib.attrNames withTls == [
          "victorialogs-secret-watch-syslog-tls-cert"
          "victorialogs-secret-watch-syslog-tls-key"
        ];
      "cert watcher watches the cert" =
        withTls.victorialogs-secret-watch-syslog-tls-cert.pathConfig.PathChanged == "/run/fake-cert.pem";
      "key watcher watches the key" =
        withTls.victorialogs-secret-watch-syslog-tls-key.pathConfig.PathChanged == "/run/fake-key.pem";
      "both trigger the restart helper" = lib.all (
        w: w.pathConfig.Unit == "victorialogs-secret-restart.service"
      ) (lib.attrValues withTls);
      "the helper try-restarts without blocking" =
        restart.serviceConfig.ExecStart
        == "${(eval { }).systemd.package}/bin/systemctl try-restart --no-block victorialogs.service";
      "no watcher without a tls slot" = watchers { tcp = slot "192.0.2.10" 5514; } == { };
      "no helper without a tls slot" =
        !((eval { tcp = slot "192.0.2.10" 5514; }).systemd.services ? victorialogs-secret-restart);
    };

  # --- firewall ---

  # The module opens a slot's port only when asked, in the list of its
  # transport (tls is tcp), and leaves what the operator already opened alone.
  open-firewall-adds-the-slot-port =
    let
      opened =
        syslog:
        let
          fw =
            (evalWith {
              services.victoriaStack.logs = {
                enable = true;
                inherit syslog;
              };
              networking.firewall = {
                allowedTCPPorts = [ 22 ];
                allowedUDPPorts = [ 123 ];
              };
            }).config.networking.firewall;
        in
        {
          tcp = lib.sort (a: b: a < b) fw.allowedTCPPorts;
          udp = lib.sort (a: b: a < b) fw.allowedUDPPorts;
        };
      open = s: s // { openFirewall = true; };
      untouched = {
        tcp = [ 22 ];
        udp = [ 123 ];
      };
    in
    mkTableCheck "syslog-open-firewall" {
      "off by default" =
        opened {
          udp = slot "0.0.0.0" 514;
          tcp = slot "0.0.0.0" 514;
          tls = tlsSlot "0.0.0.0" 6514;
        } == untouched;
      "udp slot" =
        opened { udp = open (slot "0.0.0.0" 514); } == {
          tcp = [ 22 ];
          udp = [
            123
            514
          ];
        };
      "tcp slot" =
        opened { tcp = open (slot "0.0.0.0" 514); } == {
          tcp = [
            22
            514
          ];
          udp = [ 123 ];
        };
      "tls slot opens tcp" =
        opened { tls = open (tlsSlot "0.0.0.0" 6514); } == {
          tcp = [
            22
            6514
          ];
          udp = [ 123 ];
        };
      "a custom port is the one opened" =
        opened { udp = open (slot "0.0.0.0" 5514); } == {
          tcp = [ 22 ];
          udp = [
            123
            5514
          ];
        };
      "only the slot that asks" =
        opened {
          udp = open (slot "0.0.0.0" 514);
          tcp = slot "0.0.0.0" 514;
        } == {
          tcp = [ 22 ];
          udp = [
            123
            514
          ];
        };
      "a disabled slot opens nothing" =
        opened {
          udp = (open (slot "0.0.0.0" 514)) // {
            enable = false;
          };
        } == untouched;
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
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(main, "victorialogs.service")
      wait_active(custom, "victorialogs.service")

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
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(machine, "victorialogs.service")
      machine.succeed("ss -lntH | grep -F '127.0.0.1:4202'")
      machine.succeed("ss -lunH | grep -F '127.0.0.1:4202'")
      resend_until_found(machine, "${send} --proto udp --port 4202 SAMEPORTMARK", "SAMEPORTMARK")
    '';
  };

  # TLS only encrypts: a client with no certificate is accepted, plaintext to
  # the TLS port is refused, and the plain tcp slot next to it stays plain
  # (the positional arrays line up). TLS 1.3 is the default minimum; an
  # `extraFlags` -syslog.tlsMinVersion opens it to 1.2.
  tls-listener-encrypts-and-has-no-client-auth = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-tls";

    containers.main = {
      imports = [
        module
        (tlsFilesFrom certOne)
      ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog = {
          tcp = slot "127.0.0.1" 5514;
          tls = (slot "127.0.0.1" 6514) // runtimeCert;
        };
      };
    };
    containers.old = {
      imports = [
        module
        (tlsFilesFrom certOne)
      ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog.tls = (slot "127.0.0.1" 6514) // runtimeCert;
        extraFlags = [ "-syslog.tlsMinVersion=TLS12" ];
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(main, "victorialogs.service")
      wait_active(old, "victorialogs.service")
      main.wait_for_open_port(5514)
      main.wait_for_open_port(6514)

      # The plain slot is still plain.
      main.succeed("${send} --proto tcp --port 5514 PLAINSLOTMARK")
      assert rows(main, "PLAINSLOTMARK")[0]["source"] == "syslog"

      # TLS with no client certificate is accepted and negotiates TLS 1.3.
      out = main.succeed("${send} --proto tls --port 6514 --cacert ${certOne}/cert.pem --format 5424 TLSOKMARK")
      assert "TLSv1.3" in out, out
      r = rows(main, "TLSOKMARK")[0]
      assert r["format"] == "rfc5424" and r["source"] == "syslog", r

      # Plaintext to the TLS port is not ingested; TLS to the plain port fails.
      main.succeed("${send} --proto tcp --port 6514 PLAINTOTLSMARK")
      main.wait_until_succeeds("journalctl -u victorialogs.service --no-pager | grep -F 'does not look like a TLS handshake'")
      main.fail("${send} --proto tls --port 5514 --cacert ${certOne}/cert.pem TLSTOPLAINMARK")
      # A later message proves the earlier ones had time to be stored.
      main.succeed("${send} --proto tls --port 6514 --cacert ${certOne}/cert.pem TLSAFTERMARK")
      rows(main, "TLSAFTERMARK")
      for marker in ("PLAINTOTLSMARK", "TLSTOPLAINMARK"):
          assert main.succeed(query_cmd("_msg:" + marker)).strip() == "", marker

      # TLS 1.2 is refused by default, accepted with -syslog.tlsMinVersion=TLS12.
      main.fail("${send} --proto tls --tls-max 1.2 --port 6514 --cacert ${certOne}/cert.pem TLS12REFUSEDMARK")
      old.wait_for_open_port(6514)
      out = old.succeed("${send} --proto tls --tls-max 1.2 --port 6514 --cacert ${certOne}/cert.pem TLS12MARK")
      assert "TLSv1.2" in out, out
      rows(old, "TLS12MARK")
    '';
  };

  # The unit reads a copy of the files, so replacing them must restart it:
  # the served certificate changes without anyone touching the unit.
  tls-cert-replacement-restarts-victorialogs = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-tls-rotation";

    containers.machine = {
      imports = [
        module
        (tlsFilesFrom certOne)
      ];
      environment.systemPackages = tools;
      services.victoriaStack.logs = {
        enable = true;
        syslog.tls = (slot "127.0.0.1" 6514) // runtimeCert;
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(machine, "victorialogs.service")
      machine.wait_for_open_port(6514)
      machine.wait_for_unit("victorialogs-secret-watch-syslog-tls-cert.path")
      machine.wait_for_unit("victorialogs-secret-watch-syslog-tls-key.path")

      def subject():
          return machine.succeed("echo | openssl s_client -connect 127.0.0.1:6514 2>/dev/null | openssl x509 -noout -subject")

      assert "syslog-test-one" in subject(), subject()
      was = machine.succeed("systemctl show -p InvocationID --value victorialogs.service").strip()

      # The helper has to be idle and the path units armed, or the change is not noticed.
      machine.wait_until_succeeds("systemctl show -p SubState --value victorialogs-secret-watch-syslog-tls-cert.path | grep -qx waiting")
      machine.succeed("cp ${certTwo}/key.pem /var/lib/syslog-tls/key.pem && cp ${certTwo}/cert.pem /var/lib/syslog-tls/cert.pem")

      machine.wait_until_succeeds("echo | openssl s_client -connect 127.0.0.1:6514 2>/dev/null | openssl x509 -noout -subject | grep -F syslog-test-two", timeout=180)
      now = machine.succeed("systemctl show -p InvocationID --value victorialogs.service").strip()
      assert now != was, "VictoriaLogs was not restarted"
      wait_active(machine, "victorialogs.service")
      machine.succeed("${send} --proto tls --port 6514 --cacert ${certTwo}/cert.pem ROTATEDMARK")
      rows(machine, "ROTATEDMARK")
    '';
  };

  # From another host: a plain listener on the wildcard is unreachable behind the
  # default firewall (the module opens nothing by itself), and reachable on all
  # three transports once the slots ask for openFirewall.
  cross-host-needs-open-firewall = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-cross-host";

    containers =
      let
        server = openFirewall: {
          virtualisation.vlans = [ 1 ];
          imports = [
            module
            (tlsFilesFrom certHosts)
          ];
          environment.systemPackages = tools;
          services.victoriaStack.logs = {
            enable = true;
            syslog = {
              udp = (slot "0.0.0.0" 514) // {
                inherit openFirewall;
                suppressExposureWarning = true;
              };
              tcp = (slot "0.0.0.0" 514) // {
                inherit openFirewall;
                suppressExposureWarning = true;
              };
              tls = (slot "0.0.0.0" 6514) // runtimeCert // { inherit openFirewall; };
            };
          };
        };
      in
      {
        sealed = server false;
        exposed = server true;
        client = {
          virtualisation.vlans = [ 1 ];
          environment.systemPackages = tools;
        };
      };

    testScript = ''
      ${testLib.waitActivePython}
      ${queryPython}
      import time

      def send_until_found(sender, server, send, marker):
          # A datagram sent before the route is up is simply lost; resend.
          for _ in range(30):
              sender.succeed(send)
              if server.execute(f"{query_cmd('_msg:' + marker)} | grep -F {marker}")[0] == 0:
                  return rows(server, marker)
              time.sleep(1)
          raise Exception(f"{marker} never arrived")

      start_all()
      for m in (sealed, exposed, client):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")
      wait_active(sealed, "victorialogs.service")
      wait_active(exposed, "victorialogs.service")
      client.succeed("ping -c 1 sealed && ping -c 1 exposed")

      # With openFirewall: udp, tcp and tls all arrive, labelled.
      cert = "--cacert ${certHosts}/cert.pem"
      for proto, extra in (("udp", ""), ("tcp", ""), ("tls", cert)):
          marker = f"EXPOSED{proto.upper()}MARK"
          send = f"${send} --proto {proto} --host exposed --port {6514 if proto == 'tls' else 514} {extra} {marker}"
          r = send_until_found(client, exposed, send, marker)[0]
          assert r["source"] == "syslog" and r["hostname"] == "testhost", r

      # Without it: nothing gets in, whatever the transport.
      client.fail("${send} --proto tcp --host sealed --port 514 SEALEDTCPMARK")
      client.fail(f"${send} --proto tls --host sealed --port 6514 {cert} SEALEDTLSMARK")
      for _ in range(3):
          client.succeed("${send} --proto udp --host sealed --port 514 SEALEDUDPMARK")
      # The listeners themselves are fine: a local sender is ingested right away,
      # so the absence above is the firewall.
      sealed.succeed("${send} --proto tcp --port 514 SEALEDLOCALMARK")
      rows(sealed, "SEALEDLOCALMARK")
      for marker in ("SEALEDTCPMARK", "SEALEDTLSMARK", "SEALEDUDPMARK"):
          assert sealed.succeed(query_cmd("_msg:" + marker)).strip() == "", marker
    '';
  };

  # Syslog rows sit in the default tenant, so the read tier that serves the
  # other log queries serves them too, and still wants a token.
  rows-are-readable-through-the-vmauth-read-tier = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-read-tier";

    containers.machine = {
      imports = [ module ];
      environment.systemPackages = tools;
      services.victoriaStack = {
        logs = {
          enable = true;
          syslog.tcp = (slot "127.0.0.1" 514) // {
            extraFields = {
              source = "firewall";
              site = "lab";
            };
          };
        };
        vmauth.readTokensFile = "${pkgs.writeText "syslog-read-tokens.yaml" ''
          tokens:
            - token: syslog-read-token-one # gitleaks:allow
        ''}";
      };
    };

    testScript = ''
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(machine, "victorialogs.service")
      wait_active(machine, "vmauth.service")
      machine.wait_for_open_port(4204)
      machine.succeed("${send} --proto tcp --port 514 --format 5424 READTIERMARK")
      rows(machine, "READTIERMARK")

      url = "http://127.0.0.1:4204/logs/select/logsql/query"
      auth = "-H 'Authorization: Bearer syslog-read-token-one'"
      machine.wait_until_succeeds(f"curl -sf {auth} {url} -d 'query=_msg:READTIERMARK' | grep -F READTIERMARK")
      out = machine.succeed(f"curl -sf {auth} {url} -d 'query=_msg:READTIERMARK'")
      r = [json.loads(l) for l in out.splitlines() if l.strip()][0]
      assert r["source"] == "firewall" and r["site"] == "lab" and r["format"] == "rfc5424", r

      code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {url} -d 'query=_msg:READTIERMARK'").strip()
      assert code == "401", code
    '';
  };

  # End to end, the way a user configures it: a stack with all three slots open
  # to the network, a sender on another host, real RFC 3164 and 5424 over udp,
  # tcp and TLS, a restart through systemctl, and every row read back through
  # vmauth's read tier with a read token.
  e2e-sender-to-vmauth-read-tier = pkgs.testers.nixosTest {
    name = "victoria-stack-syslog-e2e";

    containers.stack = scenarioStack true;
    containers.sender = {
      virtualisation.vlans = [ 1 ];
      environment.systemPackages = tools;
    };

    testScript = ''
      ${testLib.waitActivePython}
      ${queryPython}
      import time

      start_all()
      for m in (stack, sender):
          m.systemctl("start network-online.target")
          m.wait_for_unit("network-online.target")
      wait_active(stack, "victorialogs.service")
      wait_active(stack, "vmauth.service")
      stack.wait_for_open_port(4204)
      sender.succeed("ping -c 1 stack")

      url = "http://127.0.0.1:4204/logs/select/logsql/query"
      auth = "-H 'Authorization: Bearer syslog-e2e-read-token'"
      cert = "--cacert ${certStack}/cert.pem"

      def read_cmd(marker):
          return f"curl -sf {auth} {url} -d 'query=_msg:{marker}' | grep -F {marker}"

      def deliver(proto, fmt, marker):
          # Sent from the other host, read back through the real read tier.
          port = 6514 if proto == "tls" else 514
          extra = cert if proto == "tls" else ""
          cmd = f"${send} --proto {proto} --host stack --port {port} --format {fmt} {extra} {marker}"
          for _ in range(40):
              sender.succeed(cmd)
              if stack.execute(read_cmd(marker))[0] == 0:
                  out = stack.succeed(f"curl -sf {auth} {url} -d 'query=_msg:{marker}'")
                  return [json.loads(l) for l in out.splitlines() if l.strip()][0]
              time.sleep(1)
          raise Exception(f"{marker} never became readable through vmauth")

      def check_all(generation):
          for proto in ("udp", "tcp", "tls"):
              for fmt in ("3164", "5424"):
                  r = deliver(proto, fmt, f"E2E{proto.upper()}{fmt}G{generation}")
                  assert r["format"] == f"rfc{fmt}" and r["hostname"] == "testhost", r
                  if fmt == "3164":
                      assert r["app_name"] == "su" and r["proc_id"] == "1234" and r["level"] == "critical", r
                  else:
                      assert r["app_name"] == "evntslog" and r["msg_id"] == "ID47", r
                      assert r["exampleSDID@32473.iut"] == "3", r
                  if proto == "tls":
                      assert r["source"] == "edge" and r["site"] == "lab", r
                  else:
                      assert r["source"] == "syslog" and "site" not in r, r

      check_all(1)

      # A restart through systemd: the listeners come back and take new traffic.
      stack.succeed("systemctl restart victorialogs.service")
      wait_active(stack, "victorialogs.service")
      stack.wait_for_open_port(514)
      stack.wait_for_open_port(6514)
      check_all(2)
      assert "active" == stack.succeed("systemctl is-active victorialogs.service").strip()

      # The read tier still wants its token.
      code = stack.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {url} -d 'query=*'").strip()
      assert code == "401", code

      # The stack's own journal: nothing from the syslog listeners went wrong.
      stack.fail(
          "journalctl -u victorialogs.service --no-pager | grep -i syslog | grep -iE 'error|fatal|panic|cannot'"
      )
    '';
  };

  # The same scenario evaluated: the plain udp and tcp slots on the wildcard warn,
  # the tls slot does not, and the slots' own suppress option silences the
  # warning.
  e2e-exposure-warning-emitted-and-suppressible =
    let
      warnings =
        suppress:
        lib.filter (lib.hasInfix "services.victoriaStack.logs.syslog") (
          (evalWith { services.victoriaStack = scenarioServices suppress; }).config.warnings
        );
      loud = warnings false;
    in
    mkTableCheck "syslog-e2e-exposure-warning" {
      "udp warns" = lib.any (lib.hasInfix "logs.syslog.udp") loud;
      "tcp warns" = lib.any (lib.hasInfix "logs.syslog.tcp") loud;
      "tls does not" = !(lib.any (lib.hasInfix "logs.syslog.tls") loud);
      "suppressed is silent" = warnings true == [ ];
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
      ${testLib.waitActivePython}
      ${queryPython}
      start_all()
      wait_active(low, "victorialogs.service")
      low.wait_for_open_port(514)
      low.succeed("ss -lunH | grep -F ':514'")
      resend_until_found(low, "${send} --proto udp --port 514 LOWUDPMARK", "LOWUDPMARK")
      low.succeed("${send} --proto tcp --port 514 LOWTCPMARK")
      rows(low, "LOWTCPMARK")
      c = caps(low)
      for k in ("CapBnd", "CapEff", "CapAmb"):
          assert c[k] == "0000000000000400", (k, c)

      wait_active(high, "victorialogs.service")
      c = caps(high)
      for k in ("CapBnd", "CapEff", "CapAmb"):
          assert c[k] == "0000000000000000", (k, c)
    '';
  };
}
