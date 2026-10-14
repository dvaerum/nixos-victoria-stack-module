{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  listen = import ./listen.nix { inherit lib; };
  restartBackoff = import ../restart-backoff.nix;
  readiness = import ./readiness.nix { inherit lib pkgs; };
  inherit (import ./exec-escape.nix { inherit lib; }) escapeEnvironment;

  # One value for the readiness probe and, a minute above it, TimeoutStartSec.
  readinessTimeout = "90s";
  startTimeout = (import ./startup-timeout.nix { inherit lib; }).unitTimeout readinessTimeout;

  # The MCP servers call vmauth's read tier (loopback data
  # listener) with the caller's own Authorization header
  # (MCP_PASSTHROUGH_HEADERS), so vmauth stays the one authority: token tier,
  # closed allow-list, backend scope (docs/decisions/0023). The MCP unit holds
  # no credential and logs none.
  vmauthUrl = "http://${listen.connectAddr topCfg.vmauth.listenAddress}";

  mkMcpService =
    {
      name, # "metrics" | "logs" | "traces"
      serviceCfg, # topCfg.<name>
      envPrefix, # "VM" | "VL" | "VT"
      instanceType ? null, # only VM_INSTANCE_TYPE needs a value; VL/VT don't use this env var at all
      packagePath, # directory name under ../../packages
      binaryName,
      backendUnit, # "vmselect.service" | "victorialogs.service" | "victoriatraces.service"
      vmauthPrefix, # read-tier path prefix: "metrics" | "logs" | "traces"
      # mcp-victoriametrics hardcodes these as its fallback when
      # MCP_DISABLED_TOOLS is unset (the version pinned in
      # packages/mcp-victoriametrics/package.nix); logs/traces have no such
      # default. Passing any value replaces it, so it is unioned in
      # below. See the `disabledTools` option text for why.
      upstreamDefaultDisabledTools ? [ ],
      # Tools that read /flags or /api/v1/status/tsdb or show other users'
      # query text (docs/decisions/0023). Other tools off the allow-list stay
      # listed and fail with vmauth's 400. Not operator-liftable.
      moduleDefaultDisabledTools ? [ ],
    }:
    let
      disabledTools = lib.unique (
        upstreamDefaultDisabledTools ++ moduleDefaultDisabledTools ++ serviceCfg.mcp.disabledTools
      );
    in
    {
      config = lib.mkIf serviceCfg.mcp.enable {
        systemd.services."mcp-victoria${name}" = {
          description = "mcp-victoria${name} (read-only MCP server for AI access to victoriaStack.${name})";
          after = [
            "network.target"
            backendUnit
          ]
          # Ordering only, no Wants=: a Wants= makes every MCP restart enqueue a
          # start job for vmauth, which cuts short vmauth's own restart backoff
          # (the restart-backoff test caught shrinking delays). vmauth is
          # enabled anyway (assertions.nix).
          ++ [ "vmauth.service" ];
          wantedBy = [ "multi-user.target" ];

          environment = lib.mapAttrs (_: escapeEnvironment) (
            {
              "${envPrefix}_INSTANCE_ENTRYPOINT" = "${vmauthUrl}/${vmauthPrefix}";
              MCP_PASSTHROUGH_HEADERS = "Authorization";
              MCP_SERVER_MODE = "http";
              MCP_LISTEN_ADDR = serviceCfg.mcp.listenAddress;
            }
            // lib.optionalAttrs (instanceType != null) {

              "${envPrefix}_INSTANCE_TYPE" = instanceType;
            }
            # MCP_LOG_LEVEL/MCP_LOG_FORMAT/MCP_DISABLED_TOOLS are identical
            # across all three mcp-victoria* binaries. Inert unless configured.
            // lib.optionalAttrs (serviceCfg.mcp.logLevel != null) {
              MCP_LOG_LEVEL = serviceCfg.mcp.logLevel;
            }
            // lib.optionalAttrs (serviceCfg.mcp.logFormat != null) {
              MCP_LOG_FORMAT = serviceCfg.mcp.logFormat;
            }
            // lib.optionalAttrs (disabledTools != [ ]) {
              # Union, so a user's list never drops the upstream defaults.
              MCP_DISABLED_TOOLS = lib.concatStringsSep "," disabledTools;
            }
          );

          # HTTP probe, like the storage services': all 3 mcp-victoria* binaries
          # serve /health/readiness, so the unit counts as started only once the
          # server answers. (vmauth lists no MCP unit: ordering cycle, vmauth.nix.)
          serviceConfig = {
            ExecStart = "${serviceCfg.mcp.package}/bin/${binaryName}";
            ExecStartPost = readiness.command {
              unit = "mcp-victoria${name}.service";
              kind = "http";
              target = "http://${listen.connectAddr serviceCfg.mcp.listenAddress}/health/readiness";
              timeout = readinessTimeout;
            };
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 5;
            inherit (restartBackoff) RestartSteps RestartMaxDelaySec;
            TimeoutStartSec = startTimeout;

            # Hardening -- same general-purpose systemd profile applied
            # across this module (docs/decisions/0015). Readiness is
            # handled above via ExecStartPost, not here.
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

        services.victoriaStack.${name}.mcp.package = lib.mkDefault (
          pkgs.callPackage (./../../packages + "/${packagePath}/package.nix") { }
        );
      };
    };
in
{
  imports = [
    (mkMcpService {
      name = "metrics";
      serviceCfg = topCfg.metrics;
      envPrefix = "VM";
      # Not "cluster": that would build
      # <entrypoint>/select/<tenant>/prometheus/api/v1/..., which vmauth's
      # read tier does not allow. The client paths on its `/metrics` prefix
      # are what vmauth rewrites onto vmselect, and the token (not an MCP
      # option) decides the tenant.
      instanceType = "single";
      packagePath = "mcp-victoriametrics";
      binaryName = "mcp-victoriametrics";
      backendUnit = "vmselect.service";
      vmauthPrefix = "metrics";
      # mcp-victoriametrics' own config.go (see the pinned version above).
      upstreamDefaultDisabledTools = [
        "export"
        "flags"
        "metric_relabel_debug"
        "downsampling_filters_debug"
        "retention_filters_debug"
        "test_rules"
      ];
      # active_queries/top_queries show other users' query text. tsdb_status,
      # alerts (/vmalert/api/v1/alerts), rules (/vmalert/api/v1/rules),
      # metric_statistics (/api/v1/status/metric_names_stats) and
      # prettify_query (/prettify-query) call endpoints that are not on
      # vmauth's read allow-list, so they always get its 400.
      moduleDefaultDisabledTools = [
        "active_queries"
        "top_queries"
        "tsdb_status"
        "alerts"
        "rules"
        "metric_statistics"
        "prettify_query"
      ];
    })
    (mkMcpService {
      name = "logs";
      serviceCfg = topCfg.logs;
      envPrefix = "VL";
      packagePath = "mcp-victorialogs";
      binaryName = "mcp-victorialogs";
      backendUnit = "victorialogs.service";
      vmauthPrefix = "logs";
      # `flags` reads /flags, outside vmauth's /logs/select/ allow-list.
      moduleDefaultDisabledTools = [ "flags" ];
    })
    (mkMcpService {
      name = "traces";
      serviceCfg = topCfg.traces;
      envPrefix = "VT";
      packagePath = "mcp-victoriatraces";
      binaryName = "mcp-victoriatraces";
      backendUnit = "victoriatraces.service";
      vmauthPrefix = "traces";
    })
  ];
}
