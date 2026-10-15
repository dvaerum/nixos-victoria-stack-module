# Regenerates tests/durations.json, the timing hint scripts/gate.sh uses to start
# the slowest tests first. Input: one or more logs of a gate/flake-check run made
# with -L; the median of each test's "test script finished in" is kept.
#   nix run .#update-durations -- gate1.log gate2.log > tests/durations.json
# Keys are derivation names (the log prefix); a test missing from the file counts
# as 0 s in gate.sh, so a stale file only loses ordering, never a check.

[ $# -ge 1 ] || {
  echo "usage: update-durations LOG... > tests/durations.json" >&2
  exit 2
}

# A log without a single timing line is a wrong input, not an empty result:
# grep's exit status (1) stops the pipeline instead of writing "{}".
grep -ahE '^[^ >]+> test script finished in [0-9.]+s' "$@" |
  sed -E 's/^([^ >]+)> test script finished in ([0-9.]+)s.*/\1 \2/' |
  jq -Rn '
    [inputs | split(" ") | {name: .[0], s: (.[1] | tonumber)}]
    | group_by(.name)
    | map({key: .[0].name, value: (map(.s) | sort | .[length / 2 | floor] | round)})
    | sort_by(.key)
    | from_entries'
