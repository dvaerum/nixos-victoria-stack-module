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
  selfMonitoring = import ./self-monitoring.nix { inherit lib; };
  listen = import ./listen.nix { inherit lib; };

  # `ip:port`, bracketing a bare IPv6 literal.
  inherit (listen) hostPort;

  # The ACME cert directory this module reads when https.acmeCertName is set.
  acmeDir = "/var/lib/acme/${cfg.https.acmeCertName}";
  httpsCertSource =
    if cfg.https.acmeCertName != null then "${acmeDir}/fullchain.pem" else cfg.https.certFile;
  httpsKeySource = if cfg.https.acmeCertName != null then "${acmeDir}/key.pem" else cfg.https.keyFile;

  # Secret files vmauth only reads at start (LoadCredential= copies them, the
  # render script runs once). ACME certs are excluded: reloadServices covers them.
  watchedSecrets = lib.filterAttrs (_: path: path != null) {
    admin-password = cfg.adminPasswordFile;
    read-tokens = cfg.readTokensFile;
    write-tokens = cfg.writeTokensFile;
    https-cert =
      if cfg.https.enable && cfg.https.acmeCertName == null then cfg.https.certFile else null;
    https-key = if cfg.https.enable && cfg.https.acmeCertName == null then cfg.https.keyFile else null;
  };

  # Every listener in positional order: the -tls/-tlsCertFile/-tlsKeyFile
  # array flags apply to -httpListenAddr by INDEX (confirmed in vmauth's
  # source), so all four flag lists are generated from this one list with
  # identical length. With both doors off this is just the internal listener
  # and no -tls flags are emitted.
  listeners = [
    {
      addr = cfg.listenAddress;
      tls = false;
    }
  ]
  ++ lib.optional cfg.https.enable {
    addr = hostPort cfg.https.ipAddress cfg.https.port;
    tls = true;
  }
  ++ lib.optional cfg.http.enable {
    addr = hostPort cfg.http.ipAddress cfg.http.port;
    tls = false;
  };
  anyTls = lib.any (l: l.tls) listeners;

  # vmauth's own `headers`/`response_headers` url_map keys -- applied
  # uniformly to every entry this module builds (read, write, and MCP
  # routes alike) when configured, omitted entirely otherwise.
  #
  # Concatenates onto any headers an entry already carries (e.g. a
  # user-supplied extraReadUrlMap entry with its own route-specific header)
  # rather than overwriting via `//`, which would silently discard them. The
  # entry's own values are listed last (more specific wins for any name vmauth
  # treats as last-value-wins).
  withExtraHeaders = map (
    entry:
    entry
    // {
      # vmauth forwards the caller's Authorization header to the backend by
      # default (its docs say so, and that an empty `Authorization:` header
      # strips it). The built-in backends are loopback and ignore it, but a
      # route to another host would receive every token and admin password that
      # passes through, so every module-built route drops it first. The
      # operator's own headers follow it, so an entry can still set its own.
      headers = [ "Authorization:" ] ++ cfg.extraRequestHeaders ++ (entry.headers or [ ]);
    }
    // lib.optionalAttrs (cfg.extraResponseHeaders != [ ]) {
      response_headers = cfg.extraResponseHeaders ++ (entry.response_headers or [ ]);
    }
  );

  # Each enabled backend's own native read API, reached via vmauth as
  # /metrics/*, /logs/*, /traces/* -- src_paths are POST-STRIP (vmauth
  # itself strips nothing; whatever fronts vmauth, e.g. nginx, is
  # responsible for any further prefix stripping of its own).
  #
  # Read via each backend's own effectiveUrl (docs/decisions/0019), not
  # listenAddress directly -- MCP's own listenAddress stays a direct
  # read: those proxies are tightly coupled to a co-located backend by
  # construction, not a meaningful target for future remote-backend
  # support the way the 3 storage services are.
  #
  # Curated allow-lists, NOT a blanket "/metrics/.*"-style passthrough
  # (docs/decisions/0021): a blanket passthrough let a read-tier
  # credential reach /api/v1/import (write arbitrary data) and
  # /api/v1/admin/tsdb/delete_series (permanently delete data) --
  # verified live, a real, severe privilege-escalation bug. Fails
  # closed: a future backend release's new endpoint not yet added here
  # is rejected by default, not silently allowed (the opposite failure
  # mode of the bug this fixes). New legitimate read endpoints need this
  # list updated -- use extraReadUrlMap as an interim escape hatch.
  readUrlMap = withExtraHeaders (
    lib.optional topCfg.metrics.enable {
      # Confirmed from VictoriaMetrics' own "Reads" API docs, and this
      # exact set (query/query_range/series/labels/label values) is also
      # vmauth's own official per-tenant-authorization example -- not
      # improvised. /api/v1/export* is a genuine read (dumps data out,
      # distinct from /api/v1/import*, the write path); /federate is
      # Prometheus's own federation read endpoint.
      src_paths = [
        "/metrics/api/v1/query"
        "/metrics/api/v1/query_range"
        "/metrics/api/v1/series"
        "/metrics/api/v1/labels"
        "/metrics/api/v1/label/.+/values"
        "/metrics/api/v1/export.*"
        "/metrics/federate"
      ];
      drop_src_path_prefix_parts = 1;
      url_prefix = "${topCfg.metrics.effectiveUrl}/";
    }
    ++ lib.optional topCfg.logs.enable {
      # VictoriaLogs' entire read API lives under /select/* -- confirmed
      # from its own HTTP API docs: /insert/* is the completely separate,
      # never-overlapping write namespace. One regex is both correct and
      # already a closed allow-list here, unlike metrics' API shape.
      src_paths = [ "/logs/select/.*" ];
      drop_src_path_prefix_parts = 1;
      url_prefix = "${topCfg.logs.effectiveUrl}/";
    }
    ++ lib.optional topCfg.traces.enable {
      # Same reasoning as logs -- VictoriaTraces' own docs: it "provides
      # the same HTTP endpoints that VictoriaLogs provides" plus the
      # Jaeger API, both also under /select/*.
      src_paths = [ "/traces/select/.*" ];
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
      url_prefix = "http://${listen.connectAddr topCfg.metrics.mcp.listenAddress}/mcp";
    }
    ++ lib.optional topCfg.logs.mcp.enable {
      src_paths = [ "/mcp/logs(/.*)?" ];
      drop_src_path_prefix_parts = 2;
      url_prefix = "http://${listen.connectAddr topCfg.logs.mcp.listenAddress}/mcp";
    }
    ++ lib.optional topCfg.traces.mcp.enable {
      src_paths = [ "/mcp/traces(/.*)?" ];
      drop_src_path_prefix_parts = 2;
      url_prefix = "http://${listen.connectAddr topCfg.traces.mcp.listenAddress}/mcp";
    }
    ++ cfg.extraReadUrlMap
  );

  # Each enabled backend's own native ingest/write path -- auto-derived
  # default for `openIngestPaths`, confirmed from each project's own data
  # ingestion docs (not assumed to share one shape): VictoriaMetrics' OTLP
  # receiver, VictoriaLogs' native journald-upload handler, VictoriaTraces'
  # OTLP receiver.
  #
  # Left unwrapped: withExtraHeaders is NOT idempotent (it concatenates
  # headers), and a user-overridden openIngestPaths must get the headers
  # too, so the wrap happens once, at serialization, below.
  autoOpenIngestPaths =
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
    };

  # Which url_map entries a token scoped to `backends = [ "<name>" ]` keeps:
  # those whose src_paths start with one of that backend's prefixes. The
  # two tiers' routes don't share one naming convention (reads live under
  # /<backend>/..., writes under each backend's own ingest path), hence
  # one table per tier. Kept here, next to the routes they describe, and
  # handed to the render script as data so the prefixes aren't duplicated
  # inside the embedded jq.
  readBackendPrefixesFile = pkgs.writeText "vmauth-read-backend-prefixes.json" (
    builtins.toJSON {
      metrics = [
        "/metrics"
        "/mcp/metrics"
      ];
      logs = [
        "/logs"
        "/mcp/logs"
      ];
      traces = [
        "/traces"
        "/mcp/traces"
      ];
    }
  );
  writeBackendPrefixesFile = pkgs.writeText "vmauth-write-backend-prefixes.json" (
    builtins.toJSON {
      metrics = [ "/opentelemetry" ];
      logs = [ "/insert/journald" ];
      traces = [ "/insert/opentelemetry/v1/traces" ];
    }
  );

  readUrlMapFile = pkgs.writeText "vmauth-read-url-map.json" (builtins.toJSON readUrlMap);
  openIngestPathsFile = pkgs.writeText "vmauth-open-ingest-paths.json" (
    builtins.toJSON (withExtraHeaders cfg.openIngestPaths)
  );
  # Deliberately NEVER cfg.openIngestPaths -- write-tier bearer tokens are
  # a credentialed tier (docs/decisions/0003) and must stay reachable
  # regardless of how the unauthenticated/open door is sized. Always
  # derived straight from autoOpenIngestPaths; see docs/decisions/0014.
  writeUrlMapFile = pkgs.writeText "vmauth-write-url-map.json" (
    builtins.toJSON (withExtraHeaders (autoOpenIngestPaths ++ cfg.extraWriteUrlMap))
  );

  # Renders /run/vmauth/config.json at service start from: the three
  # Nix-known (non-secret) url_map JSON files above (read, open-ingest,
  # write), plus whichever of
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
      # systemd leaves $CREDENTIALS_DIRECTORY unset when the unit has no
      # LoadCredential= entries at all (e.g. requireAuthForWrites = false and
      # no TLS files). `set -u` would crash on an unguarded reference, so
      # default it to empty, which reads as "no credential files present".
      credentials_directory="''${CREDENTIALS_DIRECTORY:-}"
      users_json='[]'

      # yq succeeds (exit 0) even when the `tokens:` key is absent (yields
      # JSON `null`) or isn't a list (e.g. a bare string) -- genuinely
      # malformed YAML in a safe way, but jq's native failure on either
      # shape downstream ("Cannot iterate over null (null)" / "...over
      # string (...)") names neither the offending file nor what shape was
      # expected. Confirmed live against both cases before writing this
      # guard. Fail closed either way (the crash-loop is correct -- an
      # operator typo must not silently serve zero tokens), just with a
      # message that says which option and why.
      #
      # Every message names the OPTION ($label: readTokensFile/writeTokensFile)
      # and 1-based entry numbers -- never a token value, and never the name of
      # an unknown key (a mistyped key can itself be a token). Secrets are also
      # never passed to jq as arguments (--arg/--argjson): argv is world-readable
      # via /proc/<pid>/cmdline while the script runs. They travel through
      # here-strings, process substitution (/dev/fd) or files only.
      validate_tokens_shape() {
        local label="$1"
        local tokens_json="$2"
        local prefixes_file="$3"
        # Pre-scoping format: a bare list of strings. Detected on its own
        # so the failure says how to migrate rather than just "malformed".
        if jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' <<<"$tokens_json" >/dev/null; then
          echo "vmauth-render-config: $label lists tokens as bare strings, the old format -- each entry must now be an object: '- token: <value>' (optionally with 'backends: [metrics, logs, traces]' to scope it to those backends)" >&2
          exit 1
        fi
        if ! jq -e 'type == "array" and all(.[]; type == "object" and (.token | type == "string") and ((.backends // []) | type == "array" and all(.[]; type == "string")))' <<<"$tokens_json" >/dev/null; then
          # Reports only the JSON type, never the contents: the file holds
          # secrets and this lands in the journal.
          echo "vmauth-render-config: $label must contain a top-level 'tokens:' key whose value is a YAML list of objects, each with a string \`token\` key and an optional \`backends\` list of strings (optionally with inline '#' comments) -- got a value of type: $(jq -r type <<<"$tokens_json")" >&2
          exit 1
        fi
        local bad
        bad=$(jq -r '[to_entries[] | select((.value | keys - ["token", "backends"]) | length > 0) | "#\(.key + 1)"] | join(", ")' <<<"$tokens_json")
        if [ -n "$bad" ]; then
          echo "vmauth-render-config: $label entry $bad has an unknown key (only 'token' and 'backends' are allowed)" >&2
          exit 1
        fi
        bad=$(jq -r '[to_entries[] | select(.value.token == "") | "#\(.key + 1)"] | join(", ")' <<<"$tokens_json")
        if [ -n "$bad" ]; then
          echo "vmauth-render-config: $label entry $bad has an empty token" >&2
          exit 1
        fi
        # vmauth itself dies on a duplicate and prints the token in its fatal line.
        bad=$(jq -r '[.[].token] | to_entries | group_by(.value) | map(select(length > 1) | map("#\(.key + 1)") | join(" and ")) | join("; ")' <<<"$tokens_json")
        if [ -n "$bad" ]; then
          echo "vmauth-render-config: $label lists the same token more than once (entries $bad)" >&2
          exit 1
        fi
        local unknown
        unknown=$(jq -r --slurpfile prefixes "$prefixes_file" \
          '[.[] | (.backends // [])[]] | unique - ($prefixes[0] | keys) | join(", ")' <<<"$tokens_json")
        if [ -n "$unknown" ]; then
          echo "vmauth-render-config: $label scopes a token to unknown backend(s): $unknown -- valid names: $(jq -r 'keys | join(", ")' "$prefixes_file")" >&2
          exit 1
        fi
      }

      # Turns one tier's (already validated) token list into vmauth users: an
      # unscoped token (no/empty `backends`) gets the tier's full url_map, a
      # scoped one only the PATHS under its backends' prefixes. Filtering is per
      # src_path, not per entry: an entry listing several paths keeps only the
      # matching ones (otherwise a multi-path extra entry leaks its other paths),
      # and a prefix matches only at a boundary (`/metricsX` is not under
      # `/metrics`). An alternation (`|`) cannot be attributed to one backend and
      # an entry with no src_paths has nothing to match, so both are dropped for
      # scoped tokens (fail closed). Echoes the old users array plus these.
      append_token_users() {
        local label="$1" users="$2" tokens_json="$3" urlmap_file="$4" prefixes_file="$5"
        local result
        result=$(jq --slurpfile tokens <(printf '%s' "$tokens_json") --slurpfile urlmap "$urlmap_file" \
          --slurpfile prefixes "$prefixes_file" \
          '. + ($tokens[0] | map(
             . as $t
             | (if (($t.backends // []) | length) == 0 then $urlmap[0]
                else ($t.backends | map($prefixes[0][.]) | add) as $pfx
                  | $urlmap[0]
                  | map(
                      (.src_paths |= ((. // []) | map(select(
                          . as $p
                          | ($p | contains("|") | not)
                          and any($pfx[]; . as $pre
                              | ($p | startswith($pre))
                              and (($p[($pre | length):]) | (. == "" or (.[0:1] | test("[A-Za-z0-9_-]") | not))))))))
                      | select((.src_paths | length) > 0))
                end) as $um
             | {bearer_token: $t.token, url_map: $um, scoped: (($t.backends // []) | length > 0), backends: ($t.backends // [])}))' <<<"$users")
        # A scoped token left with no routes (its backends aren't enabled)
        # would be an empty url_map, which vmauth rejects -- fail closed
        # here with a message that doesn't echo the token itself.
        local empty
        empty=$(jq -r '[.[] | select(.scoped and (.url_map | length) == 0) | (.backends | join("/"))] | join(", ")' <<<"$result")
        if [ -n "$empty" ]; then
          echo "vmauth-render-config: $label has a token scoped to [$empty] but none of its backends is enabled -- it would have no routes" >&2
          exit 1
        fi
        jq 'map(del(.scoped, .backends))' <<<"$result"
      }

      read_tokens_json=""
      write_tokens_json=""
      if [ -n "$credentials_directory" ] && [ -f "$credentials_directory/read-tokens" ]; then
        read_tokens_json=$(yq -o=json '.tokens' "$credentials_directory/read-tokens")
        validate_tokens_shape readTokensFile "$read_tokens_json" "$READ_BACKEND_PREFIXES_FILE"
      fi
      if [ -n "$credentials_directory" ] && [ -f "$credentials_directory/write-tokens" ]; then
        write_tokens_json=$(yq -o=json '.tokens' "$credentials_directory/write-tokens")
        validate_tokens_shape writeTokensFile "$write_tokens_json" "$WRITE_BACKEND_PREFIXES_FILE"
      fi
      # The same token in both tiers would give one bearer two routings.
      if [ -n "$read_tokens_json" ] && [ -n "$write_tokens_json" ]; then
        shared=$(jq -n -r --slurpfile r <(printf '%s' "$read_tokens_json") --slurpfile w <(printf '%s' "$write_tokens_json") \
          '[$r[0] | to_entries[] | . as $e | ($w[0] | to_entries[] | select(.value.token == $e.value.token)) as $m | "readTokensFile (entry #\($e.key + 1)) and writeTokensFile (entry #\($m.key + 1))"] | join("; ")')
        if [ -n "$shared" ]; then
          echo "vmauth-render-config: the same token is in $shared" >&2
          exit 1
        fi
      fi

      if [ -n "$credentials_directory" ] && [ -f "$credentials_directory/admin-password" ]; then
        admin_password=$(cat "$credentials_directory/admin-password")
        if [ -z "$admin_password" ]; then
          echo "vmauth-render-config: adminPasswordFile is empty -- refusing to create an admin user with an empty password" >&2
          exit 1
        fi
        users_json=$(jq --rawfile pw "$credentials_directory/admin-password" --slurpfile urlmap "$READ_URL_MAP_FILE" \
          '. + [{username: "admin", password: ($pw | sub("\n+$"; "")), url_map: $urlmap[0]}]' <<<"$users_json")
      fi

      if [ -n "$read_tokens_json" ]; then
        users_json=$(append_token_users readTokensFile "$users_json" \
          "$read_tokens_json" "$READ_URL_MAP_FILE" "$READ_BACKEND_PREFIXES_FILE")
      fi

      if [ -n "$write_tokens_json" ]; then
        users_json=$(append_token_users writeTokensFile "$users_json" \
          "$write_tokens_json" "$WRITE_URL_MAP_FILE" "$WRITE_BACKEND_PREFIXES_FILE")
      fi

      jq -n \
        --slurpfile users <(printf '%s' "$users_json") \
        --slurpfile openmap "$OPEN_INGEST_PATHS_FILE" \
        '{}
         + (if ($ENV.REQUIRE_AUTH_FOR_WRITES == "false") and (($openmap[0] | length) > 0)
            then {unauthorized_user: {access_log: {}, url_map: $openmap[0]}}
            else {} end)
         + {users: (if $ENV.ACCESS_LOG == "true" then ($users[0] | map(. + {access_log: {}})) else $users[0] end)}' \
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
    #
    # No warning for the inverse (requireAuthForWrites = true with
    # writeTokensFile unset): it is indistinguishable from never writing
    # through vmauth (writing straight to a backend's own listenAddress),
    # a common legitimate setup.
    warnings =
      # A src_paths pattern that begins with a wildcard matches every path
      # -- almost certainly a mistake in an escape-hatch entry, but still
      # the operator's call (no hard assertion).
      let
        matchesEverything =
          entries:
          # `.*`, `/.+`, `/(.*)`, `/(?:.*)`, `^/.*`, `(.*)` ...: nothing narrows the
          # path before the wildcard. `/foo(.*)` and `/x.+` do narrow it.
          lib.any (
            e: lib.any (p: lib.match "\\^?/?[(]*(\\?:)?\\.[*+].*" p != null) (e.src_paths or [ ])
          ) entries;
      in
      # LoadCredential= copies the cert at start, so vmauth only sees a
      # renewed one if it is restarted: the ACME cert must list it.
      lib.optional
        (
          cfg.https.enable
          && cfg.https.acmeCertName != null
          && !(lib.elem "vmauth.service" (
            (config.security.acme.certs.${cfg.https.acmeCertName} or { }).reloadServices or [ ]
          ))
        )
        ''
          services.victoriaStack.vmauth.https.acmeCertName = "${cfg.https.acmeCertName}",
          but security.acme.certs."${cfg.https.acmeCertName}".reloadServices does
          not include "vmauth.service" -- vmauth would keep serving the old
          certificate after a renewal until it is restarted.
        ''
      ++ lib.optional (matchesEverything cfg.extraWriteUrlMap) ''
        services.victoriaStack.vmauth.extraWriteUrlMap has a src_paths
        pattern that matches every path (nothing narrows it before a wildcard) --
        every write-tier request would be routed by that entry.
      ''
      ++ lib.optional (matchesEverything cfg.extraReadUrlMap) ''
        services.victoriaStack.vmauth.extraReadUrlMap has a src_paths
        pattern that matches every path (nothing narrows it before a wildcard) --
        every read-tier request would be routed by that entry.
      ''
      ++ lib.optional (!cfg.requireAuthForWrites && cfg.writeTokensFile != null) ''
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
      ++ lib.optional topCfg.traces.enable "victoriatraces.service"
      # The MCP servers vmauth's /mcp/* routes proxy to. Their postStart runs
      # an HTTP readiness probe (mcp.nix), so `after` means "answering".
      ++ lib.optional topCfg.metrics.mcp.enable "mcp-victoriametrics.service"
      ++ lib.optional topCfg.logs.mcp.enable "mcp-victorialogs.service"
      ++ lib.optional topCfg.traces.mcp.enable "mcp-victoriatraces.service"
      # The cert files only exist once ACME has issued them (a first boot
      # would otherwise fail LoadCredential= and crash-loop until it has).
      ++ lib.optional (
        cfg.https.enable && cfg.https.acmeCertName != null
      ) "acme-${cfg.https.acmeCertName}.service";
      wants = lib.optional (
        cfg.https.enable && cfg.https.acmeCertName != null
      ) "acme-${cfg.https.acmeCertName}.service";
      wantedBy = [ "multi-user.target" ];

      # TCP probe, not HTTP: with -httpInternalListenAddr, /health is not served
      # on the data listener. Lets units ordered after vmauth (nginx) rely on it
      # listening, not just having forked.
      path = [ pkgs.wait4x ];
      postStart = "wait4x tcp ${listen.connectAddr cfg.listenAddress} --timeout 90s";

      serviceConfig = {
        LoadCredential =
          lib.optional (cfg.adminPasswordFile != null) "admin-password:${cfg.adminPasswordFile}"
          ++ lib.optional (cfg.readTokensFile != null) "read-tokens:${cfg.readTokensFile}"
          ++ lib.optional (cfg.writeTokensFile != null) "write-tokens:${cfg.writeTokensFile}"
          # Every TLS file goes through LoadCredential, public CA bundle
          # included: vmauth's DynamicUser then never depends on who owns
          # the file or what its mode is.
          ++ lib.optional (cfg.backendTls.caFile != null) "backend-tls-ca:${toString cfg.backendTls.caFile}"
          ++ lib.optional (cfg.backendTls.certFile != null) "backend-tls-cert:${cfg.backendTls.certFile}"
          ++ lib.optional (cfg.backendTls.keyFile != null) "backend-tls-key:${cfg.backendTls.keyFile}"
          ++ lib.optionals cfg.https.enable [
            "https-cert:${httpsCertSource}"
            "https-key:${httpsKeySource}"
          ];

        Environment = [
          "READ_URL_MAP_FILE=${readUrlMapFile}"
          "OPEN_INGEST_PATHS_FILE=${openIngestPathsFile}"
          "WRITE_URL_MAP_FILE=${writeUrlMapFile}"
          "READ_BACKEND_PREFIXES_FILE=${readBackendPrefixesFile}"
          "WRITE_BACKEND_PREFIXES_FILE=${writeBackendPrefixesFile}"
          "REQUIRE_AUTH_FOR_WRITES=${lib.boolToString cfg.requireAuthForWrites}"
          "ACCESS_LOG=${lib.boolToString cfg.accessLog}"
        ];

        ExecStartPre = "${lib.getExe renderConfig}";
        # escapeShellArgs, like the storage services: one list element is exactly
        # one argument (a plain space-join split "-x=a b" in two).
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/vmauth"
            "-auth.config=/run/vmauth/config.json"
          ]
          ++ map (l: "-httpListenAddr=${l.addr}") listeners
          # vmauth's own pages move off every -httpListenAddr listener onto this
          # one. It reads the SAME -tls/-tlsCertFile/-tlsKeyFile array slot as
          # listener 0, which is why, whenever any listener uses TLS, those
          # arrays are written out in full and keep a plain first entry.
          ++ [ "-httpInternalListenAddr=${cfg.internalListenAddress}" ]
          ++ lib.optionals anyTls (
            map (l: "-tls=${lib.boolToString l.tls}") listeners
            ++ map (l: "-tlsCertFile=${lib.optionalString l.tls "%d/https-cert"}") listeners
            ++ map (l: "-tlsKeyFile=${lib.optionalString l.tls "%d/https-key"}") listeners
          )
          ++ [
            "-http.idleConnTimeout=${cfg.idleConnTimeout}"
          ]
          ++ lib.optional (
            cfg.maxConcurrentRequests != null
          ) "-maxConcurrentRequests=${toString cfg.maxConcurrentRequests}"
          ++ lib.optional (
            cfg.maxConcurrentPerUserRequests != null
          ) "-maxConcurrentPerUserRequests=${toString cfg.maxConcurrentPerUserRequests}"
          ++ lib.optional cfg.backendTls.insecureSkipVerify "-backend.tlsInsecureSkipVerify=true"
          ++ lib.optional (cfg.backendTls.caFile != null) "-backend.tlsCAFile=%d/backend-tls-ca"
          # %d expands to $CREDENTIALS_DIRECTORY at the service manager
          # level (same pattern nixpkgs' own victoriametrics.nix module
          # uses for -httpAuth.password=file://%d/basic_auth_password) --
          # never a literal path, the credential is staged there by
          # LoadCredential= at runtime.
          ++ lib.optional (cfg.backendTls.certFile != null) "-backend.tlsCertFile=%d/backend-tls-cert"
          ++ lib.optional (cfg.backendTls.keyFile != null) "-backend.tlsKeyFile=%d/backend-tls-key"
          ++ selfMonitoring.mkFlags {
            selfMonitoring = cfg.selfMonitoring;
            metricsEnabled = topCfg.metrics.enable;
            metricsUrl = topCfg.metrics.effectiveUrl;
            job = "vmauth";
          }
          ++ cfg.extraFlags
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

        # Same hardening profile as the storage services (docs/decisions/0015),
        # minus LimitNOFILE, which has no confirmed basis for vmauth.
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
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
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

    # try-restart: a rotation while vmauth is stopped must not start it. A bad
    # file written mid-rotation restarts vmauth into the render script's error,
    # i.e. it fails closed.
    systemd.services.vmauth-secret-restart = lib.mkIf (watchedSecrets != { }) {
      description = "Restart vmauth after one of its secret files changed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.systemd.package}/bin/systemctl try-restart vmauth.service";
        CapabilityBoundingSet = "";
      };
    };

    systemd.paths = lib.mapAttrs' (
      name: path:
      lib.nameValuePair "vmauth-secret-watch-${name}" {
        description = "Watch vmauth's ${name} file for replacement";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = path;
          Unit = "vmauth-secret-restart.service";
        };
      }
    ) watchedSecrets;
  };
}
