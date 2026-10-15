{ pkgs, nixosModule }:

# vmauth in front of the metrics cluster: client
# paths stay `/metrics/...` and `/opentelemetry/...`, vmauth rewrites them to
# vmselect's `/select/0/prometheus/...` and vminsert's `/insert/0/...`.
# Sections: the rendered url maps (eval-only), config.json per token tier
# (render script), the real processes through vmauth (booted).
let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith httpTestPython otlpMetricGenerator;

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

  urlMapFile =
    prefix: evaluated:
    let
      v =
        lib.findFirst (lib.hasPrefix "${prefix}=") null
          evaluated.config.systemd.services.vmauth.serviceConfig.Environment;
    in
    builtins.fromJSON (builtins.readFile (lib.removePrefix "${prefix}=" v));

  stack =
    extra:
    evalWith {
      services.victoriaStack = {
        metrics = {
          enable = true;
        }
        // (extra.metrics or { });
      }
      // lib.removeAttrs extra [ "metrics" ];
    };

  # The one metrics entry of each tier's url map.
  readRoutes = [
    "/metrics/api/v1/query"
    "/metrics/api/v1/query_range"
    "/metrics/api/v1/series"
    "/metrics/api/v1/labels"
    "/metrics/api/v1/label/.+/values"
    "/metrics/api/v1/metadata"
    "/metrics/api/v1/export.*"
    "/metrics/federate"
  ];
  readEntry = prefix: {
    src_paths = readRoutes;
    drop_src_path_prefix_parts = 1;
    url_prefix = prefix;
    headers = [ "Authorization:" ];
  };
  writeEntry = prefix: {
    src_paths = [ "/opentelemetry.*" ];
    url_prefix = prefix;
    headers = [ "Authorization:" ];
  };

  cluster = stack { };
  wildcard = stack {
    metrics = {
      listenAddress = "0.0.0.0:4301";
      insert.listenAddress = "[::]:4309";
    };
  };
  withMcp = stack {
    metrics.mcp.enable = true;
    logs.enable = true;
    traces.enable = true;
  };
  logsOnly = evalWith {
    services.victoriaStack.logs.enable = true;
  };

  afterOf = e: e.config.systemd.services.vmauth.after;
  firstMetrics =
    m: lib.head (lib.filter (e: lib.any (lib.hasPrefix "/metrics") (e.src_paths or [ ])) m);

  # ---- render script ----
  adminPassword = pkgs.writeText "admin-password" "admin-password-value\n";
  readTokens = pkgs.writeText "read-tokens.yaml" ''
    tokens:
      - token: cluster-read-token # gitleaks:allow
      - token: cluster-read-tenant-a # gitleaks:allow
        tenant: a
  '';
  writeTokens = pkgs.writeText "write-tokens.yaml" ''
    tokens:
      - token: cluster-write-token # gitleaks:allow
      - token: cluster-write-tenant-a # gitleaks:allow
        tenant: a
  '';

  renderTest =
    let
      sel = "http://127.0.0.1:4201/select/0/prometheus/";
      ins = "http://127.0.0.1:4209/insert/0/";
      sel1 = "http://127.0.0.1:4201/select/1/prometheus/";
      ins1 = "http://127.0.0.1:4209/insert/1/";
    in
    pkgs.testers.nixosTest {
      name = "victoria-stack-vmauth-cluster-renders-each-token-tier";
      containers.machine = {
        imports = [
          module
          testLib.testStartupTimeouts
        ];
        services.victoriaStack = {
          metrics = {
            enable = true;
          };
          logs.enable = true;
          tenants.a.accountId = 1;
          vmauth = {
            adminPasswordFile = "${adminPassword}";
            readTokensFile = "${readTokens}";
            writeTokensFile = "${writeTokens}";
            requireAuthForWrites = false;
          };
        };
      };
      testScript = ''
        import json
        ${testLib.waitActivePython}
        start_all()
        wait_active(machine, "vmauth.service")
        config = json.loads(machine.succeed("cat /run/vmauth/config.json"))

        def metrics_routes(url_map):
            return [
                r for r in url_map
                if any(p.startswith(("/metrics", "/opentelemetry")) for p in r.get("src_paths", []))
            ]

        READ = {
            "src_paths": ${builtins.toJSON readRoutes},
            "drop_src_path_prefix_parts": 1,
            "url_prefix": "${sel}",
            "headers": ["Authorization:"],
        }
        WRITE = {
            "src_paths": ["/opentelemetry.*"],
            "url_prefix": "${ins}",
            "headers": ["Authorization:"],
        }

        users = {u.get("username") or u["bearer_token"]: u["url_map"] for u in config["users"]}
        assert metrics_routes(users["admin"]) == [READ], users["admin"]
        assert metrics_routes(users["cluster-read-token"]) == [READ], users["cluster-read-token"]
        assert metrics_routes(users["cluster-write-token"]) == [WRITE], users["cluster-write-token"]
        # A tenant token's metrics routes point at the tenant's own path (account 1).
        assert metrics_routes(users["cluster-read-tenant-a"]) == [dict(READ, url_prefix="${sel1}")], users["cluster-read-tenant-a"]
        assert metrics_routes(users["cluster-write-tenant-a"]) == [dict(WRITE, url_prefix="${ins1}")], users["cluster-write-tenant-a"]
        assert metrics_routes(config["unauthorized_user"]["url_map"]) == [WRITE]

        journal = machine.succeed("journalctl -u vmauth.service --no-pager")
        assert "vmauth-render-config: warning:" not in journal, journal
        for secret in ["cluster-read-tenant-a", "cluster-write-tenant-a"]:
            assert secret not in journal, secret

        after = machine.succeed("systemctl show vmauth.service -p After --value").split()
        assert "vmselect.service" in after and "vminsert.service" in after, after
        assert "victoriametrics.service" not in after, after
      '';
    };

  # ---- booted ----
  roundtripTokens = {
    read = pkgs.writeText "rt-read-tokens.yaml" ''
      tokens:
        - token: roundtrip-read-token # gitleaks:allow
    '';
    write = pkgs.writeText "rt-write-tokens.yaml" ''
      tokens:
        - token: roundtrip-write-token # gitleaks:allow
    '';
  };
in
{
  # --- eval ---

  cluster-read-tier-routes-to-vmselect-under-select-0 = table "vmauth-cluster-read-tier" {
    "exactly the closed list, rewritten under /select/0/prometheus/" =
      urlMapFile "READ_URL_MAP_FILE" cluster
      == [ (readEntry "http://127.0.0.1:4201/select/0/prometheus/") ];
    "a wildcard listenAddress is dialled on loopback" =
      urlMapFile "READ_URL_MAP_FILE" wildcard
      == [ (readEntry "http://127.0.0.1:4301/select/0/prometheus/") ];
    "other backends and MCP routes are untouched" =
      let
        m = urlMapFile "READ_URL_MAP_FILE" withMcp;
      in
      firstMetrics m == readEntry "http://127.0.0.1:4201/select/0/prometheus/"
      && lib.length m == 4
      && (lib.elemAt m 1).url_prefix == "http://127.0.0.1:4202/"
      && (lib.elemAt m 2).url_prefix == "http://127.0.0.1:4203/"
      && (lib.elemAt m 3).url_prefix == "http://127.0.0.1:4205/mcp";
    "the options layer names both addresses" =
      cluster.config.services.victoriaStack.metrics.effectiveSelectUrl == "http://127.0.0.1:4201"
      && cluster.config.services.victoriaStack.metrics.effectiveInsertUrl == "http://127.0.0.1:4209"
      && wildcard.config.services.victoriaStack.metrics.effectiveSelectUrl == "http://127.0.0.1:4301"
      && wildcard.config.services.victoriaStack.metrics.effectiveInsertUrl == "http://127.0.0.1:4309";
  };

  cluster-write-tier-and-open-door-route-to-vminsert-under-insert-0 =
    table "vmauth-cluster-write-tier"
      {
        "write tier" =
          urlMapFile "WRITE_URL_MAP_FILE" cluster == [ (writeEntry "http://127.0.0.1:4209/insert/0/") ];
        "open ingest door" =
          urlMapFile "OPEN_INGEST_PATHS_FILE" cluster == [ (writeEntry "http://127.0.0.1:4209/insert/0/") ];
        "a wildcard insert address is dialled on loopback" =
          urlMapFile "WRITE_URL_MAP_FILE" wildcard == [ (writeEntry "http://127.0.0.1:4309/insert/0/") ];
        "logs and traces ingest routes are untouched" =
          let
            m = urlMapFile "WRITE_URL_MAP_FILE" withMcp;
          in
          lib.length m == 3
          && (lib.elemAt m 0).url_prefix == "http://127.0.0.1:4209/insert/0/"
          && (lib.elemAt m 1).url_prefix == "http://127.0.0.1:4202/"
          && (lib.elemAt m 2).url_prefix == "http://127.0.0.1:4203/";
      };

  # The seam of docs/decisions/0019, per direction: reads follow effectiveUrl,
  # writes follow effectiveInsertUrl (vminsert is another process).
  cluster-effective-url-overrides-reach-their-routes = table "vmauth-cluster-effective-urls" {
    "effectiveUrl reaches the read route and only that" =
      let
        o = evalWith {
          services.victoriaStack.metrics = {
            enable = true;
            effectiveUrl = "http://metrics.example.test:9";
          };
        };
      in
      urlMapFile "READ_URL_MAP_FILE" o
      == [ (readEntry "http://metrics.example.test:9/select/0/prometheus/") ]
      && urlMapFile "WRITE_URL_MAP_FILE" o == [ (writeEntry "http://127.0.0.1:4209/insert/0/") ];
    "effectiveInsertUrl reaches the write route, the open door and the self-monitoring push" =
      let
        o = evalWith {
          services.victoriaStack.metrics = {
            enable = true;
            effectiveInsertUrl = "http://insert.example.test:9";
          };
        };
      in
      urlMapFile "WRITE_URL_MAP_FILE" o == [ (writeEntry "http://insert.example.test:9/insert/0/") ]
      &&
        urlMapFile "OPEN_INGEST_PATHS_FILE" o == [ (writeEntry "http://insert.example.test:9/insert/0/") ]
      && urlMapFile "READ_URL_MAP_FILE" o == [ (readEntry "http://127.0.0.1:4201/select/0/prometheus/") ]
      && lib.hasInfix "-pushmetrics.url=http://insert.example.test:9/insert/0/prometheus/api/v1/import/prometheus" (
        lib.concatStringsSep " " (lib.toList o.config.systemd.services.vmauth.serviceConfig.ExecStart)
      );
  };

  cluster-vmauth-orders-after-the-data-path-and-keeps-its-own-package =
    table "vmauth-cluster-ordering-package"
      {
        "after vmselect and vminsert" = lib.all (u: lib.elem u (afterOf cluster)) [
          "vmselect.service"
          "vminsert.service"
        ];
        "not after the single-node unit" = !(lib.elem "victoriametrics.service" (afterOf cluster));
        "no MCP unit (they start after vmauth)" = !(lib.any (lib.hasPrefix "mcp-") (afterOf withMcp));
        "package is pkgs.victoriametrics, not the cluster package" =
          cluster.config.services.victoriaStack.vmauth.package.outPath == pkgs.victoriametrics.outPath;
        "an overridden metrics.package is not used for vmauth" =
          (stack { metrics.package = pkgs.hello; }).config.services.victoriaStack.vmauth.package.outPath
          == pkgs.victoriametrics.outPath;
        "logs only: still evaluates, same package" =
          logsOnly.config.services.victoriaStack.vmauth.package.outPath == pkgs.victoriametrics.outPath;
      };

  # --- render script ---

  cluster-renders-each-token-tier = renderTest;

  # --- booted ---

  vmauth-cluster-roundtrip = pkgs.testers.nixosTest {
    name = "victoria-stack-vmauth-cluster-roundtrip";

    containers.machine = {
      imports = [
        module
        testLib.testStartupTimeouts
      ];
      services.victoriaStack = {
        metrics = {
          enable = true;
        };
        vmauth = {
          adminPasswordFile = "${adminPassword}";
          readTokensFile = "${roundtripTokens.read}";
          writeTokensFile = "${roundtripTokens.write}";
          # The anonymous OTLP door.
          requireAuthForWrites = false;
          # A Prometheus import path for the write tier, as an operator would
          # add it: the module only derives the OTLP route.
          # The same path on the anonymous door: openIngestPaths replaces the
          # derived list, so the OTLP route is repeated. The operator's url_prefix
          # carries the cluster path (docs/decisions/0033).
          openIngestPaths = [
            {
              src_paths = [ "/opentelemetry.*" ];
              url_prefix = "http://127.0.0.1:4209/insert/0/";
            }
            {
              src_paths = [ "/api/v1/import/prometheus" ];
              url_prefix = "http://127.0.0.1:4209/insert/0/prometheus/";
            }
          ];
          extraWriteUrlMap = [
            {
              src_paths = [ "/api/v1/import/prometheus" ];
              url_prefix = "http://127.0.0.1:4209/insert/0/prometheus/";
            }
          ];
        };
      };
    };

    testScript = ''
      import time
      ${testLib.waitActivePython}
      ${httpTestPython}

      VMAUTH = "http://127.0.0.1:4204"
      READ = "-H 'Authorization: Bearer roundtrip-read-token'"
      WRITE = "-H 'Authorization: Bearer roundtrip-write-token'"
      ADMIN = "-u admin:admin-password-value"
      PB = "-H 'Content-Type: application/x-protobuf'"

      start_all()
      for u in ["vmstorage", "vminsert", "vmselect", "vmauth"]:
          wait_active(machine, f"{u}.service")
      for port in [4201, 4204, 4209, 4210]:
          machine.wait_for_open_port(port)

      def poll(cmd, pattern, timeout=90):
          # A fresh write is not visible at once (flush, and vmselect's 30s latency offset).
          machine.wait_until_succeeds(f"{cmd} | grep -q '{pattern}'", timeout=timeout)

      def no_route(cred, url, extra=""):
          code, body = http(machine, url, cred, f"--path-as-is -g {extra}")
          assert code == "400" and "missing route" in body, (url, cred, extra, code, body)

      # ---- writes through vmauth ----
      old_ms = int((time.time() - 600) * 1000)
      old_s = old_ms // 1000
      # Prometheus text import, an old timestamp: readable at once by an explicit time=.
      machine.succeed(
          f"curl -sf {WRITE} -X POST --data-binary 'cluster_probe_prom 7 {old_ms}' "
          f"{VMAUTH}/api/v1/import/prometheus"
      )
      machine.succeed(f"curl -sf {WRITE} -X POST --data-binary 'cluster_probe_fresh 5' {VMAUTH}/api/v1/import/prometheus")
      # OTLP as the collector sends it: protobuf, gzip, the real path, a bearer token.
      machine.succeed("${otlpMetricGenerator}/bin/gen-otlp-metric cluster_probe_otlp 3 | gzip -c > /tmp/otlp.gz")
      machine.succeed(
          f"curl -sf {WRITE} -X POST {PB} -H 'Content-Encoding: gzip' -H 'User-Agent: Alloy/v1.0' "
          f"--data-binary @/tmp/otlp.gz {VMAUTH}/opentelemetry/v1/metrics"
      )
      # The anonymous door (requireAuthForWrites = false).
      machine.succeed("${otlpMetricGenerator}/bin/gen-otlp-metric cluster_probe_open 9 > /tmp/otlp-open.bin")
      machine.succeed(f"curl -sf -X POST {PB} --data-binary @/tmp/otlp-open.bin {VMAUTH}/opentelemetry/v1/metrics")
      # An operator's Prometheus import path on the anonymous door (openIngestPaths).
      machine.succeed(f"curl -sf -X POST --data-binary 'cluster_probe_open_prom 11' {VMAUTH}/api/v1/import/prometheus")

      # ---- reads through vmauth, read token and admin password alike ----
      win = f"start={old_s - 60}&end={old_s + 120}"
      for cred in [READ, ADMIN]:
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/export?match[]=cluster_probe_prom&{win}'", '"values":\\[7\\]')
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/export?match[]=cluster_probe_otlp&start={old_s}'", '"values":\\[3\\]')
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/export?match[]=cluster_probe_open&start={old_s}'", '"values":\\[9\\]')
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/export?match[]=cluster_probe_open_prom&start={old_s}'", '"values":\\[11\\]')
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/query?query=cluster_probe_prom&time={old_s + 30}'", '"cluster_probe_prom".*"7"', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/query_range?query=cluster_probe_prom&{win}&step=30'", '"values":\\[\\[', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/series?match[]=cluster_probe_prom&{win}'", '"__name__":"cluster_probe_prom"', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/labels?{win}'", '"__name__"', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/label/__name__/values?{win}'", '"cluster_probe_prom"', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/api/v1/metadata'", '"status":"success"', 30)
          poll(f"curl -sfg {cred} '{VMAUTH}/metrics/federate?match[]=cluster_probe_fresh'", 'cluster_probe_fresh')

      # ---- the closed list: vmauth's own 400, for both read credentials ----
      forbidden_get = [
          "/metrics/api/v1/status/tsdb",
          "/metrics/api/v1/admin/tsdb/delete_series",
          "/metrics/api/v1/import",
          "/metrics/api/v1/import/prometheus",
          "/metrics/select/1/prometheus/api/v1/labels",
          "/metrics/select/0/prometheus/api/v1/labels",
          "/metrics/insert/0/prometheus/api/v1/import/prometheus",
          "/metrics/internal/force_merge",
          "/metrics/delete/0/prometheus/api/v1/admin/tsdb/delete_series",
          "/metrics/snapshot/create",
          "/metrics",
          "/select/0/prometheus/api/v1/labels",
          "/select/1/prometheus/api/v1/labels",
          "/insert/0/prometheus/api/v1/import/prometheus",
          "/insert/1/prometheus/api/v1/import/prometheus",
          "/internal/force_merge",
          "/delete/0/prometheus/api/v1/admin/tsdb/delete_series",
          "/api/v1/admin/tsdb/delete_series",
          "/metrics/../select/1/prometheus/api/v1/labels",
          "/metrics/api/v1/query/../../../../delete/0/prometheus/api/v1/admin/tsdb/delete_series",
          "/metrics/api/v1/label/a/../../../../delete/0/prometheus/api/v1/admin/tsdb/delete_series/values",
          "/metrics/%2e%2e/select/1/prometheus/api/v1/labels",
          "/metrics/api/v1/query/%2e%2e/%2e%2e/%2e%2e/delete/0/prometheus/api/v1/admin/tsdb/delete_series",
          "/metrics/api/v1/label/x%2F..%2F..%2F..%2F..%2Fdelete%2F0%2Fprometheus%2Fapi%2Fv1%2Fadmin%2Ftsdb%2Fdelete_series%2Fvalues",
          "/metrics/api/v1/export/../import",
      ]
      for cred in [READ, ADMIN]:
          for path in forbidden_get:
              no_route(cred, VMAUTH + path)
              no_route(cred, VMAUTH + path, "-X POST --data-binary 'match[]=cluster_probe_prom'")
      # Nothing was deleted and nothing landed in another tenant.
      poll(f"curl -sfg {READ} '{VMAUTH}/metrics/api/v1/export?match[]=cluster_probe_prom&{win}'", '"values":\\[7\\]', 30)
      for tenant in ["1", "2"]:
          out = machine.succeed(f"curl -sfg 'http://127.0.0.1:4201/select/{tenant}/prometheus/api/v1/labels?start=0'")
          assert '"data":[]' in out, (tenant, out)

      # ---- the write tier cannot read, the read tier cannot write ----
      for path in [
          "/metrics/api/v1/query?query=cluster_probe_prom",
          "/metrics/api/v1/export?match[]=cluster_probe_prom",
          "/select/0/prometheus/api/v1/export?match[]=cluster_probe_prom",
      ]:
          no_route(WRITE, VMAUTH + path)
      for cred in [READ, ADMIN]:
          no_route(cred, VMAUTH + "/opentelemetry/v1/metrics", f"-X POST {PB} --data-binary @/tmp/otlp-open.bin")
          no_route(cred, VMAUTH + "/api/v1/import/prometheus", "-X POST --data-binary 'cluster_probe_denied 1'")
      for path in [
          "/insert/0/prometheus/api/v1/import/prometheus",
          "/insert/1/prometheus/api/v1/import/prometheus",
          "/opentelemetry/../insert/1/prometheus/api/v1/import/prometheus",
          "/opentelemetry%2F..%2F..%2Finsert%2F1%2Fprometheus%2Fapi%2Fv1%2Fimport%2Fprometheus",
          "/api/v1/admin/tsdb/delete_series",
          "/delete/0/prometheus/api/v1/admin/tsdb/delete_series",
          "/internal/force_merge",
      ]:
          no_route(WRITE, VMAUTH + path, "-X POST --data-binary 'cluster_probe_denied 1'")
      # The anonymous caller reads nothing.
      code, body = http(machine, VMAUTH + "/metrics/api/v1/labels")
      assert code == "401", (code, body)
      for tenant in ["0", "1"]:
          out = machine.succeed(f"curl -sfg 'http://127.0.0.1:4201/select/{tenant}/prometheus/api/v1/export?match[]=cluster_probe_denied&start=0'")
          assert out.strip() == "", (tenant, out)
    '';
  };
}
