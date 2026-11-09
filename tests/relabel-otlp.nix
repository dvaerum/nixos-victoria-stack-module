{ pkgs, nixosModule }:

# `-relabelConfig` through metrics.insert.extraFlags applies to the OTLP path:
# the resource attributes service.instance.id / service.name arrive as labels
# of exactly those (dotted) names and the rules map them onto instance / job.
# `relabelled` has the flag, `plain` is the same stack without it (the control:
# the labels must not exist there). The rules are the ones the single-node
# server this module replaced ran in production.
let
  module = nixosModule.nixosModules.victoriaStack;
  testLib = import ./lib.nix { inherit pkgs nixosModule; };
  inherit (testLib) otlpMetricGenerator;

  # The `(.+)` guard keeps a series that has no such attribute (a scraped or
  # imported one) from having its own instance/job overwritten with "".
  relabelFile = (pkgs.formats.yaml { }).generate "relabel.yaml" [
    {
      source_labels = [ "service.instance.id" ];
      regex = "(.+)";
      target_label = "instance";
    }
    {
      source_labels = [ "service.name" ];
      regex = "(.+)";
      target_label = "job";
    }
  ];

  node = extraFlags: {
    imports = [
      module
      testLib.testStartupTimeouts
    ];
    services.victoriaStack = {
      metrics = {
        enable = true;
        insert.extraFlags = extraFlags;
      };
      vmauth = {
        adminPasswordFile = "${pkgs.writeText "admin-password" "admin-password-value\n"}";
        readTokensFile = "${pkgs.writeText "read-tokens.yaml" ''
          tokens:
            - token: relabel-read-token # gitleaks:allow
        ''}";
        requireAuthForWrites = false;
      };
    };
  };
in
{
  boot = pkgs.testers.nixosTest {
    name = "victoria-stack-relabel-otlp";
    containers = {
      relabelled = node [ "-relabelConfig=${relabelFile}" ];
      plain = node [ ];
    };
    testScript = ''
      import json
      import time
      ${testLib.waitActivePython}

      VMAUTH = "http://127.0.0.1:4204"
      READ = "-H 'Authorization: Bearer relabel-read-token'"
      PB = "-H 'Content-Type: application/x-protobuf'"
      start_all()
      for m in (relabelled, plain):
          for u in ["vmstorage", "vminsert", "vmselect", "vmauth"]:
              wait_active(m, f"{u}.service")
          m.wait_for_open_port(4204)

      def push_otlp(m, name):
          m.succeed(f"${otlpMetricGenerator}/bin/gen-otlp-metric {name} 1 host-a node > /tmp/m.bin")
          m.succeed(f"curl -sf -X POST {PB} --data-binary @/tmp/m.bin {VMAUTH}/opentelemetry/v1/metrics")

      def series(m, name):
          since = int(time.time()) - 600
          out = m.wait_until_succeeds(
              f"curl -sfg {READ} '{VMAUTH}/metrics/api/v1/export?match[]={name}&start={since}' | grep -q . && "
              f"curl -sfg {READ} '{VMAUTH}/metrics/api/v1/export?match[]={name}&start={since}'",
              timeout=120)
          return [json.loads(l)["metric"] for l in out.splitlines() if l.strip()]

      for m in (relabelled, plain):
          push_otlp(m, "relabel_probe")

      # The OTLP path keeps the dots in the label names and relabelling targets them.
      got = series(relabelled, "relabel_probe")
      assert len(got) == 1, got
      assert got[0]["instance"] == "host-a" and got[0]["job"] == "node", got
      # Additive: the original attributes stay.
      assert got[0]["service.instance.id"] == "host-a" and got[0]["service.name"] == "node", got

      # Control: without the flag neither label exists, only the dotted attributes.
      ctl = series(plain, "relabel_probe")
      assert len(ctl) == 1, ctl
      assert "instance" not in ctl[0] and "job" not in ctl[0], ctl
      assert ctl[0]["service.instance.id"] == "host-a" and ctl[0]["service.name"] == "node", ctl

      # A series without the attributes keeps its own instance/job (the regex guard).
      relabelled.succeed(
          "curl -sf -X POST --data-binary 'relabel_scraped{instance=\"keep-i\",job=\"keep-j\"} 1' "
          "http://127.0.0.1:4209/insert/0/prometheus/api/v1/import/prometheus")
      kept = series(relabelled, "relabel_scraped")
      assert kept[0]["instance"] == "keep-i" and kept[0]["job"] == "keep-j", kept

      # The flag coexists with the module's own flags and survives a restart.
      flags = relabelled.succeed("systemctl show -p ExecStart vminsert")
      assert "-relabelConfig=${relabelFile}" in flags and "-storageNode=" in flags, flags
      relabelled.succeed("systemctl restart vminsert")
      wait_active(relabelled, "vminsert.service")
      relabelled.wait_for_open_port(4209)
      push_otlp(relabelled, "relabel_probe_after_restart")
      after = series(relabelled, "relabel_probe_after_restart")
      assert after[0]["instance"] == "host-a" and after[0]["job"] == "node", after
    '';
  };
}
