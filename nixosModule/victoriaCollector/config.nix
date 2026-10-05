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
      chmod 600 "$conf"
    '';
  };

  # alloy.service's own preStart runs too late to populate an
  # EnvironmentFile=: systemd resolves EnvironmentFile= for every exec in
  # the unit -- including ExecStartPre= itself -- before that exec runs,
  # so a file only created by the unit's own preStart never exists yet.
  # Same trap ADR 0012 already avoids for journal-upload; fixed here the
  # same way, a dedicated oneshot ordered strictly before alloy.service.
  renderAlloyWriteToken = pkgs.writeShellApplication {
    name = "victoria-collector-alloy-write-token";
    text = ''
      mkdir -p /run/alloy
      env=/run/alloy/write-token.env
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
        environmentFile = lib.mkIf (cfg.writeTokenFile != null) "/run/alloy/write-token.env";
      };

      environment.etc."alloy/config.alloy".text = configAlloyText;

      # Without this, alloy.service just reads the stable /etc/alloy/
      # config.alloy path at runtime -- changing the file's CONTENT
      # doesn't change the unit file's own hash, so NixOS activation has
      # no reason to restart it.
      systemd.services.alloy.restartTriggers = [ configAlloyText ];

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
          TrustedCertificateFile = toString cfg.trustedCertificateFile;
        };
      };

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
        };
      };
    })
  ];
}
