# Route helpers of the vmauth render script (vmauth.nix). Data only: the
# prefixes, the tenant table and the url_map come in as arguments.

# Whether a path lies under one of the prefixes, at a path boundary
# (`/metricsX` is not under `/metrics`).
def under($pfx):
  . as $p
  | any($pfx[]; . as $pre
      | ($p | startswith($pre))
      and (($p[($pre | length):]) | (. == "" or (.[0:1] | test("[A-Za-z0-9_-]") | not))));

# Keeps, per route, only the src_paths satisfying f; a route left without any is dropped.
def keep_paths(f):
  map(.src_paths |= ((. // []) | map(select(f))) | select((.src_paths | length) > 0));

def add_headers($h):
  .headers = ((.headers // []) + $h);

# Applies f to the part of every route whose src_paths lie under $pfx and
# leaves the rest of the route alone. A route without src_paths cannot be
# attributed to a backend and is left alone as well.
def on_paths_under($pfx; f):
  map(
    (.src_paths // []) as $sp
    | ($sp | map(select(under($pfx)))) as $in
    | if ($in | length) == 0 then [.]
      else
        (($sp - $in) as $out | if ($out | length) > 0 then [.src_paths = $out] else [] end)
        + [(.src_paths = $in) | f]
      end)
  | add // [];

# The routes of ONE tenant the client cannot change: vmauth overrides a
# client-sent header with these.
def stamp($account; $project):
  map(add_headers(["AccountID: \($account)", "ProjectID: \($project)"]));

# One copy of the routes per tenant. The client's AccountID selects the copy
# (src_headers matches ANY value of the header, so the account is stamped too:
# a second AccountID header would otherwise reach the backend), the project is
# forced.
def per_tenant($table; $names):
  . as $routes
  | [$names[] as $nm
     | $table[$nm] as $t
     | $routes
     | map(.src_headers = ((.src_headers // []) + ["AccountID: \($t.accountId)"]))
     | stamp($t.accountId; $t.projectId)
     | .[]];
