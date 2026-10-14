{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) mkAssertionFiresCheck mkAssertionMessagesAreCheck mkNoAssertionsFireCheck;

  # Same throwaway fixture tests/grafana.nix uses -- nixpkgs' grafana
  # module requires a real secret_key file-provider, no silent default.
  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";

  # extraFlags that change addressing or auth are rejected (the readiness
  # check and self-push use plain http on the module's own address/path).
  # Each service is enabled alone, its flag list set to the one flag under test.
  flagServices = {
    metrics = { };
    logs = { };
    traces = { };
    vmauth = {
      # vmauth only activates with a backend behind it.
      services.victoriaStack.metrics.enable = true;
    };
  };
  commonBadFlags = [
    "-http.pathPrefix=/x"
    "--http.pathPrefix=/x"
    "-http.pathPrefix"
    "-tls"
    "--tls=true"
    "-tlsCertFile=/run/fake-cert.pem"
    "-tlsKeyFile=/run/fake-key.pem"
    "-httpAuth.username=someone"
    "-httpAuth.password=file:///run/fake-pass"
    # An entry of the -httpListenAddr family is positional with the module's own
    # -httpListenAddr: the proxy protocol made the readiness probe get a 400.
    "-httpListenAddr.useProxyProtocol=true"
    "--httpListenAddr.useProxyProtocol=true"
  ];
  badFlagsFor =
    svc:
    commonBadFlags
    ++ lib.optionals (svc == "vmauth") [
      "-httpListenAddr=127.0.0.1:18080"
      "--httpListenAddr=127.0.0.1:18080"
      "-httpInternalListenAddr=127.0.0.1:18081"
    ];
  flagModule =
    svc: flags:
    lib.recursiveUpdate flagServices.${svc} {
      services.victoriaStack.${svc} = {
        enable = true;
        extraFlags = flags;
      };
    };
  slug = lib.replaceStrings [ "/" "=" "." ":" ] [ "_" "-" "-" "-" ];
  extraFlagsChecks = lib.concatMapAttrs (
    svc: _:
    lib.listToAttrs (
      map (
        flag:
        lib.nameValuePair "${svc}-extraflags-rejects${slug flag}" (mkAssertionFiresCheck {
          name = "${svc}-extraflags-rejects${slug flag}";
          expectMessageSubstring = "extraFlags contains `${flag}`";
          module = flagModule svc [ flag ];
        })
      ) (badFlagsFor svc)
    )
    // {
      # Positive control: a flag that merely resembles a banned one
      # (http.maxGracefulShutdownDuration shares the http. prefix) must pass.
      "${svc}-extraflags-harmless-flag-is-fine" = mkNoAssertionsFireCheck {
        name = "${svc}-extraflags-harmless-flag-is-fine";
        module = flagModule svc [
          "-http.maxGracefulShutdownDuration=5s"
          "-maxConcurrentRequests=100"
        ];
      };
    }
  ) flagServices;
  # The snapshot oneshot POSTs without a key, so a flag that makes the service
  # demand one for its snapshot endpoint fails it every run.
  # `option` is the extraFlags list of the process serving the endpoint (the
  # metrics cluster's vmstorage, not the one behind listenAddress).
  snapshotKeyFlags = {
    metrics = {
      flag = "snapshotAuthKey";
      option = "storage.extraFlags";
    };
    logs = {
      flag = "partitionManageAuthKey";
      option = "extraFlags";
    };
    traces = {
      flag = "partitionManageAuthKey";
      option = "extraFlags";
    };
  };
  snapshotKeyChecks = lib.concatMapAttrs (
    svc:
    { flag, option }:
    let
      mod =
        enable: flags:
        lib.recursiveUpdate flagServices.${svc} {
          services.victoriaStack.${svc} = lib.recursiveUpdate {
            enable = true;
            snapshots.enable = enable;
          } (lib.setAttrByPath (lib.splitString "." option) flags);
        };
    in
    lib.listToAttrs (
      map
        (
          f:
          lib.nameValuePair "${svc}-snapshots-reject-key-flag${slug f}" (mkAssertionFiresCheck {
            name = "${svc}-snapshots-reject-key-flag${slug f}";
            expectMessageSubstring = "services.victoriaStack.${svc}.snapshots.enable is true but ${option} contains `${f}`";
            module = mod true [ f ];
          })
        )
        [
          "-${flag}=k"
          "--${flag}=k"
          "-${flag}"
        ]
    )
    // {
      "${svc}-snapshots-key-flag-is-fine-with-snapshots-off" = mkNoAssertionsFireCheck {
        name = "${svc}-snapshots-key-flag-is-fine-with-snapshots-off";
        module = mod false [ "-${flag}=k" ];
      };
      "${svc}-snapshots-similar-flags-are-fine" = mkNoAssertionsFireCheck {
        name = "${svc}-snapshots-similar-flags-are-fine";
        module = mod true [
          "-metricsAuthKey=k"
          "-deleteAuthKey=k"
          "-${flag}Extra=k"
        ];
      };
    }
  ) snapshotKeyFlags;
in
{
  nginx-requires-vmauth = mkAssertionMessagesAreCheck {
    name = "nginx-requires-vmauth";
    expected = [
      ''
        services.victoriaStack.nginx.enable requires
        services.victoriaStack.vmauth.enable = true AND at least one of
        metrics/logs/traces.enable = true -- nginx only ever
        reverse-proxies to vmauth, never directly to a raw backend port,
        so there is nothing for it to point at otherwise. vmauth.enable
        alone is not sufficient: the vmauth unit is only created when at
        least one backend is also enabled, so `vmauth.enable = true` with
        zero backends leaves nothing for nginx to reverse-proxy to.
      ''
    ];
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        # Forced off: vmauth would otherwise auto-enable (mkDefault true)
        # whenever a backend is on, which is exactly the case this
        # assertion needs to NOT be satisfied by auto-enable alone.
        vmauth.enable = lib.mkForce false;
        nginx.enable = true;
      };
    };
  };

  # vmauth.enable = true alone is not sufficient: vmauth.nix's own config
  # block only activates when a backend is also enabled, so vmauth.enable with
  # no backend produces no vmauth service for nginx to reverse-proxy to and
  # must still fail this assertion.
  nginx-requires-vmauth-with-a-real-backend = mkAssertionMessagesAreCheck {
    name = "nginx-requires-vmauth-with-a-real-backend";
    expected = [
      ''
        services.victoriaStack.nginx.enable requires
        services.victoriaStack.vmauth.enable = true AND at least one of
        metrics/logs/traces.enable = true -- nginx only ever
        reverse-proxies to vmauth, never directly to a raw backend port,
        so there is nothing for it to point at otherwise. vmauth.enable
        alone is not sufficient: the vmauth unit is only created when at
        least one backend is also enabled, so `vmauth.enable = true` with
        zero backends leaves nothing for nginx to reverse-proxy to.
      ''
    ];
    module = {
      services.victoriaStack = {
        vmauth.enable = true;
        nginx.enable = true;
        # metrics/logs/traces all left at their default (disabled) --
        # vmauth.enable = true here is structurally inert.
      };
    };
  };

  # An MCP server needs ITS OWN backend: the whole message is pinned (a bare
  # "mcp" substring matches any neighbouring assertion), and each has a control
  # with the backend on -- and one with only a DIFFERENT backend on, which is
  # still the same mistake.
  mcp-requires-own-backend = mkAssertionMessagesAreCheck {
    name = "mcp-requires-own-backend";
    module = {
      services.victoriaStack.metrics = {
        enable = false;
        mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.metrics.mcp.enable requires
        services.victoriaStack.metrics.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if
        metrics itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  logs-mcp-requires-own-backend = mkAssertionMessagesAreCheck {
    name = "logs-mcp-requires-own-backend";
    module = {
      services.victoriaStack.logs = {
        enable = false;
        mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.logs.mcp.enable requires
        services.victoriaStack.logs.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if logs
        itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  traces-mcp-requires-own-backend = mkAssertionMessagesAreCheck {
    name = "traces-mcp-requires-own-backend";
    module = {
      services.victoriaStack.traces = {
        enable = false;
        mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.traces.mcp.enable requires
        services.victoriaStack.traces.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if
        traces itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  # Only a different backend on: still no backend for this MCP server.
  logs-mcp-with-only-another-backend-still-fires = mkAssertionMessagesAreCheck {
    name = "logs-mcp-with-only-another-backend-still-fires";
    module = {
      services.victoriaStack = {
        traces.enable = true;
        logs.mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.logs.mcp.enable requires
        services.victoriaStack.logs.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if logs
        itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  metrics-mcp-with-only-another-backend-still-fires = mkAssertionMessagesAreCheck {
    name = "metrics-mcp-with-only-another-backend-still-fires";
    module = {
      services.victoriaStack = {
        logs.enable = true;
        metrics.mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.metrics.mcp.enable requires
        services.victoriaStack.metrics.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if
        metrics itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  traces-mcp-with-only-another-backend-still-fires = mkAssertionMessagesAreCheck {
    name = "traces-mcp-with-only-another-backend-still-fires";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        traces.mcp.enable = true;
      };
    };
    expected = [
      ''
        services.victoriaStack.traces.mcp.enable requires
        services.victoriaStack.traces.enable = true -- an mcp server
        proxies to one specific backend instance by construction; if
        traces itself is disabled there is nothing for it to connect to.
      ''
    ];
  };

  # Controls: each MCP server with its own backend (and no other) is fine.
  metrics-mcp-with-its-own-backend-is-fine = mkNoAssertionsFireCheck {
    name = "metrics-mcp-with-its-own-backend-is-fine";
    module.services.victoriaStack.metrics = {
      enable = true;
      mcp.enable = true;
    };
  };

  logs-mcp-with-its-own-backend-is-fine = mkNoAssertionsFireCheck {
    name = "logs-mcp-with-its-own-backend-is-fine";
    module.services.victoriaStack.logs = {
      enable = true;
      mcp.enable = true;
    };
  };

  traces-mcp-with-its-own-backend-is-fine = mkNoAssertionsFireCheck {
    name = "traces-mcp-with-its-own-backend-is-fine";
    module.services.victoriaStack.traces = {
      enable = true;
      mcp.enable = true;
    };
  };

  # --- vmauth.https certificate sources ---

  # ACME and explicit files are alternatives: naming a certificate AND
  # supplying a file is ambiguous, and one file without the other is half a pair.
  https-acme-together-with-a-cert-file-fires = mkAssertionMessagesAreCheck {
    name = "https-acme-together-with-a-cert-file-fires";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.https = {
          enable = true;
          acmeCertName = "example.test";
          certFile = "/run/fake-cert.pem";
        };
      };
      security.acme.certs."example.test" = { };
    };
    expected = [
      ''
        services.victoriaStack.vmauth.https.enable needs a certificate:
        set BOTH vmauth.https.certFile and vmauth.https.keyFile, OR
        vmauth.https.acmeCertName -- not both, and not just one of the
        two files.
      ''
    ];
  };

  https-cert-file-without-key-fires = mkAssertionMessagesAreCheck {
    name = "https-cert-file-without-key-fires";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.https = {
          enable = true;
          certFile = "/run/fake-cert.pem";
        };
      };
    };
    expected = [
      ''
        services.victoriaStack.vmauth.https.enable needs a certificate:
        set BOTH vmauth.https.certFile and vmauth.https.keyFile, OR
        vmauth.https.acmeCertName -- not both, and not just one of the
        two files.
      ''
    ];
  };

  # Controls: each valid way to supply the certificate is accepted.
  https-with-both-files-is-fine = mkNoAssertionsFireCheck {
    name = "https-with-both-files-is-fine";
    module.services.victoriaStack = {
      metrics.enable = true;
      vmauth.https = {
        enable = true;
        certFile = "/run/fake-cert.pem";
        keyFile = "/run/fake-key.pem";
      };
    };
  };

  https-with-an-acme-certificate-alone-is-fine = mkNoAssertionsFireCheck {
    name = "https-with-an-acme-certificate-alone-is-fine";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        vmauth.https = {
          enable = true;
          acmeCertName = "example.test";
        };
      };
      security.acme.certs."example.test" = { };
    };
  };

  listen-address-collision-between-two-backends-fires = mkAssertionFiresCheck {
    name = "listen-address-collision-between-two-backends-fires";
    expectMessageSubstring = "same listenAddress";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
        logs = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
      };
    };
  };

  listen-address-collision-between-mcp-and-backend-fires = mkAssertionFiresCheck {
    name = "listen-address-collision-between-mcp-and-backend-fires";
    expectMessageSubstring = "same listenAddress";
    module = {
      services.victoriaStack.metrics = {
        enable = true;
        listenAddress = "127.0.0.1:9000";
        mcp = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
      };
    };
  };

  # Control: a DISABLED service never binds, so sharing its address with an
  # enabled one is not a collision.
  listen-address-shared-with-a-disabled-service-is-fine = mkNoAssertionsFireCheck {
    name = "listen-address-shared-with-a-disabled-service-is-fine";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          listenAddress = "127.0.0.1:9000";
        };
        logs.listenAddress = "127.0.0.1:9000";
      };
    };
  };

  # Control: nginx + vmauth both on, mcp + its own backend both on -- no
  # assertion should fire.
  valid-configuration-no-assertions = mkNoAssertionsFireCheck {
    name = "valid-configuration-no-assertions";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        vmauth.enable = true;
        nginx.enable = true;
      };
    };
  };

  # Control for the three mcp-*-requires-vmauth assertions (tests/mcp.nix):
  # every MCP server on its own backend with vmauth on trips nothing. No MCP server
  # works without vmauth (docs/decisions/0023).
  mcp-with-vmauth-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "mcp-with-vmauth-is-not-an-assertion-failure";
    module = {
      services.victoriaStack = {
        metrics = {
          enable = true;
          mcp.enable = true;
        };
        logs = {
          enable = true;
          mcp.enable = true;
        };
        traces = {
          enable = true;
          mcp.enable = true;
        };
      };
    };
  };

  grafana-requires-grafana-service = mkAssertionFiresCheck {
    name = "grafana-requires-grafana-service";
    expectMessageSubstring = "services.grafana.enable";
    module = {
      services.victoriaStack.grafana.enable = true;
      # services.grafana.enable deliberately left at its default (false)
      # -- this module only provisions datasources, never enables Grafana
      # itself (docs/decisions/0010).
    };
  };

  # The datasources send a vmauth read token and go through vmauth
  # (docs/decisions/0029); each missing piece must stop the build instead of
  # leaving Grafana with a way to reach a backend directly or no credential.
  grafana-requires-read-token-file = mkAssertionFiresCheck {
    name = "grafana-requires-read-token-file";
    expectMessageSubstring = "grafana.readTokenFile";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        vmauth.readTokensFile = "/run/fake-read-tokens.yaml";
      };
      services.grafana.enable = true;
    };
  };

  grafana-requires-vmauth = mkAssertionFiresCheck {
    name = "grafana-requires-vmauth";
    expectMessageSubstring = "grafana.enable requires vmauth.enable";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        vmauth.enable = lib.mkForce false;
      };
      services.grafana.enable = true;
    };
  };

  grafana-requires-token-in-vmauth-read-tier = mkAssertionFiresCheck {
    name = "grafana-requires-token-in-vmauth-read-tier";
    expectMessageSubstring = "vmauth.readTokensFile";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        # vmauth.readTokensFile deliberately unset: no token Grafana sends
        # could be accepted.
      };
      services.grafana.enable = true;
    };
  };

  # Control: everything wired -- no assertion should fire.
  grafana-with-grafana-service-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "grafana-with-grafana-service-is-not-an-assertion-failure";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "/run/fake-grafana-token";
        };
        vmauth.readTokensFile = "/run/fake-read-tokens.yaml";
      };
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };
  };

  # ADR 0029: the token and vmauth requirements exist because Grafana provisions
  # datasources; with no backend nothing is provisioned, so none of them applies.
  # The converse is the same module with one backend switched on.
  grafana-without-a-backend-needs-no-token = mkNoAssertionsFireCheck {
    name = "grafana-without-a-backend-needs-no-token";
    module = {
      services.victoriaStack.grafana.enable = true;
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };
  };

  grafana-with-a-backend-and-no-token-fires = mkAssertionFiresCheck {
    name = "grafana-with-a-backend-and-no-token-fires";
    expectMessageSubstring = "grafana.readTokenFile must be set";
    module = {
      services.victoriaStack = {
        metrics.enable = true;
        grafana.enable = true;
        vmauth.readTokensFile = "/run/fake-read-tokens.yaml";
      };
      services.grafana = {
        enable = true;
        settings.security.secret_key = "$__file{${secretKeyFixture}}";
      };
    };
  };

  backend-tls-cert-requires-key = mkAssertionFiresCheck {
    name = "backend-tls-cert-requires-key";
    expectMessageSubstring = "certFile and .keyFile";
    module = {
      services.victoriaStack.vmauth.backendTls.certFile = "/run/fake-client-cert.pem";
      # keyFile deliberately left unset -- an incomplete mTLS pair.
    };
  };

  backend-tls-key-requires-cert = mkAssertionFiresCheck {
    name = "backend-tls-key-requires-cert";
    expectMessageSubstring = "certFile and .keyFile";
    module = {
      services.victoriaStack.vmauth.backendTls.keyFile = "/run/fake-client-key.pem";
      # certFile deliberately left unset -- an incomplete mTLS pair.
    };
  };

  # Control: both halves of the mTLS pair set together -- no assertion
  # should fire.
  backend-tls-cert-and-key-together-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "backend-tls-cert-and-key-together-is-not-an-assertion-failure";
    module = {
      services.victoriaStack.vmauth.backendTls = {
        certFile = "/run/fake-client-cert.pem";
        keyFile = "/run/fake-client-key.pem";
      };
    };
  };

  # Control: neither half set (the default) -- no assertion should fire.
  backend-tls-neither-cert-nor-key-is-not-an-assertion-failure = mkNoAssertionsFireCheck {
    name = "backend-tls-neither-cert-nor-key-is-not-an-assertion-failure";
    module = { };
  };

  # Every address option reaches shell scripts, unit files or nginx's config,
  # so it may hold only what a host:port holds. All options are set to one value
  # at a time; each must be named when the value is hostile and silent when not.
  address-options-accept-only-host-port-characters =
    let
      hostPortOptions = [
        "metrics.listenAddress"
        "logs.listenAddress"
        "traces.listenAddress"
        "metrics.mcp.listenAddress"
        "logs.mcp.listenAddress"
        "traces.mcp.listenAddress"
        "vmauth.listenAddress"
        "vmauth.internalListenAddress"
      ];
      ipOptions = [
        "vmauth.https.ipAddress"
        "vmauth.http.ipAddress"
        "logs.syslog.udp.ipAddress"
        "logs.syslog.tcp.ipAddress"
        "logs.syslog.tls.ipAddress"
      ];
      setAt =
        path: value:
        lib.setAttrByPath (
          [
            "services"
            "victoriaStack"
          ]
          ++ lib.splitString "." path
        ) value;
      everything =
        hostPort: ip:
        lib.foldl' lib.recursiveUpdate {
          services.victoriaStack = {
            metrics = {
              enable = true;
              mcp.enable = true;
            };
            logs = {
              enable = true;
              mcp.enable = true;
              syslog = {
                udp.enable = true;
                tcp.enable = true;
                tls = {
                  enable = true;
                  certFile = "/run/fake-cert.pem";
                  keyFile = "/run/fake-key.pem";
                };
              };
            };
            traces = {
              enable = true;
              mcp.enable = true;
            };
            vmauth = {
              https = {
                enable = true;
                certFile = "/run/fake-cert.pem";
                keyFile = "/run/fake-key.pem";
              };
              http.enable = true;
            };
          };
        } (map (o: setAt o hostPort) hostPortOptions ++ map (o: setAt o ip) ipOptions);
      namedFor =
        hostPort: ip:
        let
          failed = map (a: a.message) (
            builtins.filter (a: !a.assertion) (testLib.evalWith (everything hostPort ip)).config.assertions
          );
        in
        o: lib.any (lib.hasInfix "services.victoriaStack.${o} = ") failed;
      allOptions = hostPortOptions ++ ipOptions;
      verdicts =
        wantNamed: value:
        let
          named = namedFor value value;
        in
        lib.listToAttrs (
          map (
            o:
            lib.nameValuePair "${o} ${if wantNamed then "rejects" else "accepts"} ${builtins.toJSON value}" (
              named o == wantNamed
            )
          ) allOptions
        );
      hostile = [
        "127.0.0.1:9428;touch /tmp/PWNED"
        "a;b:1"
        "a b:1"
        "a$b:1"
        "a!b:1"
        "a(b):1"
        "a*b:1"
        "a=b:1"
        "a?b:1"
        "a@b:1"
        "a~b:1"
        "a,b:1"
        "127.0.0.1:9428 --evil"
        "$(id):1"
        "`id`:1"
        "a\"b:1"
        "a'b:1"
        "a\\b:1"
        "a{b}:1"
        "a|b:1"
        "a#b:1"
        "a\nb:1"
        "a&b:1"
        "a<b>:1"
        "a/b:1"
        ""
      ];
      accepted = [
        ":4201"
        "[::1]:4201"
        "localhost:4201"
        "0.0.0.0:4201"
        "[::]:4201"
        "127.0.0.1:4201"
        "::"
        "fe80::1%eth0"
        "host-name.example.com"
      ];
      checks = lib.foldl' (a: b: a // b) { } (
        map (verdicts true) hostile ++ map (verdicts false) accepted
      );
    in
    pkgs.runCommand "address-options-accept-only-host-port-characters" { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "address validation wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Grafana's own http_addr becomes nginx's proxy_pass (and takes part in the
  # collision check), so it gets the same character check as the module's
  # address options -- but empty stays legal (Grafana: all interfaces).
  grafana-http-addr-accepts-only-host-characters =
    let
      failedFor =
        grafanaEnable: addr:
        map (a: a.message) (
          builtins.filter (a: !a.assertion)
            (testLib.evalWith {
              services.grafana = {
                enable = true;
                settings = {
                  security.secret_key = "$__file{${secretKeyFixture}}";
                  server.http_addr = addr;
                };
              };
              services.victoriaStack = {
                metrics.enable = true;
                grafana.enable = grafanaEnable;
                nginx.enable = true;
              };
            }).config.assertions
        );
      named =
        grafanaEnable: addr:
        lib.any (lib.hasInfix "services.grafana.settings.server.http_addr = ") (
          failedFor grafanaEnable addr
        );
      rejected = [
        "a$host;b"
        "a b"
        "a/b"
        "a,b"
        "a\nb"
      ];
      accepted = [
        "127.0.0.1"
        "0.0.0.0"
        "::1"
        "localhost"
        "grafana.example.com"
        ""
      ];
      checks =
        lib.listToAttrs (
          map (a: lib.nameValuePair "rejects ${builtins.toJSON a}" (named true a)) rejected
          ++ map (a: lib.nameValuePair "accepts ${builtins.toJSON a}" (!named true a)) accepted
        )
        // {
          # Nothing reads http_addr when the module does not wire Grafana up.
          "not checked while victoriaStack.grafana is off" = !named false "a$host;b";
        };
    in
    pkgs.runCommand "grafana-http-addr-accepts-only-host-characters" { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "grafana http_addr validation wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # dataDir is written into tmpfiles rules, ReadWritePaths, RequiresMountsFor and
  # -storageDataPath, where a space, `%` or quote changes the meaning; only a
  # plain absolute path may pass, and only for an enabled service.
  datadir-accepts-only-plain-absolute-paths =
    let
      services = [
        "metrics"
        "logs"
        "traces"
      ];
      setup = enabled: svc: value: {
        services.victoriaStack.${svc} = {
          enable = enabled;
          dataDir = value;
        };
      };
      namedFor =
        enabled: svc: value:
        lib.any (lib.hasInfix "services.victoriaStack.${svc}.dataDir = ") (
          map (a: a.message) (
            builtins.filter (a: !a.assertion) (testLib.evalWith (setup enabled svc value)).config.assertions
          )
        );
      rejected = [
        "/srv/my data/100%"
        "/srv/a b"
        "/srv/100%"
        "/srv/a\nb"
        "/srv/\"q\""
        "/srv/'q'"
        "/srv/a;b"
        "/srv/$x"
        "/srv/*"
        "/srv/a:b"
        "/srv/a\\b"
        "/srv/é"
        "/srv/a\tb"
      ];
      accepted = [
        "/var/lib/victoria-metrics"
        "/var/lib/victoria-logs"
        "/var/lib/victoria-traces"
        "/srv/victoria-metrics"
        "/data/vm_1.2-x"
        "/a"
      ];
      verdicts =
        wantNamed: value:
        lib.listToAttrs (
          map (svc: {
            name = "${svc} ${builtins.toJSON value}";
            value = namedFor true svc value == wantNamed;
          }) services
        );
      # A disabled service never renders the unit, so it must not fail the build.
      disabled = lib.listToAttrs (
        map (svc: {
          name = "disabled ${svc}";
          value = !namedFor false svc "/srv/my data/100%";
        }) services
      );
      checks = lib.foldl' (a: b: a // b) disabled (
        map (verdicts true) rejected ++ map (verdicts false) accepted
      );
    in
    pkgs.runCommand "datadir-accepts-only-plain-absolute-paths" { } (
      let
        failed = lib.filterAttrs (_: ok: !ok) checks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "dataDir validation wrong for: ${builtins.toJSON (builtins.attrNames failed)}"
    );
}
// extraFlagsChecks
// snapshotKeyChecks
