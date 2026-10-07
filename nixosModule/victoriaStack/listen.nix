# How a configured listen address is DIALLED, and when two of them cannot both
# be bound. One definition for every consumer (storage services, vmauth, MCP,
# nginx, assertions); it replaces three copies of the same wildcard logic, only
# one of which ever reached the URLs the module builds.
#
# A wildcard address (`:port`, `0.0.0.0:port`, `[::]:port`) is a legitimate
# -httpListenAddr but not something to connect to: probing the wildcard address
# as a destination is unreliable across kernels, so callers dial loopback.
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

  isWildcardHost = host: host == "" || host == "0.0.0.0" || host == "[::]";

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

  # Does the wildcard host `wild` also accept a connection addressed to `other`?
  # `:port` and `[::]` are dual-stack; `0.0.0.0` only covers IPv4 addresses.
  covers =
    wild: other: wild == "" || wild == "[::]" || (wild == "0.0.0.0" && !(lib.hasPrefix "[" other));

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
      sa.host == sb.host
      || (isWildcardHost sa.host && covers sa.host sb.host)
      || (isWildcardHost sb.host && covers sb.host sa.host)
    );
}
