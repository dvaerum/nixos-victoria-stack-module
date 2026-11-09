#!/usr/bin/env bash
# Make a failed weekly bump visible (docs/decisions/0035): open an issue, or
# comment on the one that is already open, with the run's URL.
# Env: GH_TOKEN, GH_REPO  as `gh` expects
#      RUN_URL            URL of the failed workflow run
set -euo pipefail

title="Weekly dependency bump failed"
body="The scheduled dependency bump failed: ${RUN_URL:?}"

# Exact-title match on top of the search, which is fuzzy.
existing=$(gh issue list --state open --search "\"$title\" in:title" \
  --json number,title --jq "map(select(.title == \"$title\")) | .[0].number // empty")

if [ -n "$existing" ]; then
  gh issue comment "$existing" --body "$body"
else
  gh issue create --title "$title" --body "$body"
fi
