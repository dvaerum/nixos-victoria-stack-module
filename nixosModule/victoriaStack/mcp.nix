{
  config,
  lib,
  pkgs,
  ...
}:

let
  topCfg = config.services.victoriaStack;

  # Each MCP server talks directly to its own backend over loopback, not
  # through vmauth -- by the time a request reaches the MCP server it's
  # already been authenticated (if at all) by vmauth's own /mcp/* routing,
  # so no credential logic is needed here (matches the real deployment-a
  # deployment this design generalizes from).
  mkMcpService =
    {
      name, # "metrics" | "logs" | "traces"
      serviceCfg, # topCfg.<name>
      envPrefix, # "VM" | "VL" | "VT"
      instanceType ? null, # only VM_INSTANCE_TYPE needs a value; VL/VT don't use this env var at all
      packagePath, # directory name under ../../packages
      binaryName,
      backendListenAddress,
      backendUnit, # "victoriametrics.service" | "victorialogs.service" | "victoriatraces.service"
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

          environment = {
            "${envPrefix}_INSTANCE_ENTRYPOINT" = "http://${backendListenAddress}";
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
          // lib.optionalAttrs (serviceCfg.mcp.disabledTools != [ ]) {
            MCP_DISABLED_TOOLS = lib.concatStringsSep "," serviceCfg.mcp.disabledTools;
          };

          serviceConfig = {
            ExecStart = "${serviceCfg.mcp.package}/bin/${binaryName}";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 5;

            # Hardening -- same general-purpose systemd profile applied
            # across this module (docs/decisions/0015); no readiness
            # check added (no documented HTTP health endpoint for the
            # mcp-victoria* binaries to poll).
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
      backendListenAddress = topCfg.metrics.listenAddress;
      backendUnit = "victoriametrics.service";
    })
    (mkMcpService {
      name = "logs";
      serviceCfg = topCfg.logs;
      envPrefix = "VL";
      packagePath = "mcp-victorialogs";
      binaryName = "mcp-victorialogs";
      backendListenAddress = topCfg.logs.listenAddress;
      backendUnit = "victorialogs.service";
    })
    (mkMcpService {
      name = "traces";
      serviceCfg = topCfg.traces;
      envPrefix = "VT";
      packagePath = "mcp-victoriatraces";
      binaryName = "mcp-victoriatraces";
      backendListenAddress = topCfg.traces.listenAddress;
      backendUnit = "victoriatraces.service";
    })
  ];
}
