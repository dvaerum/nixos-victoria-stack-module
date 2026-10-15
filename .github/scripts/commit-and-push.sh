#!/usr/bin/env bash
# Commit the given paths and push them to $PUSH_BRANCH (docs/decisions/0035).
# Usage: commit-and-push.sh <commit message> <path>...
# Env: PUSH_BRANCH  branch to push to (required)
#      DRY_RUN      "true": rebase and show the commit, skip the push
set -euo pipefail

message=$1
shift

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add -- "$@"
git commit -m "$message"

# A scratch PUSH_BRANCH does not exist until the first push to it.
remote_head=$(git ls-remote --heads origin "refs/heads/$PUSH_BRANCH")
if [ -n "$remote_head" ]; then
  git pull --rebase origin "$PUSH_BRANCH"
fi

if [ "${DRY_RUN:-}" = true ]; then
  echo "dry run: would push this commit to $PUSH_BRANCH"
  git show --stat --format=fuller HEAD
  exit 0
fi

git push origin "HEAD:refs/heads/$PUSH_BRANCH"
