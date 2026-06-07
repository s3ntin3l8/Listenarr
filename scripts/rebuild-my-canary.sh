#!/usr/bin/env bash
# FORK-INTERNAL — lives on the fork-ci branch of s3ntin3l8/Listenarr.
#
# Rebuilds the disposable integration branch `my-canary` from scratch:
#   upstream/canary + merge of every branch in PATCH_BRANCHES + every open
#   upstream PR in UPSTREAM_PRS.
# Pushing it triggers .github/workflows/my-canary-image.yml, which publishes
# ghcr.io/s3ntin3l8/listenarr:my-canary for unraid to pull.
#
# Workflow:
#   own fix          -> branch off upstream/canary -> PR upstream -> add to PATCH_BRANCHES -> run
#   someone's PR     -> add its number to UPSTREAM_PRS -> run (re-fetched fresh each time)
#   PR merged/closed -> remove from PATCH_BRANCHES / UPSTREAM_PRS -> run
#   upstream moved   -> just run this script
#
# RULES:
#   - NEVER open a PR from fork-ci or my-canary. Upstream PRs always come from
#     feature branches cut from upstream/canary, targeting Listenarrs/Listenarr:canary.
#   - Never commit directly to my-canary; it is recreated on every run.
#
# Run from anywhere inside the repo: scripts/rebuild-my-canary.sh
# (Entire body is wrapped in main() so the mid-run branch switch cannot
#  corrupt the running script.)

set -euo pipefail

# Merge a single local branch into the current branch, tolerating a conflict
# that rerere (autoupdate) has already resolved+staged, but failing loudly on a
# real (unresolved) conflict or a merge that can't even start (e.g. bad ref).
merge_branch() {
    local branch="$1"
    if ! git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null; then
        echo "" >&2
        echo "ERROR: branch '${branch}' does not exist locally." >&2
        echo "Fix the name in PATCH_BRANCHES (it may have been renamed), then re-run." >&2
        exit 1
    fi

    echo "==> Merging ${branch}..."
    if ! git merge --no-edit "$branch"; then
        # A real merge is in progress (MERGE_HEAD) but stopped. If rerere
        # (autoupdate) already resolved and staged every conflict from a
        # previous manual resolution, finish the merge; otherwise bail.
        if [ ! -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
            echo "" >&2
            echo "ERROR: merge of '${branch}' failed before it started (see git output above)." >&2
            exit 1
        fi
        if [ -z "$(git diff --name-only --diff-filter=U)" ]; then
            echo "==> Conflict auto-resolved by rerere; committing merge."
            git commit --no-edit
        else
            echo "" >&2
            echo "ERROR: merge of '${branch}' conflicted." >&2
            echo "Resolve the conflict and commit (git rerere will remember the" >&2
            echo "resolution for future rebuilds), then re-run this script —" >&2
            echo "or 'git merge --abort' to bail out." >&2
            exit 1
        fi
    fi
}

main() {
    # Patch branches merged on top of upstream/canary. fork-ci must stay first
    # (it carries the CI workflow that builds the image).
    PATCH_BRANCHES=(
        fork-ci
        571-implicit-naming-patterns
        655-explain-apikey-gate-ui
        508-storage-per-root-folder
    )

    # Open upstream PRs (by number) authored by anyone, folded in until they
    # merge/close. Re-fetched from refs/pull/<N>/head every run, so new commits
    # the PR author pushes are picked up automatically. Drop the number once the
    # PR lands (it then arrives via upstream/canary).
    UPSTREAM_PRS=(
        634   # bugfix/fix-nzbget-import (therobbiedavis) — Fix NZBGet import completion
    )

    cd "$(git rev-parse --show-toplevel)"

    # Remember merge-conflict resolutions (e.g. CHANGELOG entries from several
    # patch branches) and re-apply + stage them automatically on every rebuild.
    git config rerere.enabled true
    git config rerere.autoupdate true

    if [ -n "$(git status --porcelain)" ]; then
        echo "ERROR: working tree is not clean — commit or stash first." >&2
        exit 1
    fi

    local previous_branch
    previous_branch=$(git branch --show-current)

    echo "==> Fetching upstream..."
    git fetch upstream

    echo "==> Recreating my-canary from upstream/canary ($(git rev-parse --short upstream/canary))..."
    git checkout -B my-canary upstream/canary

    for branch in "${PATCH_BRANCHES[@]}"; do
        merge_branch "$branch"
    done

    for pr in "${UPSTREAM_PRS[@]}"; do
        echo "==> Fetching PR #${pr} (refs/pull/${pr}/head)..."
        git fetch -q upstream "pull/${pr}/head:pr-${pr}"
        merge_branch "pr-${pr}"
    done

    echo "==> Pushing my-canary to origin (triggers image build)..."
    git push --force-with-lease origin my-canary

    if [ -n "$previous_branch" ] && [ "$previous_branch" != "my-canary" ]; then
        echo "==> Returning to ${previous_branch}..."
        git checkout "$previous_branch"
    fi

    echo "==> Done. Watch the build: gh run watch -R s3ntin3l8/Listenarr"
}

main "$@"
