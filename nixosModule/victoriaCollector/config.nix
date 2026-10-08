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

  # What systemd-journal-upload is given: it only recognises a lower-case
  # scheme (HTTPS://host became "https://HTTPS://host"). URL schemes are
  # case-insensitive, so lower-casing is not a change of meaning.
  journaldBaseUrl =
    let
      stripped = common.stripTrailingSlashes journaldWriteEndpoint;
      m = lib.match "([A-Za-z][A-Za-z0-9+.-]*)://(.*)" stripped;
    in
    if m == null then stripped else "${lib.toLower (builtins.elemAt m 0)}://${builtins.elemAt m 1}";
  journaldIsHttps = lib.hasPrefix "https://" journaldBaseUrl;

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
      # systemd-journal-upload.service runs as DynamicUser=yes with
      # SupplementaryGroups=systemd-journal: its per-boot UID can only read
      # this root-written file through that group (owner-only 600 failed with
      # "Permission denied"). Matches nixpkgs' journald-upload.nix comment on
      # ServerKeyFile.
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

      # No restartTriggers: nixpkgs' alloy module reloads via reloadTriggers; an
      # explicit one would turn every config change into a restart.

      # Same-host ordering: when victoriaStack is on this host, vmauth could
      # still be starting when alloy's first export fires. A no-op on a
      # collector-only host (systemd ignores an undefined After=/Wants=
      # target). Cross-host splits get nothing from this; see
      # startLimitIntervalSec below.
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
      # static user gets it spelled out. ReadWritePaths (below) keeps the queue
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
      # Requires=, not Wants=: only Requires= carries a restart of the oneshot
      # over to alloy, whose EnvironmentFile= is read at start. With Wants=, a
      # rotated token was rewritten to the env file but Alloy kept sending the
      # old one.
      systemd.services.alloy.requires = lib.mkIf (cfg.writeTokenFile != null) [
        "victoria-collector-alloy-write-token.service"
      ];

      systemd.services.victoria-collector-alloy-write-token = lib.mkIf (cfg.writeTokenFile != null) {
        description = "Render alloy's write-token EnvironmentFile=";
        before = [ "alloy.service" ];
        wantedBy = [ "alloy.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "write-token:${cfg.writeTokenFile}" ];
          ExecStart = lib.getExe renderAlloyWriteToken;
          CapabilityBoundingSet = "";

          # Own RuntimeDirectory, deliberately not alloy.service's StateDirectory
          # (two dynamic UIDs must not share one directory); see
          # renderAlloyWriteToken for why root is not needed.
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
          URL = "${journaldBaseUrl}/insert/journald";
        }
        // lib.optionalAttrs journaldIsHttps {
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
        lib.optional journaldIsHttps "trusted-ca:${toString cfg.trustedCertificateFile}";

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
          # chgrp to systemd-journal: root is not a member of that group.
          CapabilityBoundingSet = [ "CAP_CHOWN" ];

          # Stays root: /run/systemd is root:root 755, so creating a
          # subdirectory under it requires root (unlike the alloy write-token
          # oneshot above). Same lighter hardening pass as that unit.
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

      # Same-host ordering, same reasoning as alloy's above.
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
