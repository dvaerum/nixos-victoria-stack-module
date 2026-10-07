{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaCollector;
  common = import ./common.nix { inherit lib; };
  needsAlloyOtlp = common.needsAlloyOtlp cfg;
  configAlloyText = import ./config.alloy.nix { inherit lib cfg; };

  journaldWriteEndpoint = common.journaldEndpoint cfg;

  # `..` is rejected by assertions.nix, so a plain prefix test is sound here.
  queueOutsideStateDir = !(lib.hasPrefix "/var/lib/alloy/" (toString cfg.queue.directory));

  renderJournalUploadTokenHeader = pkgs.writeShellApplication {
    name = "victoria-collector-journal-upload-token-header";
    text = ''
      # The directory keeps the default 755: the uploader's DynamicUser reaches the
      # file through the systemd-journal group and must be able to traverse it.
      mkdir -p /run/systemd/journal-upload.conf.d
      # The file holds the write token: never world-readable, not even before the
      # chgrp/chmod below (this runs under the default umask 022).
      umask 027
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

      # Same shape as the storage services (docs/decisions/0009): dynamic user by
      # default; a queue directory the dynamic user cannot own draws a warning, and
      # `alloy.dynamicUser = false` is the way out.
      warnings =
        lib.optional
          (queueOutsideStateDir && cfg.alloy.dynamicUser && !cfg.alloy.suppressDynamicUserWarning)
          ''
            services.victoriaCollector.queue.directory (${toString cfg.queue.directory}) is
            outside /var/lib/alloy while Alloy runs as a systemd DynamicUser. A
            dynamic user can only write inside its own StateDirectory and nothing
            owns that directory for it, so Alloy would fail to write its queue
            there. Set services.victoriaCollector.alloy.dynamicUser = false (a
            static "alloy" user; the module then creates the directory for it), or
            services.victoriaCollector.alloy.suppressDynamicUserWarning = true once
            you have made the directory writable for Alloy's runtime user yourself.
          '';

      users.users.alloy = lib.mkIf (!cfg.alloy.dynamicUser) {
        isSystemUser = true;
        group = "alloy";
      };
      users.groups.alloy = lib.mkIf (!cfg.alloy.dynamicUser) { };

      systemd.tmpfiles.rules = lib.optional (
        !cfg.alloy.dynamicUser && cfg.alloy.manageTmpfiles && queueOutsideStateDir
      ) "d ${toString cfg.queue.directory} 0750 alloy alloy - -";

      # DynamicUser=yes implies this sandbox; DynamicUser=false drops it, so a
      # static user gets it spelled out. ReadWritePaths (above) keeps the queue
      # directory writable under ProtectSystem=strict.
      systemd.services.alloy.serviceConfig = lib.mkMerge [
        {
          # The CA bundle reaches Alloy's user as a systemd credential
          # (config.alloy.nix points ca_file at it), so the file's owner and mode
          # don't matter -- same rule as every other TLS/secret file here.
          LoadCredential = lib.optional (
            cfg.alloy.tlsCaFile != null
          ) "tls-ca:${toString cfg.alloy.tlsCaFile}";
          # DynamicUser implies ProtectSystem=strict, which blocks writes anywhere
          # not allow-listed via StateDirectory=/ReadWritePaths=; the default
          # queue.directory sits inside alloy's own StateDirectory, anything
          # outside needs an explicit entry or it fails silently at Alloy's own
          # runtime (docs/decisions/0020).
          ReadWritePaths = lib.optional queueOutsideStateDir (toString cfg.queue.directory);
        }
        (lib.mkIf (!cfg.alloy.dynamicUser) {
          DynamicUser = lib.mkForce false;
          User = "alloy";
          Group = "alloy";
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          PrivateTmp = true;
          RemoveIPC = true;
          NoNewPrivileges = true;
          RestrictSUIDSGID = true;
        })
      ];

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
      # systemd-journal-upload does not follow the https=443 / http=80 convention:
      # it only recognises a port when a ":" appears somewhere after the scheme and
      # otherwise appends ITS OWN default port after the URL's path
      # ("https://gw/insert/journald:19532/upload", answered with a 400). A
      # port-less endpoint is a valid URL (Alloy follows the standard), so this is a
      # warning that explains the quirk, never an error and never a rewrite.
      warnings =
        lib.optional (lib.match "[A-Za-z][A-Za-z0-9+.-]*://[^:]*" journaldWriteEndpoint != null)
          ''
            services.victoriaCollector: the endpoint logs are shipped to (${journaldWriteEndpoint})
            has no explicit port. systemd-journal-upload does not follow the usual
            https = 443 / http = 80 convention: without a ":" in the URL it falls back to
            its own default port (19532), so write the port out even when it is the
            standard one (e.g. "https://host:443"). Alloy is unaffected; to give only the
            log uploader a port, set services.victoriaCollector.journaldWriteEndpoint.
          '';

      # nixpkgs' journald-upload module sets no restart trigger, so changing only
      # the endpoint or the CA rewrote /etc/systemd/journal-upload.conf and left the
      # running uploader on the old URL until reboot.
      systemd.services.systemd-journal-upload.restartTriggers = [
        config.environment.etc."systemd/journal-upload.conf".source
      ];

      services.journald.upload = {
        enable = true;
        settings.Upload = {
          URL = "${journaldWriteEndpoint}/insert/journald";
        }
        // lib.optionalAttrs (lib.hasPrefix "https" journaldWriteEndpoint) {
          # "-" disables client-certificate loading; without it the uploader
          # refuses https:// URLs it has no client cert for. The gateway never
          # asks for one.
          ServerKeyFile = "-";
          ServerCertificateFile = "-";
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
