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
      backendUnit, # "victoriametrics.service" | "vmselect.service" | "victorialogs.service" | "victoriatraces.service"
      vmauthPrefix, # read-tier path prefix: "metrics" | "logs" | "traces"
      # mcp-victoriametrics hardcodes these as its fallback when
      # MCP_DISABLED_TOOLS is unset (pinned version 1.20.2); logs/traces have
      # no such default. Passing any value replaces it, so it is unioned in
      # below. See the `disabledTools` option text for why.
      upstreamDefaultDisabledTools ? [ ],
      # Tools whose backend endpoint is outside vmauth's read-tier allow-list
      # or exposes other users' query text (docs/decisions/0023). Hidden so
      # clients do not see tools that always fail; not operator-liftable.
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
            # MCP_LOG_LEVEL/MCP_LOG_FORMAT/MCP_DISABLED_TOOLS -- confirmed
            # identical across all three mcp-victoria* binaries' own
            # READMEs. All inert unless configured.
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
          # serve /health/readiness. Without it vmauth's `after` on this unit
          # (vmauth.nix) would only mean "started", not "answering".
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
      # Stays "single" in cluster mode too: "cluster" would build
      # <entrypoint>/select/<tenant>/prometheus/api/v1/..., which vmauth's
      # read tier does not allow. The single-node paths on its `/metrics`
      # prefix are what vmauth rewrites onto vmselect, and the token (not an MCP
      # option) decides the tenant.
      instanceType = "single";
      packagePath = "mcp-victoriametrics";
      binaryName = "mcp-victoriametrics";
      backendUnit =
        if topCfg.metrics.mode == "cluster" then "vmselect.service" else "victoriametrics.service";
      vmauthPrefix = "metrics";
      # mcp-victoriametrics' own config.go, pinned version 1.20.2 --
      # confirmed directly from source, not assumed.
      upstreamDefaultDisabledTools = [
        "export"
        "flags"
        "metric_relabel_debug"
        "downsampling_filters_debug"
        "retention_filters_debug"
        "test_rules"
      ];
      # active_queries/top_queries show other users' query text; tsdb_status
      # reads /api/v1/status/tsdb. None is on vmauth's read allow-list.
      moduleDefaultDisabledTools = [
        "active_queries"
        "top_queries"
        "tsdb_status"
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
