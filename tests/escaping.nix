{ pkgs, nixosModule }:

# User-supplied strings must reach a unit's process byte for byte. systemd
# reads C escapes and expands specifiers inside the quotes of an ExecStart=
# line, so a backslash, `%` or `$` typed by the user is mangled unless the
# module escapes it first (nixosModule/victoriaStack/exec-escape.nix).
let
  inherit (pkgs) lib;

  module = nixosModule.nixosModules.victoriaStack;

  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) evalWith;

  # A backslash, a backslash before a quote, a doubled backslash, a specifier,
  # a variable, a space, double and single quotes.
  trick = ''a\b \\ \"q" 50%h ''${HOME} ''$$ x"y 'z' end'';

  # Flag the binaries accept with any text: it only matters with -envflag.enable and is otherwise just echoed.
  flag = "-envflag.prefix=${trick}";

  trickFile = pkgs.writeText "exec-escape-trick" trick;

  allEnabled = {
    services.victoriaStack = {
      metrics = {
        enable = true;
        extraFlags = [ flag ];
        # MCP's user text reaches its process through Environment=.
        mcp = {
          enable = true;
          disabledTools = [ trick ];
        };
      };
      logs = {
        enable = true;
        extraFlags = [ flag ];
      };
      traces = {
        enable = true;
        extraFlags = [ flag ];
      };
      vmauth.extraFlags = [ flag ];
    };
  };

  # (user text, the quoted argument its ExecStart must carry): the text escaped
  # for systemd, then quoted for the shell-style splitter.
  table = [
    {
      name = "backslash";
      input = ''-x=a\b'';
      rendered = ''-x=a\\b'';
    }
    {
      name = "doubled backslash";
      input = ''-x=a\\b'';
      rendered = ''-x=a\\\\b'';
    }
    {
      name = "backslash before a quote";
      input = ''-x=a\"b'';
      rendered = ''-x=a\\"b'';
    }
    {
      name = "trailing backslash";
      input = ''-x=a\'';
      rendered = ''-x=a\\'';
    }
    {
      name = "specifier";
      input = "-x=50%h";
      rendered = "-x=50%%h";
    }
    {
      name = "variable";
      input = "-x=$HOME";
      rendered = "-x=$$HOME";
    }
    {
      name = "space";
      input = "-x=a b";
      rendered = "-x=a b";
    }
    {
      name = "double quote";
      input = ''-x=say "hi"'';
      rendered = ''-x=say "hi"'';
    }
    {
      name = "single quote";
      input = "-x=it's";
      rendered = "-x=it'\\''s";
    }
  ];

  execStartsFor =
    input:
    let
      e = evalWith {
        services.victoriaStack = {
          metrics = {
            enable = true;
            extraFlags = [ input ];
          };
          vmauth.extraFlags = [ input ];
        };
      };
    in
    [
      e.config.systemd.services.victoriametrics.serviceConfig.ExecStart
      e.config.systemd.services.vmauth.serviceConfig.ExecStart
    ];
in
{
  # Every row of the table, on a storage service and on vmauth.
  extra-flags-are-escaped-for-systemd = pkgs.runCommand "extra-flags-are-escaped-for-systemd" { } (
    let
      bad = lib.concatMap (
        row:
        lib.concatMap (
          exec: lib.optional (!lib.hasInfix " '${row.rendered}'" exec) "${row.name}: ${exec}"
        ) (execStartsFor row.input)
      ) table;
    in
    if bad == [ ] then "echo OK > $out" else throw "ExecStart does not carry: ${builtins.toJSON bad}"
  );

  # MCP's user text travels in Environment=, where systemd expands `%h`.
  mcp-environment-percent-is-escaped =
    let
      env =
        (evalWith {
          services.victoriaStack.metrics = {
            enable = true;
            mcp = {
              enable = true;
              disabledTools = [ "50%h" ];
            };
          };
        }).config.systemd.services.mcp-victoriametrics.environment;
    in
    pkgs.runCommand "mcp-environment-percent-is-escaped" { } (
      if lib.hasSuffix ",50%%h" env.MCP_DISABLED_TOOLS then
        "echo OK > $out"
      else
        throw "MCP_DISABLED_TOOLS keeps a bare %: ${env.MCP_DISABLED_TOOLS}"
    );

  # One real boot: every unit that renders user strings into ExecStart gets the
  # tricky value and the process must show it exactly.
  extra-flags-reach-the-process-literally = pkgs.testers.nixosTest {
    name = "victoria-stack-exec-escaping";

    containers.machine = {
      imports = [ module ];
      inherit (allEnabled) services;
    };

    testScript = ''
      start_all()
      trick = open("${trickFile}").read()
      expected = "-envflag.prefix=" + trick

      for unit in ["victoriametrics", "victorialogs", "victoriatraces", "vmauth"]:
          # Bounded: a unit that dies on a mangled flag must fail fast.
          machine.wait_until_succeeds(f"systemctl is-active {unit}.service", timeout=120)
          pid = machine.succeed(f"systemctl show {unit}.service --property=MainPID --value").strip()
          raw = machine.succeed(f"cat /proc/{pid}/cmdline")
          args = raw.split("\0")
          assert expected in args, f"{unit}: flag arrived mangled: {[a for a in args if 'envflag' in a]!r}, wanted {expected!r}"

      machine.wait_until_succeeds("systemctl is-active mcp-victoriametrics.service", timeout=120)
      pid = machine.succeed("systemctl show mcp-victoriametrics.service --property=MainPID --value").strip()
      env = machine.succeed(f"cat /proc/{pid}/environ").split("\0")
      tools = [e for e in env if e.startswith("MCP_DISABLED_TOOLS=")]
      assert tools and tools[0].endswith("," + trick), f"mcp: disabledTools arrived mangled: {tools!r}, wanted a value ending in {trick!r}"
    '';
  };
}
