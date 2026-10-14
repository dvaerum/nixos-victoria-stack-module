# How a configured listen address is DIALLED, and when two of them cannot both
# be bound. One definition for every consumer (storage services, vmauth, MCP,
# nginx, Grafana, assertions).
#
# A wildcard address (`:port`, `0.0.0.0:port`, `[::]:port`) is a legitimate
# -httpListenAddr but not something to connect to: probing the wildcard address
# as a destination is unreliable across kernels, so callers dial loopback.
#
# The VictoriaMetrics binaries bind IPv4 only unless started with -enableTCP6
# (an IPv6 -httpListenAddr is otherwise a fatal startup error); `tcp6Flags`
# below is the one place that adds it.
{ lib }:
rec {
  split =
    addr:
    let
      m = lib.match "(.*):([0-9]+)" addr;
    in
    if m == null then
      null
    else
      {
        host = builtins.elemAt m 0;
        port = builtins.elemAt m 1;
      };

  # `[::0]` is how nginx's own IPv6 default is spelled.
  isIpv6Wildcard = host: host == "[::]" || host == "[::0]";

  isWildcardHost = host: host == "" || host == "0.0.0.0" || isIpv6Wildcard host;

  isWildcard =
    addr:
    let
      sp = split addr;
    in
    sp != null && isWildcardHost sp.host;

  # The host part to connect to: loopback for any wildcard (a bare `::` is the
  # IPv6 wildcard as Grafana spells it), a bare IPv6 literal bracketed.
  connectHost =
    host:
    if isWildcardHost host || host == "::" then
      "127.0.0.1"
    else if lib.hasInfix ":" host && !(lib.hasPrefix "[" host) then
      "[${host}]"
    else
      host;

  # `host:port` to connect to. Anything that is not host:port (a unix: socket)
  # is left alone.
  connectAddr =
    addr:
    let
      sp = split addr;
    in
    if sp == null then addr else "${connectHost sp.host}:${sp.port}";

  # `ip:port` to LISTEN on, bracketing a bare IPv6 literal exactly once.
  hostPort =
    ip: port:
    if lib.hasInfix ":" ip && !(lib.hasPrefix "[" ip) then
      "[${ip}]:${toString port}"
    else
      "${ip}:${toString port}";

  # Is this listen value (`host:port`, or a bare host) IPv6? An IPv4 address
  # or a hostname never contains `:`, a bare IPv6 literal has at least two, a
  # bracketed one has `[`. `:port` (wildcard host) is NOT IPv6.
  isIpv6Addr = addr: lib.hasInfix "[" addr || lib.length (lib.splitString ":" addr) > 2;

  # `-enableTCP6` for a unit whose listen values include an IPv6 one, unless
  # the operator already passes it in extraFlags (their value then stands; a
  # second copy would only repeat it).
  tcp6Flags =
    {
      addrs,
      extraFlags ? [ ],
    }:
    lib.optional (
      lib.any isIpv6Addr addrs
      && !lib.any (f: lib.hasPrefix "-enableTCP6" f || lib.hasPrefix "--enableTCP6" f) extraFlags
    ) "-enableTCP6";

  # Does the wildcard host `wild` also accept a connection addressed to `other`?
  # `0.0.0.0` only covers IPv4 addresses. `:port` and `[::]` are modelled as
  # covering everything, which is exact only with -enableTCP6 (`[::]` is then
  # dual-stack; without it `:port` binds IPv4 only), so collisions are never
  # under-reported.
  covers =
    wild: other: wild == "" || isIpv6Wildcard wild || (wild == "0.0.0.0" && !(lib.hasPrefix "[" other));

  # `localhost` resolves to 127.0.0.1 and/or ::1, so it clashes with any
  # loopback address, not just a byte-identical string.
  isLoopbackAddress = host: host == "[::1]" || lib.hasPrefix "127." host;

  sameHost =
    a: b:
    a == b || (a == "localhost" && isLoopbackAddress b) || (b == "localhost" && isLoopbackAddress a);

  # Can two listen addresses NOT both be bound?
  overlaps =
    a: b:
    let
      sa = split a;
      sb = split b;
    in
    sa != null
    && sb != null
    && sa.port == sb.port
    && (
      sameHost sa.host sb.host
      || (isWildcardHost sa.host && covers sa.host sb.host)
      || (isWildcardHost sb.host && covers sb.host sa.host)
    );

  # `overlaps` for listeners of a stated protocol: a udp and a tcp socket may
  # share an address and port (syslog on 514, or udp on an HTTP port's number).
  overlapsProto =
    protoA: a: protoB: b:
    protoA == protoB && overlaps a b;

  # A bare host (no port) that only this machine can reach, as the user wrote it
  # in an `ipAddress` option: `::1` with or without brackets, 127.x, localhost.
  isLoopbackHost = host: isLoopbackAddress host || host == "::1" || host == "localhost";
}
