{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.victoriaCollector;
  common = import ./common.nix { inherit lib; };
  restartBackoff = import ../restart-backoff.nix;
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
  queueFloorBytes = 4194304;

  # The directory itself is alloy's StateDirectory, so it is inside too; the
  # trailing slash on the prefix keeps look-alikes such as /var/lib/alloyx out.
  alloyStateDir = "/var/lib/alloy";
  queueOutsideStateDir =
    let
      dir = toString cfg.queue.directory;
    in
    !(dir == alloyStateDir || lib.hasPrefix "${alloyStateDir}/" dir);

  # Validates the token credential and sets $token; shared by the uploader's render
  # oneshot and Alloy's pre-start check below.
  readWriteToken = builtins.readFile ./read-write-token.sh;

  renderJournalUploadTokenHeader = pkgs.writeShellApplication {
    name = "victoria-collector-journal-upload-token-header";
    text = readWriteToken + ''
      # The directory keeps the default 755: the uploader's DynamicUser reaches the
      # file through the systemd-journal group and must be able to traverse it.
      mkdir -p /run/systemd/journal-upload.conf.d
      # The file holds the write token: never world-readable, not even before the
      # chgrp/chmod below (this runs under the default umask 022).
      umask 027
      conf=/run/systemd/journal-upload.conf.d/50-write-token.conf
      {
        echo "[Upload]"
        echo "Header=Authorization: Bearer $token"
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

  # Alloy reads the credential itself; this only refuses a file it could not use
  # as a bearer token, before Alloy starts.
  checkAlloyWriteToken = pkgs.writeShellApplication {
    name = "victoria-collector-alloy-write-token-check";
    text = readWriteToken + "unset token\n";
  };

  startUploaderIfTokenFailed = pkgs.writeShellApplication {
    name = "victoria-collector-start-uploader-if-token-failed";
    runtimeInputs = [ config.systemd.package ];
    text = builtins.readFile ./start-uploader-if-token-failed.sh;
  };

  hasToken = cfg.writeTokenFile != null;
  # Units that read the token at start: the path units below start and restart them.
  tokenConsumers =
    lib.optional needsAlloyOtlp "alloy.service"
    ++ lib.optional cfg.logs.enable "systemd-journal-upload.service";
  # What a changed file has to restart: the uploader gets the token through its
  # render oneshot, whose restart carries over to it (Requires=).
  tokenRestartUnits =
    lib.optional needsAlloyOtlp "alloy.service"
    ++ lib.optional cfg.logs.enable "victoria-collector-journal-upload-token.service";
  systemctl = "${config.systemd.package}/bin/systemctl";
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
        lib.optional (cfg.queue.maxSizeBytes < queueFloorBytes) ''
          services.victoriaCollector.queue.maxSizeBytes (${toString cfg.queue.maxSizeBytes})
          is below ${toString queueFloorBytes} bytes. The cap applies to each exporter and must
          hold at least one batch (a metrics batch measured 0.32-0.51 MB on a
          minimal host and grows with it): below that, Alloy rejects every
          export ("sending queue is full") and nothing reaches the gateway.
          Raise it, or ignore this warning once you have checked that data
          arrives.
        ''
        ++
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

      # nixpkgs' alloy unit has Restart=always, RestartSec=2: a start that fails for
      # the missing credential would repeat every ~2.3 s for as long as the file is
      # absent (five starts take longer than the 10 s rate-limit window, so it never
      # trips). A condition skips the start cleanly instead; the path unit below
      # starts Alloy once the file exists.
      systemd.services.alloy.unitConfig = lib.mkIf hasToken {
        ConditionPathExists = cfg.writeTokenFile;
      };

      # DynamicUser=yes implies this sandbox; DynamicUser=false drops it, so a
      # static user gets it spelled out. ReadWritePaths (below) keeps the queue
      # directory writable under ProtectSystem=strict.
      systemd.services.alloy.serviceConfig = lib.mkMerge [
        {
          # On top of nixpkgs' own RestartSec=2, which stays the first delay.
          inherit (restartBackoff) RestartSteps RestartMaxDelaySec;
          # The CA bundle and the write token reach Alloy's user as systemd
          # credentials (config.alloy.nix reads both from the credentials
          # directory), so the files' owner and mode don't matter -- same rule as
          # every other TLS/secret file here.
          LoadCredential =
            lib.optional (cfg.alloy.tlsCaFile != null) "tls-ca:${toString cfg.alloy.tlsCaFile}"
            ++ lib.optional hasToken "write-token:${cfg.writeTokenFile}";
          ExecStartPre = lib.optional hasToken (lib.getExe checkAlloyWriteToken);
          # DynamicUser implies ProtectSystem=strict, which blocks writes anywhere
          # not allow-listed via StateDirectory=/ReadWritePaths=; the default
          # queue.directory sits inside alloy's own StateDirectory, anything
          # outside needs an explicit entry or it fails silently at Alloy's own
          # runtime.
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

      # A dedicated root oneshot, not systemd-journal-upload.service's own
      # preStart: that unit runs hardened/DynamicUser with no write access to
      # /run/systemd (docs/decisions/0012). The uploader cannot take the
      # credential itself: Header= is read only from its config files (systemd
      # 261 man page; the binary has no credential support).
      systemd.services.victoria-collector-journal-upload-token = lib.mkIf (cfg.writeTokenFile != null) {
        description = "Render systemd-journal-upload's write-token Header= drop-in";
        before = [ "systemd-journal-upload.service" ];
        wantedBy = [ "systemd-journal-upload.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "write-token:${cfg.writeTokenFile}" ];
          ExecStart = lib.getExe renderJournalUploadTokenHeader;
          # RemainAfterExit keeps the unit "active" after the script ends, so
          # without this the drop-in outlives the unit until reboot.
          ExecStop = "${lib.getExe' pkgs.coreutils "rm"} -f /run/systemd/journal-upload.conf.d/50-write-token.conf";
          # chgrp to systemd-journal: root is not a member of that group.
          CapabilityBoundingSet = [ "CAP_CHOWN" ];

          # Stays root: /run/systemd is root:root 755, so creating a
          # subdirectory under it requires root. Lighter hardening pass than the
          # long-running services (docs/decisions/0015).
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
        };
      };

      # A drop-in config directory under /run/systemd/<unit>.conf.d/ with nothing
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

      # A collector on an intermittent network has no ordering fix: the
      # default start-limit ceiling would eventually stop the uploader for
      # good and need `systemctl reset-failed`. 0 disables the ceiling.
      systemd.services.systemd-journal-upload.startLimitIntervalSec = 0;
    })

    # The consumers read a copy of the token file at start (LoadCredential=), so
    # a file that appears late or changes has to be acted on by someone else:
    # path units, event-driven (docs/decisions/0006).
    (lib.mkIf (hasToken && tokenConsumers != [ ]) {
      # The log uploader's start with a missing credential fails and is never
      # retried. The helper is RemainAfterExit: while it stays active the path
      # unit does not trigger it again, so an operator's deliberate `systemctl
      # stop` is not undone by a later change to the file.
      systemd.services.victoria-collector-write-token-appeared = {
        description = "Start the collector units once the write-token file exists";
        # switch-to-configuration would otherwise re-run it when its unit file changes, starting consumers the operator stopped.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${systemctl} start --no-block ${lib.concatStringsSep " " tokenConsumers}";
          CapabilityBoundingSet = "";
        };
      };
      systemd.paths.victoria-collector-write-token-appeared = {
        description = "Wait for the write-token file";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathExists = cfg.writeTokenFile;
          Unit = "victoria-collector-write-token-appeared.service";
        };
      };

      # try-restart: a unit stopped on purpose stays stopped. --no-block: the path
      # unit only re-arms once this helper finishes, so waiting for the restart
      # would lose a file replaced meanwhile (same as the storage units' watchers).
      # The second ExecStart heals an uploader left dead by an unusable first file.
      systemd.services.victoria-collector-write-token-restart = {
        description = "Restart the collector units after the write-token file changed";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = [
            "${systemctl} try-restart --no-block ${lib.concatStringsSep " " tokenRestartUnits}"
          ]
          ++ lib.optional cfg.logs.enable (lib.getExe startUploaderIfTokenFailed);
          CapabilityBoundingSet = "";
        };
      };
      systemd.paths.victoria-collector-write-token-watch = {
        description = "Watch the write-token file for replacement";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = cfg.writeTokenFile;
          Unit = "victoria-collector-write-token-restart.service";
        };
      };
    })
  ];
}
