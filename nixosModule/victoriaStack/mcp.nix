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
            # effectiveUrl (docs/decisions/0019), not listenAddress
            # directly -- this module's own documented seam for a future
            # remote-backend option, read by vmauth.nix/grafana.nix/
            # nginx.nix already; mcp.nix was a 4th consumer missed when
            # that ADR was written, silently left pointing at the local
            # listenAddress even if a future remoteUrl override changed
            # effectiveUrl elsewhere. Already includes its own scheme, no
            # "http://" prepend needed here.
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
          // lib.optionalAttrs (serviceCfg.mcp.disabledTools != [ ]) {
            MCP_DISABLED_TOOLS = lib.concatStringsSep "," serviceCfg.mcp.disabledTools;
          };

          # wait4x TCP-only (not wait4x http, unlike the 3 storage
          # services' own postStart probes): confirmed no documented HTTP
          # health endpoint exists for any of the 3 mcp-victoria*
          # binaries, only a mere TCP accept is checkable. Without this,
          # vmauth's own `after`/`wants` on this unit (vmauth.nix) only
          # guaranteed this unit was started, not that it was actually
          # listening yet -- the same class of race already fixed for
          # vmauth itself against the storage services.
          path = [ pkgs.wait4x ];
          postStart =
            let
              isWildcard =
                lib.hasPrefix "0.0.0.0:" serviceCfg.mcp.listenAddress
                || lib.hasPrefix "[::]:" serviceCfg.mcp.listenAddress;
              bindAddr =
                if isWildcard then
                  "127.0.0.1:${lib.last (lib.splitString ":" serviceCfg.mcp.listenAddress)}"
                else
                  serviceCfg.mcp.listenAddress;
            in
            "wait4x tcp ${bindAddr} --timeout 90s";

          serviceConfig = {
            ExecStart = "${serviceCfg.mcp.package}/bin/${binaryName}";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 5;

            # Hardening -- same general-purpose systemd profile applied
            # across this module (docs/decisions/0015). Readiness is
            # handled above via postStart's TCP-only wait4x probe, not
            # here.
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
      backendUnit = "victoriametrics.service";
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
