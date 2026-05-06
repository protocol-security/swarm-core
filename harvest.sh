#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./harvest.sh [--dry]

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
REMOTE_NAME="_agent-harvest"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<HELP
Usage: $0 [--dry]

Fetch agent-work from the bare repo and merge into the current branch.

Options:
  --dry        Show what would be merged without actually merging.
  -h, --help   Show this help message.

The bare repo is expected at /tmp/<project>-upstream.git,
created by launch.sh when starting agents.
HELP
            exit 0
            ;;
        --dry)  DRY_RUN=true ;;
    esac
done

if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found." >&2
    exit 1
fi

cd "$REPO_ROOT"

git remote remove "$REMOTE_NAME" 2>/dev/null || true

echo "--- Fetching agent-work ---"
git remote add "$REMOTE_NAME" "$BARE_REPO"
git fetch --no-recurse-submodules "$REMOTE_NAME" agent-work

# Guard against stale-bare poisoning: agent-work must descend from HEAD,
# otherwise merging it would re-introduce ancestors not in HEAD's history
# (e.g. commits removed by an upstream force-push that the bare repo did
# not see).
if ! git merge-base --is-ancestor HEAD "$REMOTE_NAME/agent-work"; then
    echo "" >&2
    echo "ERROR: $REMOTE_NAME/agent-work does not descend from HEAD." >&2
    echo "  HEAD:       $(git rev-parse --short HEAD)" >&2
    echo "  agent-work: $(git rev-parse --short "$REMOTE_NAME/agent-work")" >&2
    echo "" >&2
    echo "The bare repo at ${BARE_REPO} holds a branch that diverged from" >&2
    echo "the current branch. This usually means upstream history was" >&2
    echo "rewritten (e.g. force-push) but the bare repo still has the old" >&2
    echo "ancestry. Merging would re-introduce removed commits." >&2
    echo "" >&2
    echo "Resolve by wiping and recreating the bare repo:" >&2
    echo "  rm -rf ${BARE_REPO}" >&2
    echo "  ./launch.sh ...   # recreates the bare from current HEAD" >&2
    git remote remove "$REMOTE_NAME"
    exit 1
fi

COMMIT_LOG=$(git log --oneline "$REMOTE_NAME/agent-work" ^HEAD)
NEW_COMMITS=$(echo "$COMMIT_LOG" | grep -c . || true)
echo ""
echo "${NEW_COMMITS} new commits on agent-work:"
echo "$COMMIT_LOG" | head -20 || true
if [ "$NEW_COMMITS" -gt 20 ]; then
    echo "  ... and $((NEW_COMMITS - 20)) more"
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(dry run -- not merging)"
    git remote remove "$REMOTE_NAME"
    exit 0
fi

if [ "$NEW_COMMITS" -eq 0 ]; then
    echo ""
    echo "Nothing new to merge."
    git remote remove "$REMOTE_NAME"
    exit 0
fi

echo ""
echo "--- Merging agent-work ---"
git merge "$REMOTE_NAME/agent-work" --no-edit

git remote remove "$REMOTE_NAME"

echo ""
echo "--- Done ---"
echo "Agent results merged into $(git branch --show-current)."
echo "Review with: git log --oneline -20"
