# 0018: Weekly update automation runs as one workflow, two serialized
jobs

## Decision

`update-flake.yml` and `update-mcp-packages.yml` are merged into a single
workflow with two jobs, the second declaring `needs: update-flake` —
replacing two separately-scheduled workflows (an hour apart) that each
pushed directly to `master` with no rebase.

`update-docs.yml`'s missing `permissions: contents: write` block (its two
push-capable siblings both declare it; this one didn't) is fixed in the
same pass.

## Why

Two independently-scheduled workflows, each running a real
`nix flake check -L` (container/VM builds that can easily exceed an
hour), each pushing directly to `master` with no rebase, can race: if the
first is still running past the second's start time, the second's push
can land on a ref the first's own push is about to invalidate. A fixed
time gap (the original "an hour apart" choice) only reduces the
likelihood, it doesn't eliminate the race — build time is variable and
can exceed any fixed gap, especially on a cold CI cache.

`needs:` between two jobs in one workflow is a structural guarantee from
GitHub Actions itself, not a timing assumption — it stays correct
regardless of how long either job's build takes. This was chosen over
restructuring to PR-based automation (the alternative considered): it
keeps today's direct-push model intact while still fully eliminating the
race, with a much smaller change to the existing workflow files.
</content>
