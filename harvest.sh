#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./harvest.sh [--dry]

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
git fetch "$REMOTE_NAME" agent-work

COMMIT_LOG=$(git log --oneline "$REMOTE_NAME/agent-work" ^HEAD)
NEW_COMMITS=$(echo "$COMMIT_LOG" | grep -c . || true)
echo ""
echo "${NEW_COMMITS} new commits on agent-work:"
echo "$COMMIT_LOG" | head -20
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
