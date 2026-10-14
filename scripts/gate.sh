# Parallel test gate. Run from the repository root through the flake app:
#   nix run .#gate -- --all
# See the "Running the tests" section of README.md and docs/decisions/0034-*.md.

usage() {
  cat >&2 <<'EOF'
usage: gate --all | --sections g1,g2 | --list-sections  [options]

  --all                 every check, evaluated in parallel (nix-eval-jobs), then
                        built with `nix build --keep-going`. Fails on ANY
                        evaluation error, ANY failed build, or zero checks.
  --sections g1,g2      only the named groups (a group = one tests/*.nix file).
                        NOT A GATE: for iterating while editing.
  --list-sections       print the group names

options:
  --workers N           evaluation workers (default min(nproc/2, 8))
  --max-memory-size MB  per-worker memory limit before it is recycled (default 6144)
  --max-jobs N          passed to `nix build` (0 = build only on remote builders)
  --remote HOST         ship the tree to HOST over ssh and run there
                        (default: $GATE_REMOTE; unset = run locally)
EOF
  exit 2
}

mode=
sections=
remote=${GATE_REMOTE:-}
max_mem=6144
max_jobs=
ref=
workers=

while [ $# -gt 0 ]; do
  case $1 in
  --all) mode=all ;;
  --sections)
    [ $# -ge 2 ] || usage
    mode=sections
    sections=$2
    shift
    ;;
  --list-sections) mode=list ;;
  --workers)
    [ $# -ge 2 ] || usage
    workers=$2
    shift
    ;;
  --max-memory-size)
    [ $# -ge 2 ] || usage
    max_mem=$2
    shift
    ;;
  --max-jobs)
    [ $# -ge 2 ] || usage
    max_jobs=$2
    shift
    ;;
  --remote)
    [ $# -ge 2 ] || usage
    remote=$2
    shift
    ;;
  # Set by the remote invocation: the shipped tree's store path.
  --flake)
    [ $# -ge 2 ] || usage
    ref=$2
    shift
    ;;
  *) usage ;;
  esac
  shift
done
[ -n "$mode" ] || usage
[ "$mode" != sections ] || [ -n "$sections" ] || usage

if [ -n "$remote" ]; then
  # Evaluation and builds then use the remote's memory and cores. The script
  # that runs there is this same flake app, taken from the shipped tree.
  src=$(nix flake archive --json --to "ssh-ng://$remote" "path:$PWD" | jq -er .path)
  # Workers default on the remote's own core count, so only an explicit one is forwarded.
  remote_args=(--flake "path:$src" --max-memory-size "$max_mem")
  [ -z "$workers" ] || remote_args+=(--workers "$workers")
  [ -z "$max_jobs" ] || remote_args+=(--max-jobs "$max_jobs")
  case $mode in
  all) remote_args+=(--all) ;;
  sections) remote_args+=(--sections "$sections") ;;
  list) remote_args+=(--list-sections) ;;
  esac
  # The remote's login shell re-splits the command line, so quote every word.
  printf -v cmd '%q ' nix run "path:$src#gate" -- "${remote_args[@]}"
  # shellcheck disable=SC2029 # $cmd is built locally on purpose
  exec ssh -o BatchMode=yes "$remote" "cd /tmp && $cmd"
fi

if [ -z "$workers" ]; then
  workers=$(($(nproc) / 2))
  [ "$workers" -le 8 ] || workers=8
  [ "$workers" -ge 1 ] || workers=1
fi
[ -n "$ref" ] || ref=path:$PWD
system=$(nix config show system)

group_names() {
  nix eval --json "$ref#testSections.$system" --apply builtins.attrNames | jq -r '.[]'
}

if [ "$mode" = list ]; then
  group_names
  exit 0
fi

# The number of checks the flake defines, from attribute names alone (no
# derivation is evaluated), so a check that evaluation silently skipped shows.
count_attrs() {
  nix eval --json "$1" --apply 'c: builtins.length (builtins.attrNames c)'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jobs_file=$tmp/jobs.jsonl

if [ "$mode" = all ]; then
  echo "gate: --all, $workers evaluation workers" >&2
  expected=$(count_attrs "$ref#checks.$system")
  eval_args=(--flake "$ref#checks.$system")
else
  echo "gate: NOT A GATE: only sections [$sections]; run --all before committing" >&2
  mapfile -t known < <(group_names)
  expected=0
  IFS=, read -r -a wanted <<<"$sections"
  for g in "${wanted[@]}"; do
    if [[ " ${known[*]} " != *" $g "* ]]; then
      echo "gate: unknown section '$g'; known: ${known[*]}" >&2
      exit 2
    fi
    expected=$((expected + $(count_attrs "$ref#testSections.$system.$g")))
  done
  # shellcheck disable=SC2016 # `${...}` below is Nix, not shell
  eval_args=(--impure --expr
    '{ ref, system, sections }:
     let
       s = (builtins.getFlake ref).testSections.${system};
     in
     builtins.listToAttrs (map (g: { name = g; value = s.${g}; }) (builtins.filter builtins.isString (builtins.split "," sections)))'
    --argstr ref "$ref" --argstr system "$system" --argstr sections "$sections")
fi

eval_failed=0
nix-eval-jobs "${eval_args[@]}" --workers "$workers" --max-memory-size "$max_mem" \
  --force-recurse >"$jobs_file" || eval_failed=1

eval_errors=$(jq -s '[.[] | select(has("error"))] | length' "$jobs_file")
mapfile -t drvs < <(jq -r 'select(has("error") | not) | .drvPath + "^*"' "$jobs_file")
mapfile -t outs < <(jq -r 'select(has("error") | not) | .outputs[]' "$jobs_file")
evaluated=${#drvs[@]}
echo "gate: evaluated $evaluated of $expected checks, $eval_errors evaluation errors" >&2
jq -r 'select(has("error")) | "gate: eval error in \(.attr): \(.error | split("\n") | .[0:3] | join(" "))"' "$jobs_file" | head -20 >&2

if [ "$eval_failed" -ne 0 ] || [ "$eval_errors" -ne 0 ] || [ "$evaluated" -eq 0 ] || [ "$evaluated" -ne "$expected" ]; then
  echo "gate: FAILED during evaluation (nix-eval-jobs failed: $eval_failed)" >&2
  exit 1
fi

build_args=(--no-link --keep-going -L --stdin)
[ -z "$max_jobs" ] || build_args+=(--max-jobs "$max_jobs")
build_failed=0
printf '%s\n' "${drvs[@]}" | nix build "${build_args[@]}" || build_failed=1

# `nix build` prints failures but not a count; what is still not in the store is what failed.
# The exit status only says "some path is invalid" and the paths are counted from stdout.
invalid=$(nix-store --check-validity --print-invalid "${outs[@]}" | wc -l || true)
built=$((evaluated - invalid))
echo "gate: evaluated $evaluated, built $built, failed $invalid" >&2

if [ "$build_failed" -ne 0 ] || [ "$invalid" -ne 0 ]; then
  echo "gate: FAILED" >&2
  exit 1
fi
if [ "$mode" = all ]; then
  echo "gate: GREEN (all $evaluated checks)" >&2
else
  echo "gate: sections [$sections] green ($evaluated checks); this is NOT the gate" >&2
fi
