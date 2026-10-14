include "tenant-routes";

# Turns one tier's (already validated) token list into vmauth users and
# warnings; called by append_token_users in vmauth.nix, which explains the
# per-backend scoping and the warn-don't-break rule (docs/decisions/0030).
#
# Inputs: --slurpfile tokens, urlmap (the tier's url_map), prefixes (backend
# name -> its path prefixes), tenants (name -> {accountId, projectId}),
# tenantprefixes (per tier: logs/traces -> the data prefixes a tenant applies
# to; metrics.<tier> -> the metrics prefixes, bound by path); environment: label (the option name) and tier ("read" | "write").
#
# Tenants: `tenant: x` stamps x on every logs and traces route of the entry
# and retargets its metrics routes to x's path; `tenants: [..]`/`all` (read
# tier) emits those routes once per tenant, picked by the client's AccountID.
# MCP routes are never given to a
# tenant token (the MCP servers cannot bound tenants). Metrics routes are
# retargeted to the tenant's `/select/<id>/prometheus/` or `/insert/<id>/`.
# Without a tenant key and with tenants declared, the logs and
# traces routes are stamped 0:0, so a client header cannot reach another
# tenant. With no tenant declared nothing differs from a render without tenants.
$ENV.label as $label
| $ENV.tier as $tier
| ($prefixes[0] | keys) as $known
| $tenants[0] as $table
| ($table | keys) as $declared
| (($table | length) > 0) as $tenanted
| ($tenantprefixes[0][$tier] | [.[][]]) as $header_pfx
| $tenantprefixes[0].metrics[$tier] as $metrics_pfx
| ($header_pfx + $metrics_pfx) as $tenant_pfx
| ($tokens[0] | to_entries | map(
    (.key + 1) as $n
    | .value as $t
    | ($t.token // "") as $tok
    | ($tok | test("^\\s*$")) as $blank
    | ($t | has("backends")) as $scoped
    | (($t.backends // []) | unique) as $req
    | ($req - $known) as $unknown
    | ($req - $unknown) as $valid
    | (if $scoped then
         (if ($valid | length) == 0 then []
          else ($valid | map($prefixes[0][.]) | add) as $pfx
            | $urlmap[0]
            | keep_paths((contains("|") | not) and under($pfx))
          end)
       else $urlmap[0] end) as $um

    # ---- tenants ----
    | (if ($t | has("tenant")) then "single"
       elif ($t | has("tenants")) then (if $t.tenants == "all" then "all" else "list" end)
       else "none" end) as $mode
    | ($mode == "list" or $mode == "all") as $multi
    | ($multi and $tier == "write") as $misuse
    | (if $mode == "single" then [$t.tenant]
       elif $mode == "list" then ($t.tenants | reduce .[] as $x ([]; if index([$x]) != null then . else . + [$x] end))
       elif $mode == "all" then $declared
       else [] end) as $names
    | ($names | map(select(in($table) | not))) as $undeclared
    | ($names | map(select(in($table)))) as $known_names
    # Two tenants of one account cannot both be picked by an AccountID header.
    | (reduce $known_names[] as $nm ({kept: [], seen: {}, dups: []};
         ($table[$nm].accountId | tostring) as $a
         | if .seen[$a] != null then .dups += [{dropped: $nm, kept: .seen[$a]}]
           else .kept += [$nm] | .seen[$a] = $nm end)) as $dd
    | (if $mode == "none" or $misuse then []
       elif $mode == "single" then $known_names
       else $dd.kept end) as $tn
    | (if $mode == "none" then
         (if $tenanted then $um | on_paths_under($header_pfx; add_headers(["AccountID: 0", "ProjectID: 0"]))
          else $um end)
       elif ($tn | length) == 0 then []
       else
         ($um | keep_paths((contains("|") | not) and under($tenant_pfx))) as $r
         | if $mode == "single" then $r | stamp($table[$tn[0]]; $metrics_pfx)
           else $r | per_tenant($table; $tn; $metrics_pfx) end
       end) as $routes
    | (if $misuse then null
       elif $mode == "none" or ($tn | length) > 0 then null
       elif $mode == "all" and ($declared | length) == 0 then "has `tenants: all`, but no tenant is declared (services.victoriaStack.tenants)"
       elif $mode == "list" and ($names | length) == 0 then "has an empty `tenants` list"
       else "has no declared tenant" end) as $no_tenant
    | {
        user: (if ($blank | not) and ($routes | length) > 0 then {bearer_token: $tok, url_map: $routes} else null end),
        warnings: (
          if $blank then ["\($label) entry #\($n) has an empty or whitespace-only token -- skipped"]
          else
            (if ($unknown | length) > 0
             then ["\($label) entry #\($n) names unknown backend(s): \($unknown | join(", ")) -- ignored (valid names: \($known | join(", ")))"]
             else [] end)
            + (if $misuse
               then ["\($label) entry #\($n) has a `tenants` key, which only a read token may carry (a write token takes exactly one `tenant`) -- the token gets no access and is left out of the configuration"]
               else [] end)
            + (if ($undeclared | length) > 0 and $mode != "none" and ($misuse | not)
               then ["\($label) entry #\($n) names undeclared tenant(s): \($undeclared | join(", ")) -- ignored (\(if ($declared | length) == 0 then "no tenant is declared" else "declared: \($declared | join(", "))" end))"]
               else [] end)
            + (if $misuse then []
               else $dd.dups | map("\($label) entry #\($n): tenants \"\(.dropped)\" and \"\(.kept)\" share accountId \($table[.kept].accountId); \"\(.dropped)\" is ignored (the client picks the tenant by the AccountID header alone)") end)
            + (if $no_tenant != null
               then ["\($label) entry #\($n) \($no_tenant) -- the token gets no access and is left out of the configuration"]
               else [] end)
            + (if $scoped and ($valid | length) == 0
               then ["\($label) entry #\($n) has no valid backend (an empty or all-unknown backends list) -- the token gets no access and is left out of the configuration"]
               elif ($um | length) == 0 and $scoped
               then ["\($label) entry #\($n) is scoped to [\($valid | join(", "))], none of which is enabled -- the token gets no access and is left out of the configuration"]
               elif ($um | length) == 0
               then ["\($label) entry #\($n) has no routes to grant -- the token gets no access and is left out of the configuration"]
               elif ($tn | length) > 0 and ($routes | length) == 0
               then ["\($label) entry #\($n) has no logs, traces or metrics route to grant -- the token gets no access and is left out of the configuration"]
               else [] end)
          end)
      })) as $entries
| {users: (. + [$entries[] | .user | select(. != null)]), warnings: [$entries[] | .warnings[]]}
