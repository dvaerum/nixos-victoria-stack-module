{ pkgs, nixosModule }:

# Per-tenant Grafana datasources (tenants.<name>.grafanaOrgId + readTokenFile,
# docs/decisions/0032-tenants-in-token-files.md): the provisioned settings and assertions (L1), and the
# real stack with the runbook's steps (L3, a VM because it switches
# configurations, like the operator's deploy does).
let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib)
    evalWith
    mkAssertionFiresCheck
    mkNoAssertionsFireCheck
    ;

  secretKeyFixture = pkgs.writeText "grafana-secret-key" "test-fixture-secret-key-not-real";
  grafanaConsumerConfig = {
    services.grafana = {
      enable = true;
      settings.security.secret_key = "$__file{${secretKeyFixture}}";
    };
  };

  # grafana.enable needs the main read token and its vmauth entry.
  mainWiring = {
    services.victoriaStack = {
      grafana.readTokenFile = "${testLib.grafanaReadTokenFile}";
      vmauth.readTokensFile = "${testLib.vmauthReadTokensWithGrafana}";
    };
  };

  tenantsModule =
    {
      tenants,
      backends ? {
        metrics.enable = true;
        logs.enable = true;
        traces.enable = true;
      },
      grafanaEnable ? true,
    }:
    {
      imports = [ mainWiring ];
      services.grafana.enable = true;
      services.victoriaStack = backends // {
        grafana.enable = grafanaEnable;
        inherit tenants;
      };
    };

  tenant =
    accountId: orgId: tokenFile:
    {
      inherit accountId;
    }
    // lib.optionalAttrs (orgId != null) { grafanaOrgId = orgId; }
    // lib.optionalAttrs (tokenFile != null) { readTokenFile = tokenFile; };

  tokenA = "/run/secrets/grafana-a-token";
  tokenB = "/run/secrets/grafana-b-token";

  # ---- L1: the provisioned settings -------------------------------------
  settingsOf = evaluated: evaluated.config.services.grafana.provision.datasources.settings;
  vmauthUrl = "http://127.0.0.1:4204";
  headerFor = n: "$__file{/run/grafana/vmauth-authorization-${n}}";
  expectedFor = n: org: [
    {
      name = "VictoriaMetrics (${n})";
      type = "victoriametrics-metrics-datasource";
      uid = "vm-${n}";
      url = "${vmauthUrl}/metrics";
      isDefault = true;
      orgId = org;
      access = "proxy";
      editable = false;
      jsonData.httpHeaderName1 = "Authorization";
      secureJsonData.httpHeaderValue1 = headerFor n;
    }
    {
      name = "VictoriaLogs (${n})";
      type = "victoriametrics-logs-datasource";
      uid = "vl-${n}";
      url = "${vmauthUrl}/logs";
      isDefault = false;
      orgId = org;
      access = "proxy";
      editable = false;
      jsonData.httpHeaderName1 = "Authorization";
      secureJsonData.httpHeaderValue1 = headerFor n;
    }
    {
      name = "VictoriaTraces (${n})";
      type = "jaeger";
      uid = "vt-${n}";
      url = "${vmauthUrl}/traces/select/jaeger";
      isDefault = false;
      orgId = org;
      access = "proxy";
      editable = false;
      jsonData.httpHeaderName1 = "Authorization";
      secureJsonData.httpHeaderValue1 = headerFor n;
    }
  ];

  tokenInStore = pkgs.writeText "tenant-token-in-store" "tenant-token-fixture-value"; # gitleaks:allow

  provisioning =
    let
      evaluated = evalWith (tenantsModule {
        tenants = {
          a = tenant 1 2 tokenA;
          b = tenant 2 3 "${tokenInStore}";
          c = tenant 3 null null;
        };
      });
      settings = settingsOf evaluated;
      sc = evaluated.config.systemd.services.grafana.serviceConfig;
      inOrg = org: lib.filter (d: (d.orgId or 1) == org) settings.datasources;
      main = lib.filter (d: !(d ? orgId)) settings.datasources;
      watch = evaluated.config.systemd.paths.grafana-tenant-token-watch.pathConfig or null;
      checks = {
        "tenant a's datasources are in org 2, with its own header file" = inOrg 2 == expectedFor "a" 2;
        "tenant b's datasources are in org 3" = inOrg 3 == expectedFor "b" 3;
        "the main datasources keep their uids and no orgId" =
          map (d: d.uid) main == [
            "victoriametrics-ds"
            "victorialogs-ds"
            "victoriatraces-ds"
          ];
        "nothing for the tenant without the options" =
          lib.length settings.datasources == 9
          && !(lib.any (d: lib.hasInfix "(c)" d.name || lib.hasSuffix "-c" d.uid) settings.datasources);
        "every org has its own default" =
          map (d: d.isDefault) (inOrg 2) == [
            true
            false
            false
          ];
        "deleteDatasources covers each tenant's org" =
          lib.filter (d: d ? orgId && d.orgId != 1) settings.deleteDatasources == [
            {
              name = "VictoriaMetrics (a)";
              orgId = 2;
            }
            {
              name = "VictoriaLogs (a)";
              orgId = 2;
            }
            {
              name = "VictoriaTraces (a)";
              orgId = 2;
            }
            {
              name = "VictoriaMetrics (b)";
              orgId = 3;
            }
            {
              name = "VictoriaLogs (b)";
              orgId = 3;
            }
            {
              name = "VictoriaTraces (b)";
              orgId = 3;
            }
          ];
        "a credential per tenant next to the main one" =
          sc.LoadCredential == [
            "grafana-read-token:${testLib.grafanaReadTokenFile}"
            "grafana-tenant-a:${tokenA}"
            "grafana-tenant-b:${tokenInStore}"
          ];
        "the tenants' files are watched and trigger the same restart helper" =
          watch == {
            PathChanged = [
              tokenA
              "${tokenInStore}"
            ];
            Unit = "grafana-secret-restart.service";
          };
        "no default-datasource warning from the per-org defaults" =
          !(lib.any (lib.hasInfix "isDefault") evaluated.config.warnings);
        "the token value is not in the settings or the unit" =
          let
            text = builtins.toJSON [
              settings
              sc
              watch
            ];
          in
          !(lib.hasInfix "tenant-token-fixture-value" text);
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    pkgs.runCommand "grafana-tenant-orgs-provisioning-is-per-org-with-the-tenants-token" { } (
      if failed == [ ] then
        "echo OK > $out"
      else
        throw "tenant datasource provisioning broken: ${builtins.toJSON failed}"
    );

  # Only the backends that are enabled get a tenant datasource.
  followsBackends =
    let
      settings = settingsOf (
        evalWith (tenantsModule {
          tenants.a = tenant 1 2 tokenA;
          backends.logs.enable = true;
        })
      );
      names = map (d: d.name) (lib.filter (d: (d.orgId or 1) == 2) settings.datasources);
    in
    pkgs.runCommand "grafana-tenant-orgs-follow-the-enabled-backends" { } (
      if names == [ "VictoriaLogs (a)" ] then
        "echo OK > $out"
      else
        throw "expected only the logs datasource, got ${builtins.toJSON names}"
    );

  # Tenants without the options, or Grafana off: nothing at all.
  nothingWithoutOptIn =
    let
      checks =
        lib.mapAttrs
          (
            _: args:
            let
              evaluated = evalWith (tenantsModule args);
              sc = evaluated.config.systemd.services.grafana.serviceConfig;
            in
            !(lib.any (lib.hasPrefix "grafana-tenant-") (sc.LoadCredential or [ ]))
            && !(evaluated.config.systemd.paths ? grafana-tenant-token-watch)
            && !(lib.any (d: d ? orgId) (settingsOf evaluated).datasources or [ ])
          )
          {
            "tenants without the options" = {
              tenants.a = tenant 1 null null;
            };
            "grafana.enable off" = {
              tenants.a = tenant 1 2 tokenA;
              grafanaEnable = false;
            };
          };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    pkgs.runCommand "grafana-tenant-orgs-nothing-without-the-options" { } (
      if failed == [ ] then "echo OK > $out" else throw "provisioned anyway: ${builtins.toJSON failed}"
    );

  # `%` is a systemd specifier and is doubled; `:` needs nothing.
  escapesPaths =
    let
      evaluated = evalWith (tenantsModule {
        tenants.a = tenant 1 2 "/run/s/c%h:x";
      });
      sc = evaluated.config.systemd.services.grafana.serviceConfig;
      watch = evaluated.config.systemd.paths.grafana-tenant-token-watch.pathConfig.PathChanged or null;
    in
    pkgs.runCommand "grafana-tenant-orgs-escape-the-token-path" { } (
      if lib.elem "grafana-tenant-a:/run/s/c%%h:x" sc.LoadCredential && watch == [ "/run/s/c%%h:x" ] then
        "echo OK > $out"
      else
        throw "path not escaped: ${
          builtins.toJSON [
            sc.LoadCredential
            watch
          ]
        }"
    );

  # ---- L1: assertions ---------------------------------------------------
  repeat = n: c: lib.concatStrings (lib.genList (_: c) n);
  rejectCases = {
    org-id-without-token-file = {
      tenants.a = tenant 1 2 null;
      fragment = "services.victoriaStack.tenants.a: grafanaOrgId and readTokenFile go together";
    };
    token-file-without-org-id = {
      tenants.a = tenant 1 null tokenA;
      fragment = "services.victoriaStack.tenants.a: grafanaOrgId and readTokenFile go together";
    };
    duplicate-org-id = {
      tenants = {
        a = tenant 1 2 tokenA;
        b = tenant 2 2 tokenB;
      };
      fragment = "services.victoriaStack.tenants.a and services.victoriaStack.tenants.b both use grafanaOrgId 2";
    };
    main-org-id = {
      tenants.a = tenant 1 1 tokenA;
      fragment = "services.victoriaStack.tenants.a.grafanaOrgId is 1, the organisation the main";
    };
    relative-token-path = {
      tenants.a = tenant 1 2 "secrets/a-token";
      fragment = "services.victoriaStack.tenants.a.readTokenFile is \"secrets/a-token\": it must be an";
    };
    empty-token-path = {
      tenants.a = tenant 1 2 "";
      fragment = "services.victoriaStack.tenants.a.readTokenFile is \"\": it must be an";
    };
    newline-in-token-path = {
      tenants.a = tenant 1 2 "/run/secrets/a\n/etc/shadow";
      fragment = "it must be an\nabsolute path on a single line";
    };
    name-too-long-for-a-uid = {
      tenants.${repeat 38 "a"} = tenant 1 2 tokenA;
      fragment = "the name is longer than 37 characters";
    };
  };
  acceptCases = {
    both-options = {
      a = tenant 1 2 tokenA;
    };
    neither-option = {
      a = tenant 1 null null;
    };
    distinct-orgs-and-tokens = {
      a = tenant 1 2 tokenA;
      b = tenant 2 3 tokenB;
      c = tenant 3 null null;
    };
    longest-name = {
      ${repeat 37 "a"} = tenant 1 2 tokenA;
    };
    odd-but-valid-token-path = {
      a = tenant 1 2 "/run/s/c%h:x y";
    };
    large-org-id = {
      a = tenant 1 4294967295 tokenA;
    };
  };

  typeAccepts =
    orgId:
    (builtins.tryEval (
      builtins.deepSeq
        (evalWith (tenantsModule {
          tenants.a = tenant 1 orgId tokenA;
        })).config.services.victoriaStack.tenants.a.grafanaOrgId
        true
    )).success;
  orgIdTypeRefuses =
    let
      wrongly = lib.filter typeAccepts [
        0
        (-1)
        "2"
        1.5
        true
      ];
    in
    pkgs.runCommand "grafana-tenant-orgs-org-id-type-refuses-non-positive-and-non-integers" { } (
      if typeAccepts 2 && wrongly == [ ] then
        "echo OK > $out"
      else
        throw "accepted but should be refused: ${builtins.toJSON wrongly}"
    );

  # ---- L3: the runbook, step by step in a VM -----------------------------
  tokenFixtureA = "tenant-a-grafana-token"; # gitleaks:allow
  tokenFixtureB = "tenant-b-grafana-token"; # gitleaks:allow
  secretDir = "/var/lib/grafana-tenant-secrets";
  tenantsWithOrgs = org: {
    a = {
      grafanaOrgId = org.a;
      readTokenFile = "${secretDir}/a";
    };
    b = {
      grafanaOrgId = org.b;
      readTokenFile = "${secretDir}/b";
    };
  };

  # The Grafana API helpers both boot tests share (`machine` is the VM).
  grafanaPython = ''
    GRAFANA = "http://127.0.0.1:3000"
    ADMIN = "-u admin:admin"  # gitleaks:allow


    def grafana(path, org=None, method="GET", data=None, extra=""):
        cmd = f"curl -s -g -w '\\n%{{http_code}}' {ADMIN} -X {method} {extra} "
        if org is not None:
            cmd += f"-H 'X-Grafana-Org-Id: {org}' "
        if data is not None:
            cmd += f"-H 'Content-Type: application/json' -d {shlex.quote(data)} "
        out = machine.succeed(cmd + shlex.quote(GRAFANA + path))
        body, code = out.rsplit("\n", 1)
        return code.strip(), body


    def datasources(org):
        code, body = grafana("/api/datasources", org)
        assert code == "200", (org, code, body)
        return {d["uid"]: d["name"] for d in json.loads(body)}


    def proxy(org, uid, path, form=None):
        extra = f"--data-urlencode {shlex.quote(form)}" if form else ""
        return grafana(f"/api/datasources/proxy/uid/{uid}{path}", org, "POST" if form else "GET", None, extra)


    def eventually(fn, expected, what, tries=60):
        for _ in range(tries):
            if fn() == expected:
                return
            time.sleep(1)
        assert fn() == expected, (what, fn())
  '';

  # Metrics datasources of the tenant orgs on the real cluster: the data each
  # tenant wrote with its own write token is visible only through that tenant's
  # org datasource, over the same vmauth /metrics read tier as the main one.
  metricsRunbook = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-tenant-orgs-metrics";

    nodes.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
      ];
      virtualisation.memorySize = 3072;
      services.victoriaStack = {
        metrics.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "${testLib.grafanaReadTokenFile}";
        };
        tenants = {
          a.accountId = 1;
          b.accountId = 2;
        };
        vmauth = {
          writeTokensFile = "${pkgs.writeText "write.yaml" ''
            tokens:
              - token: write-main # gitleaks:allow
              - token: write-a # gitleaks:allow
                tenant: a
              - token: write-b # gitleaks:allow
                tenant: b
          ''}";
          readTokensFile = "${pkgs.writeText "read.yaml" ''
            tokens:
              - token: ${testLib.grafanaReadToken}
              - token: ${tokenFixtureA}
                tenant: a
              - token: ${tokenFixtureB}
                tenant: b
          ''}";
        };
      };

      specialisation.with-orgs.configuration.services.victoriaStack.tenants = tenantsWithOrgs {
        a = 2;
        b = 3;
      };
    };

    testScript = ''
      import json
      import shlex
      import time
      import urllib.parse
      ${testLib.waitActivePython}

      start_all()
      for unit in ["vmstorage", "vminsert", "vmselect", "vmauth", "grafana"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(3000)
      machine.wait_for_open_port(4204)

      ${grafanaPython}

      # One series per tenant, written through that tenant's own write token
      # (OTLP, vmauth stamps the tenant); tenant 0 through the plain one.
      WRITERS = {"write-main": "probe_m_0", "write-a": "probe_m_a", "write-b": "probe_m_b"}
      for token, name in WRITERS.items():
          machine.succeed(f"${testLib.otlpMetricGenerator}/bin/gen-otlp-metric {name} 1 > /tmp/m.bin")
          out = machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -H 'Authorization: Bearer {token}' "
              "-H 'Content-Type: application/x-protobuf' --data-binary @/tmp/m.bin "
              "http://127.0.0.1:4204/opentelemetry/v1/metrics"
          )
          assert out == "200", (token, out)

      # Runbook steps 2 and 3: the orgs and the tenants' token files, then the options.
      for name, expected in [("team-a", 2), ("team-b", 3)]:
          code, body = grafana("/api/orgs", None, "POST", json.dumps({"name": name}))
          assert code == "200" and json.loads(body)["orgId"] == expected, (code, body)
      machine.succeed(
          "install -d -m 0700 ${secretDir}; "
          "printf %s ${tokenFixtureA} > ${secretDir}/a; printf %s ${tokenFixtureB} > ${secretDir}/b; "
          "chmod 0600 ${secretDir}/a ${secretDir}/b"
      )
      machine.succeed("/run/current-system/specialisation/with-orgs/bin/switch-to-configuration test")
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)
      machine.wait_until_succeeds(f"curl -sf {ADMIN} {GRAFANA}/api/health")

      assert datasources(2) == {"vm-a": "VictoriaMetrics (a)"}, datasources(2)
      assert datasources(3) == {"vm-b": "VictoriaMetrics (b)"}, datasources(3)
      assert datasources(1) == {"victoriametrics-ds": "VictoriaMetrics"}, datasources(1)

      # Runbook step 4b through the datasource proxy. An old time= and a start
      # window keep reads clear of -search.latencyOffset (~30 s); the polling
      # waits for the flush.
      def q(params):
          return urllib.parse.urlencode(params, safe="[]")

      MATCH = {"match[]": '{__name__=~"probe_m_.*"}'}

      def metrics(org, uid):
          start = int(time.time()) - 3600
          out = {}
          for key, path, params in [
              ("names", "/api/v1/label/__name__/values", {**MATCH, "start": start}),
              ("series", "/api/v1/series", {**MATCH, "start": start}),
              ("query", "/api/v1/query", {"query": '{__name__=~"probe_m_.*"}', "time": int(time.time())}),
          ]:
              code, body = proxy(org, uid, f"{path}?{q(params)}")
              assert code == "200", (org, uid, path, code, body)
              data = json.loads(body)["data"]
              if key == "series":
                  data = [s["__name__"] for s in data]
              elif key == "query":
                  data = [r["metric"]["__name__"] for r in data["result"]]
              out[key] = sorted(data)
          return out

      def only(name):
          return {"names": [name], "series": [name], "query": [name]}

      eventually(lambda: metrics(2, "vm-a"), only("probe_m_a"), "org 2 metrics", 180)
      eventually(lambda: metrics(3, "vm-b"), only("probe_m_b"), "org 3 metrics", 180)
      # The main datasource sends the main token: tenant 0 only.
      assert metrics(1, "victoriametrics-ds") == only("probe_m_0"), metrics(1, "victoriametrics-ds")
      # A tenant's datasource does not exist in another org, for the API and the proxy.
      for org, uid in [(2, "vm-b"), (3, "vm-a"), (1, "vm-a"), (2, "victoriametrics-ds"), (2, "vm-main")]:
          assert grafana(f"/api/datasources/uid/{uid}", org)[0] == "404", (org, uid)
          assert proxy(org, uid, "/api/v1/labels")[0] == "404", (org, uid)
    '';
  };

  runbook = pkgs.testers.nixosTest {
    name = "victoria-stack-grafana-tenant-orgs-runbook";

    nodes.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
        grafanaConsumerConfig
      ];
      virtualisation.memorySize = 2048;
      services.victoriaStack = {
        logs.enable = true;
        traces.enable = true;
        grafana = {
          enable = true;
          readTokenFile = "${testLib.grafanaReadTokenFile}";
        };
        # Runbook step 1: the tenants and their vmauth tokens, no Grafana options yet.
        tenants = {
          a.accountId = 1;
          b.accountId = 2;
        };
        vmauth = {
          writeTokensFile = "${pkgs.writeText "write.yaml" ''
            tokens:
              - token: write-a # gitleaks:allow
                tenant: a
              - token: write-b # gitleaks:allow
                tenant: b
          ''}";
          readTokensFile = "${pkgs.writeText "read.yaml" ''
            tokens:
              - token: ${testLib.grafanaReadToken}
              - token: ${tokenFixtureA}
                tenant: a
              - token: ${tokenFixtureB}
                tenant: b
          ''}";
        };
      };

      # Runbook step 3 with an org that does not exist, and with the orgs
      # created in step 2.
      specialisation.missing-org.configuration.services.victoriaStack.tenants = tenantsWithOrgs {
        a = 4;
        b = 5;
      };
      specialisation.with-orgs.configuration.services.victoriaStack.tenants = tenantsWithOrgs {
        a = 2;
        b = 3;
      };
    };

    testScript = ''
      import json
      import shlex
      import time
      ${testLib.waitActivePython}

      start_all()
      for unit in ["victorialogs", "victoriatraces", "vmauth", "grafana"]:
          wait_active(machine, f"{unit}.service")
      machine.wait_for_open_port(3000)
      machine.wait_for_open_port(4204)

      VMAUTH = "http://127.0.0.1:4204"
      ${grafanaPython}


      def vmauth(path, token, headers, data):
          hdrs = " ".join(f"-H {shlex.quote(h)}" for h in headers)
          out = machine.succeed(
              f"curl -s -w '\\n%{{http_code}}' -X POST -H {shlex.quote('Authorization: Bearer ' + token)} "
              f"{hdrs} --data-binary {shlex.quote(data)} {shlex.quote(VMAUTH + path)}"
          )
          return out.rsplit("\n", 1)[1].strip()


      # Data of both tenants, written with each tenant's write token.
      for token, msg in [("write-a", "log-a"), ("write-b", "log-b")]:
          body = f"MESSAGE={msg}\n__REALTIME_TIMESTAMP={int(time.time())}000000\n_HOSTNAME=h\n\n"
          assert vmauth("/insert/journald/upload?_stream_fields=_HOSTNAME", token,
                        ["Content-Type: application/vnd.fdo.journal"], body) == "200"
      now = time.time_ns()
      for n, (token, service) in enumerate([("write-a", "svc-a"), ("write-b", "svc-b")], start=1):
          span = json.dumps({"resourceSpans": [{
              "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
              "scopeSpans": [{"spans": [{
                  "traceId": f"{n:032x}", "spanId": f"{n:016x}", "name": "op", "kind": 1,
                  "startTimeUnixNano": str(now), "endTimeUnixNano": str(now)}]}]}]})
          assert vmauth("/insert/opentelemetry/v1/traces", token,
                        ["Content-Type: application/json"], span) == "200"

      # Runbook step 1 only: Grafana runs, the main org has the main datasources and
      # no tenant datasource exists anywhere.
      assert set(datasources(None).values()) == {"VictoriaLogs", "VictoriaTraces"}
      machine.fail("ls /run/grafana/vmauth-authorization-a /run/grafana/vmauth-authorization-b")

      # The tenants' token files, as the operator's secrets mechanism would place them.
      machine.succeed(
          "install -d -m 0700 ${secretDir}; "
          "printf %s ${tokenFixtureA} > ${secretDir}/a; printf %s ${tokenFixtureB} > ${secretDir}/b; "
          "chmod 0600 ${secretDir}/a ${secretDir}/b"
      )

      # What Grafana does for an org that does not exist: provisioning fails and
      # Grafana restarts in a loop, so its API (and the org-creation call) is
      # unreachable. The org must therefore exist BEFORE grafanaOrgId is set.
      # switch-to-configuration exits non-zero when a unit fails to start; here
      # that is the outcome under test and the journal below is what is asserted.
      machine.execute("/run/current-system/specialisation/missing-org/bin/switch-to-configuration test")
      machine.wait_until_succeeds(
          "journalctl -u grafana.service --no-pager | grep -F '[org.notFound] failed to get org by ID: 4'",
          timeout=180,
      )
      restarts = int(machine.succeed("systemctl show -p NRestarts --value grafana.service"))
      machine.wait_until_succeeds(
          f"test \"$(systemctl show -p NRestarts --value grafana.service)\" -ge {restarts + 2}", timeout=180
      )

      # Back to step 1's configuration: Grafana runs again.
      machine.succeed("$(readlink -f /run/booted-system)/bin/switch-to-configuration test")
      # The switch stops the crash loop mid-start, which can leave Grafana's DB
      # lock (oss-ac-basic-role-seeder) behind: the next starts exit 1 until it
      # expires and use up the unit's start limit, leaving it failed for good
      # while the port never opens. Reset and start it again, as an operator would.
      deadline = time.monotonic() + 300
      while machine.execute(f"curl -sf {ADMIN} {GRAFANA}/api/health")[0] != 0:
          state = machine.succeed("systemctl show -p ActiveState --value grafana.service").strip()
          if state == "failed":
              machine.succeed("systemctl reset-failed grafana.service; systemctl start --no-block grafana.service")
          if time.monotonic() > deadline:
              _, journal = machine.execute("journalctl -u grafana.service -n 30 --no-pager")
              assert False, f"Grafana not healthy 300s after the switch back ({state}); journal:\n{journal}"
          time.sleep(2)

      # Runbook step 2: create the orgs through the API.
      for name, expected in [("team-a", 2), ("team-b", 3)]:
          code, body = grafana("/api/orgs", None, "POST", json.dumps({"name": name}))
          assert code == "200" and json.loads(body)["orgId"] == expected, (code, body)

      # Runbook step 3: set grafanaOrgId and readTokenFile, deploy.
      machine.succeed("/run/current-system/specialisation/with-orgs/bin/switch-to-configuration test")
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)
      machine.wait_until_succeeds(f"curl -sf {ADMIN} {GRAFANA}/api/health")

      # Runbook step 4a (Connections > Data sources): each org lists its own datasources.
      assert datasources(2) == {"vl-a": "VictoriaLogs (a)", "vt-a": "VictoriaTraces (a)"}, datasources(2)
      assert datasources(3) == {"vl-b": "VictoriaLogs (b)", "vt-b": "VictoriaTraces (b)"}, datasources(3)
      assert set(datasources(1).values()) == {"VictoriaLogs", "VictoriaTraces"}

      # Runbook step 4b (Explore): queries through each org's datasources see only that tenant.
      def log_rows(org, uid):
          code, body = proxy(org, uid, "/select/logsql/query", "query=*")
          assert code == "200", (org, uid, code, body)
          return sorted(json.loads(l)["_msg"] for l in body.splitlines() if l.strip())

      def services(org, uid):
          code, body = proxy(org, uid, "/api/services")
          assert code == "200", (org, uid, code, body)
          return sorted(json.loads(body)["data"])

      eventually(lambda: log_rows(2, "vl-a"), ["log-a"], "org 2 logs")
      eventually(lambda: log_rows(3, "vl-b"), ["log-b"], "org 3 logs")
      eventually(lambda: services(2, "vt-a"), ["svc-a"], "org 2 traces")
      eventually(lambda: services(3, "vt-b"), ["svc-b"], "org 3 traces")
      # The main datasources send the main token: the default tenant has no data.
      assert log_rows(1, "victorialogs-ds") == []
      assert services(1, "victoriatraces-ds") == []
      # A tenant's datasource does not exist in another org.
      assert grafana("/api/datasources/uid/vl-b", 2)[0] == "404"
      assert grafana("/api/datasources/uid/vl-a", 3)[0] == "404"

      # Each tenant has its own header file; the token is only in the credential
      # directory and the header files, never in the unit or the provisioning files.
      ini = machine.succeed("systemctl cat grafana.service | grep -oE -e '-config [^ ]+' | cut -d' ' -f2").strip()
      prov = machine.succeed(f"sed -n 's/^provisioning=//p' {ini}").strip()
      assert prov.startswith("/nix/store/"), prov
      for n, token in [("a", "${tokenFixtureA}"), ("b", "${tokenFixtureB}")]:
          path = f"/run/grafana/vmauth-authorization-{n}"
          assert machine.succeed(f"cat {path}") == f"Bearer {token}"
          assert machine.succeed(f"stat -c %a {path}").strip() == "600"
          machine.fail(f"systemctl cat grafana.service | grep -F {token}")
          machine.succeed(f"grep -RlF vmauth-authorization-{n} {prov}")
          machine.fail(f"grep -RF {token} {prov}")

      # Rotation: replacing a tenant's token file restarts Grafana, and the
      # datasource now sends the new token (vmauth does not list it: closed).
      machine.wait_until_succeeds(
          "systemctl show -p SubState --value grafana-tenant-token-watch.path | grep -qx waiting", timeout=120
      )
      was = machine.succeed("systemctl show -p InvocationID --value grafana.service").strip()
      machine.succeed("printf %s tenant-a-token-rotated > ${secretDir}/a")
      machine.wait_until_succeeds(
          f"test \"$(systemctl show -p InvocationID --value grafana.service)\" != {was}", timeout=180
      )
      wait_active(machine, "grafana.service")
      machine.wait_for_open_port(3000)
      machine.wait_until_succeeds(
          "test \"$(cat /run/grafana/vmauth-authorization-a)\" = 'Bearer tenant-a-token-rotated'", timeout=60
      )
      assert proxy(2, "vl-a", "/select/logsql/query", "query=*")[0] != "200"
      eventually(lambda: log_rows(3, "vl-b"), ["log-b"], "org 3 logs after a's rotation")
    '';
  };
in
{
  provisioning-is-per-org-with-the-tenants-token = provisioning;
  follows-the-enabled-backends = followsBackends;
  nothing-without-the-options = nothingWithoutOptIn;
  escapes-the-token-path = escapesPaths;
  org-id-type-refuses-non-positive-and-non-integers = orgIdTypeRefuses;
  inherit runbook;
  runbook-metrics = metricsRunbook;
}
// lib.mapAttrs' (
  n: c:
  lib.nameValuePair "rejects-${n}" (mkAssertionFiresCheck {
    name = "grafana-tenant-orgs-rejects-${n}";
    module = tenantsModule { inherit (c) tenants; };
    expectMessageSubstring = c.fragment;
  })
) rejectCases
// lib.mapAttrs' (
  n: tenants:
  lib.nameValuePair "accepts-${n}" (mkNoAssertionsFireCheck {
    name = "grafana-tenant-orgs-accepts-${n}";
    module = tenantsModule { inherit tenants; };
  })
) acceptCases
