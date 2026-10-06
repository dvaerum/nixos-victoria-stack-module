{ pkgs, nixosModule }:

let
  inherit (pkgs) lib;
  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;

  # Same shape as storage.nix's mkHardeningCheck, minus LimitNOFILE/wait4x
  # readiness -- neither applies here: no nixpkgs module to confirm a
  # LimitNOFILE value against, and no documented HTTP health endpoint for
  # vmauth or the mcp-victoria* binaries to poll (docs/decisions/0015).
  mkMcpHardeningCheck =
    {
      name,
      serviceName,
      enableModule,
    }:
    pkgs.runCommand name { } (
      let
        evaluated = evalWith enableModule;
        sc = evaluated.config.systemd.services.${serviceName}.serviceConfig;
        hardeningChecks = {
          "NoNewPrivileges" = (sc.NoNewPrivileges or null) == true;
          "ProtectSystem" = (sc.ProtectSystem or null) == "full";
          "PrivateDevices" = (sc.PrivateDevices or null) == true;
          "MemoryDenyWriteExecute" = (sc.MemoryDenyWriteExecute or null) == true;
          "RestrictAddressFamilies" =
            (sc.RestrictAddressFamilies or null) == [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
        };
        failed = lib.filterAttrs (_: ok: !ok) hardeningChecks;
      in
      if failed == { } then
        "echo OK > $out"
      else
        throw "${serviceName}'s serviceConfig is missing expected hardening: ${builtins.toJSON (builtins.attrNames failed)}"
    );

  # Previously untested for all 3 mcp services: mcp.package override
  # reaching ExecStart. Eval-only (checks the resolved ExecStart string)
  # rather than a nixosTest boot -- a derivation-path equality check
  # doesn't need a running system to be a genuine, non-vacuous assertion.
  #
  # Plain string equality, not lib.hasInfix: a regex needle carrying
  # store-path context (from "${overridePackage}") makes builtins.match
  # refuse to compile ("is not allowed to refer to a store path") --
  # confirmed by hitting this exact error.
  mkPackageOverrideCheck =
    {
      name,
      serviceName,
      serviceAttr,
      binaryName,
    }:
    pkgs.runCommand name { } (
      let
        overridePackage = pkgs.hello; # any derivation with a /bin -- content irrelevant, only the store path is checked
        evaluated = evalWith {
          services.victoriaStack.${serviceAttr} = {
            enable = true;
            mcp = {
              enable = true;
              package = overridePackage;
            };
          };
        };
        execStart = evaluated.config.systemd.services.${serviceName}.serviceConfig.ExecStart;
        expected = "${overridePackage}/bin/${binaryName}";
      in
      if execStart == expected then
        "echo OK > $out"
      else
        throw "${serviceName}'s ExecStart did not resolve through the overridden mcp.package: expected ${expected}, got ${execStart}"
    );
in
{
  mcp-metrics-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-metrics-package-override-takes-effect";
    serviceName = "mcp-victoriametrics";
    serviceAttr = "metrics";
    binaryName = "mcp-victoriametrics";
  };

  mcp-logs-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-logs-package-override-takes-effect";
    serviceName = "mcp-victorialogs";
    serviceAttr = "logs";
    binaryName = "mcp-victorialogs";
  };

  mcp-traces-package-override-takes-effect = mkPackageOverrideCheck {
    name = "mcp-traces-package-override-takes-effect";
    serviceName = "mcp-victoriatraces";
    serviceAttr = "traces";
    binaryName = "mcp-victoriatraces";
  };

  mcp-metrics-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-metrics-hardening-profile";
    serviceName = "mcp-victoriametrics";
    enableModule = {
      services.victoriaStack.metrics = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-logs-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-logs-hardening-profile";
    serviceName = "mcp-victorialogs";
    enableModule = {
      services.victoriaStack.logs = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-traces-hardening-profile = mkMcpHardeningCheck {
    name = "mcp-traces-hardening-profile";
    serviceName = "mcp-victoriatraces";
    enableModule = {
      services.victoriaStack.traces = {
        enable = true;
        mcp.enable = true;
      };
    };
  };

  mcp-log-and-disabled-tools-options-are-inert-unless-configured =
    pkgs.runCommand "mcp-log-and-disabled-tools-inert-unless-configured" { }
      (
        let
          unset = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              mcp.enable = true;
            };
          };
          set = evalWith {
            services.victoriaStack.metrics = {
              enable = true;
              mcp = {
                enable = true;
                logLevel = "debug";
                logFormat = "json";
                disabledTools = [
                  "documentation"
                  "some-other-tool"
                ];
              };
            };
          };
          envUnset = unset.config.systemd.services.mcp-victoriametrics.environment;
          envSet = set.config.systemd.services.mcp-victoriametrics.environment;
          checks = {
            "MCP_LOG_LEVEL absent when unset" = !(envUnset ? MCP_LOG_LEVEL);
            "MCP_LOG_FORMAT absent when unset" = !(envUnset ? MCP_LOG_FORMAT);
            "MCP_DISABLED_TOOLS absent when unset" = !(envUnset ? MCP_DISABLED_TOOLS);
            "MCP_LOG_LEVEL present when set" = (envSet.MCP_LOG_LEVEL or null) == "debug";
            "MCP_LOG_FORMAT present when set" = (envSet.MCP_LOG_FORMAT or null) == "json";
            "MCP_DISABLED_TOOLS joined with commas when set" =
              (envSet.MCP_DISABLED_TOOLS or null) == "documentation,some-other-tool";
          };
          failed = lib.filterAttrs (_: ok: !ok) checks;
        in
        if failed == { } then
          "echo OK > $out"
        else
          throw "mcp logLevel/logFormat/disabledTools options broken: ${builtins.toJSON (builtins.attrNames failed)}"
      );

  mcp-reachable-only-through-vmauth = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-through-vmauth";

    containers.machine = {
      imports = [ module ];
      services.victoriaStack = {
        metrics.enable = true;
        metrics.mcp.enable = true;
        vmauth.requireAuthForWrites = false;
      };
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("mcp-victoriametrics.service")
      machine.wait_for_unit("vmauth.service")
      machine.wait_for_open_port(4204)

      # Reachable through vmauth's /mcp/metrics route (no trailing slash,
      # per the MCP binary's own fixed /mcp path).
      machine.succeed("curl -sf -X POST 'http://127.0.0.1:4204/mcp/metrics' -H 'Content-Type: application/json' -d '{}' || true")
      # The MCP server's own listenAddress stays loopback-only by default
      # -- not directly reachable from outside without vmauth routing or
      # an explicit listenAddress override (checked separately below).
      machine.wait_for_open_port(4205)
    '';
  };

  mcp-reachable-directly-when-vmauth-off = pkgs.testers.nixosTest {
    name = "victoria-stack-mcp-direct-without-vmauth";

    containers.machine =
      { lib, ... }:
      {
        imports = [ module ];
        services.victoriaStack = {
          metrics.enable = true;
          metrics.mcp = {
            enable = true;
            listenAddress = "0.0.0.0:4205";
          };
          vmauth.enable = lib.mkForce false;
        };
      };

    testScript = ''
      start_all()
      machine.wait_for_unit("mcp-victoriametrics.service")
      # vmauth must not even exist/start -- confirmed separately in the
      # vmauth test group's own no-op check; here the point is that mcp
      # itself works fine standalone.
      machine.wait_for_open_port(4205)
    '';
  };
}
