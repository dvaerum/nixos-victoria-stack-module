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
          };

          serviceConfig = {
            ExecStart = "${serviceCfg.mcp.package}/bin/${binaryName}";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 5;
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
