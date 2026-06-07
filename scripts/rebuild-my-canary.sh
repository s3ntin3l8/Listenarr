#!/usr/bin/env bash
# FORK-INTERNAL — lives on the fork-ci branch of s3ntin3l8/Listenarr.
#
# Rebuilds the disposable integration branch `my-canary` from scratch:
#   upstream/canary + merge of every branch in PATCH_BRANCHES.
# Pushing it triggers .github/workflows/my-canary-image.yml, which publishes
# ghcr.io/s3ntin3l8/listenarr:my-canary for unraid to pull.
#
# Workflow:
#   new fix      -> branch off upstream/canary -> PR upstream -> add branch here -> run this script
#   PR merged    -> remove branch from PATCH_BRANCHES -> run this script
#   upstream moved -> just run this script
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

main() {
    # Patch branches merged on top of upstream/canary. fork-ci must stay first
    # (it carries the CI workflow that builds the image).
    PATCH_BRANCHES=(
        fork-ci
        571-implicit-naming-patterns
        655-trust-cgnat-private-ip-gate
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
        echo "==> Merging ${branch}..."
        if ! git merge --no-edit "$branch"; then
            # rerere (autoupdate) may have already resolved and staged
            # everything from a previous manual resolution — finish the merge.
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
