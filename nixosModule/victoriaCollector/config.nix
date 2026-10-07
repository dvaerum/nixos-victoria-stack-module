{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaCollector;
  needsAlloyOtlp = cfg.metrics.enable || cfg.traces.enable;
  configAlloyText = import ./config.alloy.nix { inherit lib cfg; };

  journaldWriteEndpoint =
    if cfg.journaldWriteEndpoint != null then cfg.journaldWriteEndpoint else cfg.writeEndpoint;

  # systemd-journal-upload has no option to skip client-certificate
  # loading for an https:// endpoint at all -- the server side (the
  # gateway's own open write/ingest path, when requireAuthForWrites is
  # false, or any Basic/Bearer-authenticated path otherwise) never
  # requests or validates a client cert, so any syntactically valid pair
  # satisfies the requirement without meaning anything. Throwaway,
  # generated at build time -- not a secret.
  dummyClientCert =
    pkgs.runCommand "journal-upload-dummy-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
          -subj "/CN=journal-upload-dummy" \
          -keyout $out/key.pem -out $out/cert.pem
      '';

  renderJournalUploadTokenHeader = pkgs.writeShellApplication {
    name = "victoria-collector-journal-upload-token-header";
    text = ''
      mkdir -p /run/systemd/journal-upload.conf.d
      conf=/run/systemd/journal-upload.conf.d/50-write-token.conf
      {
        echo "[Upload]"
        echo "Header=Authorization: Bearer $(cat "$CREDENTIALS_DIRECTORY/write-token")"
      } > "$conf"
      # systemd's own real systemd-journal-upload.service unit
      # (confirmed directly from the installed systemd package) runs as
      # DynamicUser=yes with SupplementaryGroups=systemd-journal -- the
      # ephemeral per-boot UID has no other way to read a file this
      # root-run oneshot wrote. chmod 600 (owner-only) left it genuinely
      # unreadable: confirmed by actually running this for the first
      # time (previously blocked locally by missing uid-range), which
      # hit "Failed to open .../50-write-token.conf: Permission denied"
      # and crash-looped forever. Matches nixpkgs' own journald-upload.nix
      # module comment for ServerKeyFile: "must be readable by the
      # systemd-journal group".
      chgrp systemd-journal "$conf"
      chmod 640 "$conf"
    '';
  };

  # alloy.service's own preStart runs too late to populate an
  # EnvironmentFile=: systemd resolves EnvironmentFile= for every exec in
  # the unit -- including ExecStartPre= itself -- before that exec runs,
  # so a file only created by the unit's own preStart never exists yet.
  # Same trap ADR 0012 already avoids for journal-upload; fixed here the
  # same way, a dedicated oneshot ordered strictly before alloy.service.
  #
  # Runs under its OWN DynamicUser, not root: per systemd.exec(5),
  # EnvironmentFile= is read by the service manager itself (PID1), before
  # the target process execs -- file ownership is irrelevant to that
  # read, root bypasses normal permission checks regardless. Unlike
  # journal-upload's oneshot (which writes under /run/systemd/, a
  # root-owned 755 directory this unit has no write access to otherwise),
  # there is no such requirement here -- running as root was an avoidable
  # default, not a necessity (docs/decisions/0015, 0020).
  renderAlloyWriteToken = pkgs.writeShellApplication {
    name = "victoria-collector-alloy-write-token";
    text = ''
      env=/run/alloy-write-token/write-token.env
      echo "VICTORIA_WRITE_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/write-token")" > "$env"
      chmod 600 "$env"
    '';
  };
in
{
  config = lib.mkMerge [
    {
      services.victoriaCollector.alloy.package = lib.mkDefault pkgs.grafana-alloy;
    }

    (lib.mkIf needsAlloyOtlp {
      services.alloy = {
        enable = true;
        package = cfg.alloy.package;
        # otelcol.storage.file (the disk-backed sending_queue used in
        # config.alloy.nix) is still "Public preview" upstream -- this
        # flag is what those blocks actually need to be honored at all.
        extraFlags = [ "--stability.level=public-preview" ] ++ cfg.alloy.extraFlags;
        environmentFile = lib.mkIf (cfg.writeTokenFile != null) "/run/alloy-write-token/write-token.env";
      };

      environment.etc."alloy/config.alloy".text = configAlloyText;

      # NOT systemd.services.alloy.restartTriggers -- nixpkgs' own alloy
      # module (nixos/modules/services/monitoring/alloy.nix) already sets
      # reloadTriggers against every environment.etc."alloy/*.alloy"
      # source (which "alloy/config.alloy" above matches exactly),
      # wired to ExecReload = kill -SIGHUP, specifically so config
      # changes reload in place rather than restarting (Alloy's own
      # module docs: "will continue running in last valid state" across
      # a reload). A previously-added explicit restartTriggers here, set
      # to the SAME content, shadowed that: confirmed directly in a real
      # VM test (switch-to-configuration between two generations
      # differing only in hostType) -- with restartTriggers present,
      # alloy.service's MainPID changed (a genuine stop+start); with it
      # removed, the PID stays stable (a genuine in-place reload).
      # A hard restart here was never a deliberate choice, just an
      # artifact of writing this before nixpkgs' own reloadTriggers
      # existed for this module -- this fix costs a dropped OTLP
      # receiver connection + host-metrics gap on every unrelated config
      # change (hostType, queue size, TLS/retry tuning, writeEndpoint)
      # for no reason.

      # Same-host ordering fix: if victoriaStack is composed on this same
      # host (the all-in-one single-machine deployment shape), vmauth
      # could otherwise still be starting (or not yet listening) when
      # alloy's own first export attempt fires. A plain unit name here is
      # a safe no-op on a collector-only host where no such unit exists
      # at all -- systemd silently ignores an After=/Wants= target that
      # isn't defined, confirmed behavior, not assumed. Cross-host
      # collector/stack splits (this project's other real deployment
      # shape) get no benefit from this -- see the startLimitIntervalSec
      # fix below for that case instead.
      systemd.services.alloy.after = [ "vmauth.service" ];
      systemd.services.alloy.wants = [ "vmauth.service" ];

      # DynamicUser implies ProtectSystem=strict (confirmed via
      # systemd.exec(5)), which blocks writes anywhere not explicitly
      # allow-listed via StateDirectory=/RuntimeDirectory=/
      # ReadWritePaths=. The default queue.directory
      # (/var/lib/alloy/queue) already sits inside alloy's own
      # StateDirectory="alloy" (nixpkgs' own alloy module); anything
      # outside that tree -- the exact "point it at a bigger disk" use
      # case queue.directory's own docs invite -- needs an explicit
      # ReadWritePaths entry or it fails silently at Alloy's own runtime,
      # uncaught by Nix eval or systemd itself. See docs/decisions/0020.
      # The CA bundle reaches Alloy's dynamic user as a systemd credential
      # (config.alloy.nix points ca_file at it), so the file's owner and mode
      # don't matter -- same rule as every other TLS/secret file here.
      systemd.services.alloy.serviceConfig.LoadCredential = lib.optional (
        cfg.alloy.tlsCaFile != null
      ) "tls-ca:${toString cfg.alloy.tlsCaFile}";

      systemd.services.alloy.serviceConfig.ReadWritePaths = lib.optional (
        !(lib.hasPrefix "/var/lib/alloy/" (toString cfg.queue.directory))
      ) (toString cfg.queue.directory);

      # Rendered by victoria-collector-alloy-write-token (see above) --
      # NOT this unit's own preStart, which runs too late to satisfy its
      # own EnvironmentFile=.
      systemd.services.victoria-collector-alloy-write-token = lib.mkIf (cfg.writeTokenFile != null) {
        description = "Render alloy's write-token EnvironmentFile=";
        before = [ "alloy.service" ];
        wantedBy = [ "alloy.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "write-token:${cfg.writeTokenFile}" ];
          ExecStart = lib.getExe renderAlloyWriteToken;

          # Own DynamicUser + its own RuntimeDirectory (deliberately NOT
          # alloy.service's own "alloy" StateDirectory -- two different
          # dynamic UIDs sharing one directory is its own hazard) --
          # see the long comment on renderAlloyWriteToken above for why
          # this doesn't need root the way journal-upload's oneshot does.
          DynamicUser = true;
          RuntimeDirectory = "alloy-write-token";
          RuntimeDirectoryMode = "0700";

          # Lighter hardening pass than the long-running services --
          # this unit runs once per boot and exits, but the basics still
          # cost nothing for a unit that handles a plaintext secret,
          # however briefly (docs/decisions/0015).
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
        };
      };
    })

    (lib.mkIf cfg.logs.enable {
      services.journald.upload = {
        enable = true;
        settings.Upload = {
          URL = "${journaldWriteEndpoint}/insert/journald";
        }
        // lib.optionalAttrs (lib.hasPrefix "https" journaldWriteEndpoint) {
          ServerKeyFile = "${dummyClientCert}/key.pem";
          ServerCertificateFile = "${dummyClientCert}/cert.pem";
          # Staged as a credential (below), so the bundle's owner/mode don't
          # matter to systemd-journal-upload's dynamic user.
          TrustedCertificateFile = "/run/credentials/systemd-journal-upload.service/trusted-ca";
        };
      };

      systemd.services.systemd-journal-upload.serviceConfig.LoadCredential =
        lib.optional (lib.hasPrefix "https" journaldWriteEndpoint) "trusted-ca:${toString cfg.trustedCertificateFile}";

      # The write-token header drop-in: a dedicated, narrowly-scoped root
      # oneshot, NOT systemd-journal-upload.service's own preStart -- see
      # docs/decisions/0012 for why (that unit runs hardened/DynamicUser,
      # with no write access to /run/systemd/ at all).
      systemd.services.victoria-collector-journal-upload-token = lib.mkIf (cfg.writeTokenFile != null) {
        description = "Render systemd-journal-upload's write-token Header= drop-in";
        before = [ "systemd-journal-upload.service" ];
        wantedBy = [ "systemd-journal-upload.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "write-token:${cfg.writeTokenFile}" ];
          ExecStart = lib.getExe renderJournalUploadTokenHeader;

          # Stays root -- confirmed, not assumed: /run/systemd is mode
          # 755, owned root:root on a real machine, so writing a new
          # subdirectory under it genuinely requires root (unlike the
          # alloy write-token oneshot above, which doesn't).
          # Lighter hardening pass than the long-running services --
          # this unit runs once per boot and exits, but the basics still
          # cost nothing for a unit that handles a plaintext secret,
          # however briefly (docs/decisions/0015).
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
        };
      };

      # Unlike the alloy write-token oneshot above (whose failure is
      # self-enforcing: a missing EnvironmentFile= is a hard systemd
      # failure for the consuming unit, per systemd.exec(5)), a drop-in
      # config directory under /run/systemd/<unit>.conf.d/ with nothing
      # in it is NOT inherently a failure -- systemd just falls back to
      # the base unit config. Without an explicit `requires`, a failed
      # token render here would let systemd-journal-upload.service start
      # anyway, silently uploading unauthenticated (every upload then
      # individually rejected by the gateway, rather than a visible
      # systemctl --failed). `before`/`wantedBy` alone only order it,
      # they don't make the consumer depend on its success.
      systemd.services.systemd-journal-upload.requires = lib.mkIf (cfg.writeTokenFile != null) [
        "victoria-collector-journal-upload-token.service"
      ];

      # Same-host ordering fix, same reasoning as alloy's above -- a safe
      # no-op on a collector-only host where vmauth.service doesn't exist.
      systemd.services.systemd-journal-upload.after = [ "vmauth.service" ];
      systemd.services.systemd-journal-upload.wants = [ "vmauth.service" ];

      # Cross-host fix: a collector on a laptop or anything else with an
      # intermittent network has no ordering fix available -- the gateway
      # genuinely isn't reachable yet, for an unbounded amount of time,
      # not a brief same-host startup race. systemd's own default
      # StartLimitIntervalSec/StartLimitBurst (nixpkgs' systemd-journal-
      # upload.service ships its own escalating Restart=/RestartSec=
      # backoff up to 60s, untouched here) would eventually hit the
      # permanent-stop ceiling and require a manual `systemctl
      # reset-failed` -- wrong for a host that's expected to go offline
      # and come back on its own schedule. 0 disables the ceiling
      # entirely (systemd.service(5): "If set to 0, the limiting of start
      # rate is disabled"), confirmed a real top-level NixOS option, not
      # hidden in unitConfig.
      systemd.services.systemd-journal-upload.startLimitIntervalSec = 0;
    })
  ];
}
