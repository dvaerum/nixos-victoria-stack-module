# The systemd sandbox of the storage units (docs/decisions/0015), one definition
# for storage-common.nix and the metrics cluster's three units. Based on
# nixpkgs' own services.victoria* modules, but with ProtectSystem=strict and an
# empty capability set.
{
  # A syslog port below 1024 keeps CAP_NET_BIND_SERVICE (storage-common.nix).
  needsLowPort ? false,
}:
{
  DeviceAllow = [ "/dev/null rw" ];
  DevicePolicy = "strict";
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
  NoNewPrivileges = true;
  PrivateDevices = true;
  PrivateTmp = true;
  # Capabilities held inside a user namespace do not count for
  # binding a port in the host's network namespace.
  PrivateUsers = !needsLowPort;
  ProtectClock = true;
  ProtectControlGroups = true;
  ProtectHome = true;
  ProtectHostname = true;
  ProtectKernelLogs = true;
  ProtectKernelModules = true;
  ProtectKernelTunables = true;
  ProtectProc = "invisible";
  CapabilityBoundingSet = if needsLowPort then [ "CAP_NET_BIND_SERVICE" ] else "";
  ProtectSystem = "strict";
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
}
