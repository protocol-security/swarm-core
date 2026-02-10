#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./harvest.sh [--dry] [--strip-coauthor]

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
REMOTE_NAME="_agent-harvest"
DRY_RUN=false
STRIP_COAUTHOR=false

for arg in "$@"; do
    case "$arg" in
        --dry)             DRY_RUN=true ;;
        --strip-coauthor)  STRIP_COAUTHOR=true ;;
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

NEW_COMMITS=$(git log --oneline "$REMOTE_NAME/agent-work" ^HEAD | wc -l)
echo ""
echo "${NEW_COMMITS} new commits on agent-work:"
git log --oneline "$REMOTE_NAME/agent-work" ^HEAD | head -20
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

if [ "$STRIP_COAUTHOR" = true ]; then
    MERGE_BASE=$(git merge-base HEAD "$REMOTE_NAME/agent-work" 2>/dev/null || true)
    if [ -n "$MERGE_BASE" ]; then
        echo ""
        echo "--- Stripping Co-Authored-By from agent commits ---"
        git rebase "$MERGE_BASE" --rebase-merges \
            --exec 'git commit --amend --no-edit --reset-author \
            -m "$(git log -1 --pretty=%B | grep -v "^Co-Authored-By:")"'
    fi
fi

git remote remove "$REMOTE_NAME"

echo ""
echo "--- Done ---"
echo "Agent results merged into $(git branch --show-current)."
echo "Review with: git log --oneline -20"
