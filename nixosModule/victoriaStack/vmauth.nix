{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  cfg = topCfg.vmauth;

  anyBackendEnabled = topCfg.metrics.enable || topCfg.logs.enable || topCfg.traces.enable;

  # vmauth's own `headers`/`response_headers` url_map keys -- applied
  # uniformly to every entry this module builds (read, write, and MCP
  # routes alike) when configured, omitted entirely otherwise.
  extraHeadersAttrs =
    lib.optionalAttrs (cfg.extraRequestHeaders != [ ]) { headers = cfg.extraRequestHeaders; }
    // lib.optionalAttrs (cfg.extraResponseHeaders != [ ]) {
      response_headers = cfg.extraResponseHeaders;
    };
  withExtraHeaders = map (entry: entry // extraHeadersAttrs);

  # Each enabled backend's own native read API, reached via vmauth as
  # /metrics/*, /logs/*, /traces/* -- src_paths are POST-STRIP (vmauth
  # itself strips nothing; whatever fronts vmauth, e.g. nginx, is
  # responsible for any further prefix stripping of its own, same
  # separation of concerns as deployment-a's real deployment).
  #
  # Read via each backend's own effectiveUrl (docs/decisions/0019), not
  # listenAddress directly -- MCP's own listenAddress stays a direct
  # read: those proxies are tightly coupled to a co-located backend by
  # construction, not a meaningful target for future remote-backend
  # support the way the 3 storage services are.
  readUrlMap = withExtraHeaders (
    lib.optional topCfg.metrics.enable {
      src_paths = [ "/metrics/.*" ];
      drop_src_path_prefix_parts = 1;
      url_prefix = "${topCfg.metrics.effectiveUrl}/";
    }
    ++ lib.optional topCfg.logs.enable {
      src_paths = [ "/logs/.*" ];
      drop_src_path_prefix_parts = 1;
      url_prefix = "${topCfg.logs.effectiveUrl}/";
    }
    ++ lib.optional topCfg.traces.enable {
      src_paths = [ "/traces/.*" ];
      drop_src_path_prefix_parts = 1;
      url_prefix = "${topCfg.traces.effectiveUrl}/";
    }
    # MCP servers: drop 2 parts ("mcp" + the service name) so the backend
    # sees exactly "/mcp" -- the one fixed path every mcp-victoria* binary
    # serves in MCP_SERVER_MODE=http (confirmed via each project's own
    # README). Callers must request with no trailing slash for this to
    # land exactly on "/mcp" rather than "/mcp/".
    ++ lib.optional topCfg.metrics.mcp.enable {
      src_paths = [ "/mcp/metrics(/.*)?" ];
      drop_src_path_prefix_parts = 2;
      url_prefix = "http://${topCfg.metrics.mcp.listenAddress}/mcp";
    }
    ++ lib.optional topCfg.logs.mcp.enable {
      src_paths = [ "/mcp/logs(/.*)?" ];
      drop_src_path_prefix_parts = 2;
      url_prefix = "http://${topCfg.logs.mcp.listenAddress}/mcp";
    }
    ++ lib.optional topCfg.traces.mcp.enable {
      src_paths = [ "/mcp/traces(/.*)?" ];
      drop_src_path_prefix_parts = 2;
      url_prefix = "http://${topCfg.traces.mcp.listenAddress}/mcp";
    }
    ++ cfg.extraReadUrlMap
  );

  # Each enabled backend's own native ingest/write path -- auto-derived
  # default for `openIngestPaths`, confirmed from each project's own data
  # ingestion docs (not assumed to share one shape): VictoriaMetrics' OTLP
  # receiver, VictoriaLogs' native journald-upload handler, VictoriaTraces'
  # OTLP receiver.
  autoOpenIngestPaths = withExtraHeaders (
    lib.optional topCfg.metrics.enable {
      src_paths = [ "/opentelemetry.*" ];
      url_prefix = "${topCfg.metrics.effectiveUrl}/";
    }
    ++ lib.optional topCfg.logs.enable {
      src_paths = [ "/insert/journald.*" ];
      url_prefix = "${topCfg.logs.effectiveUrl}/";
    }
    ++ lib.optional topCfg.traces.enable {
      src_paths = [ "/insert/opentelemetry/v1/traces.*" ];
      url_prefix = "${topCfg.traces.effectiveUrl}/";
    }
  );

  readUrlMapFile = pkgs.writeText "vmauth-read-url-map.json" (builtins.toJSON readUrlMap);
  openIngestPathsFile = pkgs.writeText "vmauth-open-ingest-paths.json" (
    builtins.toJSON cfg.openIngestPaths
  );
  # Deliberately NEVER cfg.openIngestPaths -- write-tier bearer tokens are
  # a credentialed tier (docs/decisions/0003) and must stay reachable
  # regardless of how the unauthenticated/open door is sized. Always
  # derived straight from autoOpenIngestPaths; see docs/decisions/0014.
  writeUrlMapFile = pkgs.writeText "vmauth-write-url-map.json" (builtins.toJSON autoOpenIngestPaths);

  # Renders /run/vmauth/config.json at service start from: the two
  # Nix-known (non-secret) url_map JSON files above, plus whichever of
  # adminPasswordFile/readTokensFile/writeTokensFile are actually
  # configured, staged by systemd's own LoadCredential= (never the Nix
  # store -- see docs/decisions/0008). readTokensFile/writeTokensFile are
  # YAML (a `tokens:` list, each entry optionally trailed by an inline `#`
  # comment -- docs/decisions/0003), parsed with yq (strips comments
  # natively) rather than treating the file as raw newline-delimited text.
  renderConfig = pkgs.writeShellApplication {
    name = "vmauth-render-config";
    runtimeInputs = [
      pkgs.jq
      pkgs.yq-go
    ];
    text = ''
      users_json='[]'

      if [ -f "$CREDENTIALS_DIRECTORY/admin-password" ]; then
        admin_password=$(cat "$CREDENTIALS_DIRECTORY/admin-password")
        users_json=$(jq --arg pw "$admin_password" --slurpfile urlmap "$READ_URL_MAP_FILE" \
          '. + [{username: "admin", password: $pw, url_map: $urlmap[0]}]' <<<"$users_json")
      fi

      if [ -f "$CREDENTIALS_DIRECTORY/read-tokens" ]; then
        read_tokens_json=$(yq -o=json '.tokens' "$CREDENTIALS_DIRECTORY/read-tokens")
        users_json=$(jq --argjson tokens "$read_tokens_json" --slurpfile urlmap "$READ_URL_MAP_FILE" \
          '. + ($tokens | map({bearer_token: ., url_map: $urlmap[0]}))' <<<"$users_json")
      fi

      if [ -f "$CREDENTIALS_DIRECTORY/write-tokens" ]; then
        write_tokens_json=$(yq -o=json '.tokens' "$CREDENTIALS_DIRECTORY/write-tokens")
        users_json=$(jq --argjson tokens "$write_tokens_json" --slurpfile urlmap "$WRITE_URL_MAP_FILE" \
          '. + ($tokens | map({bearer_token: ., url_map: $urlmap[0]}))' <<<"$users_json")
      fi

      jq -n \
        --argjson users "$users_json" \
        --slurpfile openmap "$OPEN_INGEST_PATHS_FILE" \
        '{}
         + (if ($ENV.REQUIRE_AUTH_FOR_WRITES == "false") and (($openmap[0] | length) > 0)
            then {unauthorized_user: {access_log: {}, url_map: $openmap[0]}}
            else {} end)
         + {users: $users}' \
        >/run/vmauth/config.json
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && anyBackendEnabled) {
    # vmauth's binary ships inside the SAME victoriametrics package as the
    # metrics storage server (docs/decisions/0007) -- but that package's
    # own default is only ever set by metrics.nix's `lib.mkIf
    # metrics.enable`, so reading `topCfg.metrics.package` unconditionally
    # throws "has no value defined" whenever vmauth auto-enables from
    # logs/traces alone with metrics itself off (a real, legitimate case:
    # vmauth doesn't require metrics specifically, just any backend).
    # Track metrics' own package when it's enabled (preserving 0007's
    # actual intent: stay version-matched if someone overrides it), fall
    # back to the plain upstream package otherwise.
    services.victoriaStack.vmauth.package = lib.mkDefault (
      if topCfg.metrics.enable then topCfg.metrics.package else pkgs.victoriametrics
    );
    services.victoriaStack.vmauth.openIngestPaths = lib.mkDefault autoOpenIngestPaths;

    # requireAuthForWrites = false already grants unauthenticated write
    # access to every enabled backend's ingest path -- a write-tier token
    # configured in that same state provides no additional protection
    # (two settings that genuinely contradict each other, not a generic
    # "you might not understand security" nag -- docs/decisions/0014).
    warnings = lib.optional (!cfg.requireAuthForWrites && cfg.writeTokensFile != null) ''
      services.victoriaStack.vmauth.writeTokensFile is set, but
      requireAuthForWrites = false already permits unauthenticated writes --
      the configured write tokens provide no additional protection for the
      write path in this configuration.
    '';

    systemd.services.vmauth = {
      description = "vmauth -- auth/routing gateway in front of VictoriaMetrics/Logs/Traces";
      after = [
        "network.target"
      ]
      ++ lib.optional topCfg.metrics.enable "victoriametrics.service"
      ++ lib.optional topCfg.logs.enable "victorialogs.service"
      ++ lib.optional topCfg.traces.enable "victoriatraces.service";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        LoadCredential =
          lib.optional (cfg.adminPasswordFile != null) "admin-password:${cfg.adminPasswordFile}"
          ++ lib.optional (cfg.readTokensFile != null) "read-tokens:${cfg.readTokensFile}"
          ++ lib.optional (cfg.writeTokensFile != null) "write-tokens:${cfg.writeTokensFile}"
          ++ lib.optional (cfg.backendTls.certFile != null) "backend-tls-cert:${cfg.backendTls.certFile}"
          ++ lib.optional (cfg.backendTls.keyFile != null) "backend-tls-key:${cfg.backendTls.keyFile}";

        Environment = [
          "READ_URL_MAP_FILE=${readUrlMapFile}"
          "OPEN_INGEST_PATHS_FILE=${openIngestPathsFile}"
          "WRITE_URL_MAP_FILE=${writeUrlMapFile}"
          "REQUIRE_AUTH_FOR_WRITES=${lib.boolToString cfg.requireAuthForWrites}"
        ];

        ExecStartPre = "${lib.getExe renderConfig}";
        # idleConnTimeout's own default (1m) sits right on top of a
        # typical collector's OTLP export interval (~52-60s), producing
        # intermittent "connection reset by peer" retries as vmauth
        # force-closes connections collectors are about to reuse --
        # confirmed in production, see cfg.idleConnTimeout's own option
        # description.
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/vmauth"
            "-auth.config=/run/vmauth/config.json"
            "-httpListenAddr=${cfg.listenAddress}"
            "-http.idleConnTimeout=${cfg.idleConnTimeout}"
          ]
          ++ lib.optional (
            cfg.maxConcurrentRequests != null
          ) "-maxConcurrentRequests=${toString cfg.maxConcurrentRequests}"
          ++ lib.optional (
            cfg.maxConcurrentPerUserRequests != null
          ) "-maxConcurrentPerUserRequests=${toString cfg.maxConcurrentPerUserRequests}"
          ++ lib.optional cfg.backendTls.insecureSkipVerify "-backend.tlsInsecureSkipVerify=true"
          ++ lib.optional (cfg.backendTls.caFile != null) "-backend.tlsCAFile=${cfg.backendTls.caFile}"
          # %d expands to $CREDENTIALS_DIRECTORY at the service manager
          # level (same pattern nixpkgs' own victoriametrics.nix module
          # uses for -httpAuth.password=file://%d/basic_auth_password) --
          # never a literal path, the credential is staged there by
          # LoadCredential= at runtime.
          ++ lib.optional (cfg.backendTls.certFile != null) "-backend.tlsCertFile=%d/backend-tls-cert"
          ++ lib.optional (cfg.backendTls.keyFile != null) "-backend.tlsKeyFile=%d/backend-tls-key"
        );
        RuntimeDirectory = "vmauth";
        RuntimeDirectoryMode = "0700";
        # Default UMask (0022) would render config.json -- every bearer
        # token and the admin password, in cleartext -- world-readable
        # (mode 644). Applies to ExecStartPre too, so the file it renders
        # comes out 600 from the start.
        UMask = "0177";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening -- same general-purpose systemd profile applied to
        # the storage services (docs/decisions/0015), no nixpkgs vmauth
        # module exists to diff against (confirmed: nixpkgs ships no
        # vmauth module at all), and no LimitNOFILE/readiness-check
        # addition here since neither has a confirmed, documented basis
        # for this specific binary the way metrics/logs/traces did.
        DeviceAllow = [ "/dev/null rw" ];
        DevicePolicy = "strict";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "full";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "mincore"
        ];
      };
    };
  };
}
