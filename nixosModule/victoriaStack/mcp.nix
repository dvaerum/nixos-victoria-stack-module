{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;
  listen = import ./listen.nix { inherit lib; };
  inherit (import ./exec-escape.nix { inherit lib; }) escapeEnvironment;

  # One value for the readiness probe and, a minute above it, TimeoutStartSec.
  readinessTimeout = "90s";
  startTimeout = (import ./startup-timeout.nix { inherit lib; }).unitTimeout readinessTimeout;

  # Each MCP server talks directly to its own backend over loopback, not
  # through vmauth -- by the time a request reaches the MCP server it's
  # already been authenticated (if at all) by vmauth's own /mcp/* routing,
  # so no credential logic is needed here.
  mkMcpService =
    {
      name, # "metrics" | "logs" | "traces"
      serviceCfg, # topCfg.<name>
      envPrefix, # "VM" | "VL" | "VT"
      instanceType ? null, # only VM_INSTANCE_TYPE needs a value; VL/VT don't use this env var at all
      packagePath, # directory name under ../../packages
      binaryName,
      backendUnit, # "victoriametrics.service" | "victorialogs.service" | "victoriatraces.service"
      # mcp-victoriametrics hardcodes these as its fallback when
      # MCP_DISABLED_TOOLS is unset (pinned version 1.20.2); logs/traces have
      # no such default. Passing any value replaces it, so it is unioned in
      # below. See the `disabledTools` option text for why.
      upstreamDefaultDisabledTools ? [ ],
    }:
    {
      config = lib.mkIf serviceCfg.mcp.enable {
        systemd.services."mcp-victoria${name}" = {
          description = "mcp-victoria${name} (read-only MCP server for AI access to victoriaStack.${name})";
          after = [
            "network.target"
            backendUnit
          ];
          wantedBy = [ "multi-user.target" ];

          environment = lib.mapAttrs (_: escapeEnvironment) (
            {
              # effectiveUrl, not listenAddress: see docs/decisions/0019. Already
              # includes its scheme.
              "${envPrefix}_INSTANCE_ENTRYPOINT" = serviceCfg.effectiveUrl;
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
            // lib.optionalAttrs (upstreamDefaultDisabledTools != [ ] || serviceCfg.mcp.disabledTools != [ ]) {
              # Union, so a user's list never drops upstreamDefaultDisabledTools.
              MCP_DISABLED_TOOLS = lib.concatStringsSep "," (
                lib.unique (upstreamDefaultDisabledTools ++ serviceCfg.mcp.disabledTools)
              );
            }
          );

          # HTTP probe, like the storage services': all 3 mcp-victoria* binaries
          # serve /health/readiness. Without it vmauth's `after` on this unit
          # (vmauth.nix) would only mean "started", not "answering".
          path = [ pkgs.wait4x ];
          postStart =
            let
              bindAddr = listen.connectAddr serviceCfg.mcp.listenAddress;
            in
            "wait4x http http://${bindAddr}/health/readiness --timeout ${readinessTimeout}";

          serviceConfig = {
            ExecStart = "${serviceCfg.mcp.package}/bin/${binaryName}";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 5;
            TimeoutStartSec = startTimeout;

            # Hardening -- same general-purpose systemd profile applied
            # across this module (docs/decisions/0015). Readiness is
            # handled above via postStart's wait4x probe, not here.
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
      instanceType = "single";
      packagePath = "mcp-victoriametrics";
      binaryName = "mcp-victoriametrics";
      backendUnit = "victoriametrics.service";
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
    })
    (mkMcpService {
      name = "logs";
      serviceCfg = topCfg.logs;
      envPrefix = "VL";
      packagePath = "mcp-victorialogs";
      binaryName = "mcp-victorialogs";
      backendUnit = "victorialogs.service";
    })
    (mkMcpService {
      name = "traces";
      serviceCfg = topCfg.traces;
      envPrefix = "VT";
      packagePath = "mcp-victoriatraces";
      binaryName = "mcp-victoriatraces";
      backendUnit = "victoriatraces.service";
    })
  ];
}
