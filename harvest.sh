#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./harvest.sh [--dry]

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(swarm_project_id "$(basename "$REPO_ROOT")")"
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

warn_dirty_interactive_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    local image_name="${PROJECT}-agent"
    local name state dirty tmpf branch

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$name" \
            2>/dev/null || echo "")
        dirty=""
        if [ "$state" = "running" ]; then
            dirty=$(docker exec "$name" bash -lc \
                'cd /workspace && [ -n "$(git status --porcelain=v1)" ] && echo true || echo false' \
                2>/dev/null || true)
        else
            tmpf="/tmp/.swarm-harvest-${name}.state"
            docker cp "${name}:/workspace/agent_logs/interactive_state" \
                "$tmpf" 2>/dev/null || true
            if [ -s "$tmpf" ]; then
                dirty=$(grep '^dirty=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
                branch=$(grep '^branch=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
            fi
            rm -f "$tmpf"
        fi
        if [ "$dirty" = "true" ]; then
            echo "WARNING: ${name} has uncommitted interactive work" >&2
            [ -n "${branch:-}" ] && echo "         branch: ${branch}" >&2
        fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${image_name}-interactive-" \
        | sort || true)
}

if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found." >&2
    exit 1
fi

cd "$REPO_ROOT"
warn_dirty_interactive_containers

git remote remove "$REMOTE_NAME" 2>/dev/null || true

echo "--- Fetching agent work ---"
git remote add "$REMOTE_NAME" "$BARE_REPO"
git fetch --no-recurse-submodules "$REMOTE_NAME" \
    '+refs/heads/*:refs/remotes/_agent-harvest/*'

HARVEST_BRANCHES=(agent-work)
while IFS= read -r branch; do
    [ -n "$branch" ] && HARVEST_BRANCHES+=("$branch")
done < <(git -C "$BARE_REPO" for-each-ref \
    --format='%(refname:short)' refs/heads/swarm 2>/dev/null \
    | grep -E '/interactive-' || true)

# Guard against stale-bare poisoning: agent-work must descend from HEAD,
# otherwise merging it would re-introduce ancestors not in HEAD's history
# (e.g. commits removed by an upstream force-push that the bare repo did
# not see).
MERGE_BRANCHES=()
TOTAL_NEW_COMMITS=0
for branch in "${HARVEST_BRANCHES[@]}"; do
    remote_ref="$REMOTE_NAME/$branch"
    if ! git show-ref --verify --quiet "refs/remotes/${remote_ref}"; then
        continue
    fi

    if ! git merge-base --is-ancestor HEAD "$remote_ref"; then
        echo "" >&2
        echo "ERROR: ${remote_ref} does not descend from HEAD." >&2
        echo "  HEAD:       $(git rev-parse --short HEAD)" >&2
        echo "  ${branch}: $(git rev-parse --short "$remote_ref")" >&2
        echo "" >&2
        echo "The bare repo at ${BARE_REPO} holds a branch that" >&2
        echo "diverged from the current branch. This usually means" >&2
        echo "upstream history was rewritten (e.g. force-push) but" >&2
        echo "the bare repo still has the old ancestry. Merging" >&2
        echo "would re-introduce removed commits." >&2
        echo "" >&2
        echo "Resolve by wiping and recreating the bare repo:" >&2
        echo "  rm -rf ${BARE_REPO}" >&2
        echo "  ./launch.sh ...   # recreates the bare from current HEAD" >&2
        git remote remove "$REMOTE_NAME"
        exit 1
    fi

    COMMIT_LOG=$(git log --oneline "$remote_ref" ^HEAD)
    NEW_COMMITS=$(echo "$COMMIT_LOG" | grep -c . || true)
    MERGE_BRANCHES+=("${branch}|${NEW_COMMITS}")
    TOTAL_NEW_COMMITS=$((TOTAL_NEW_COMMITS + NEW_COMMITS))
    echo ""
    echo "${NEW_COMMITS} new commits on ${branch}:"
    echo "$COMMIT_LOG" | head -20 || true
    if [ "$NEW_COMMITS" -gt 20 ]; then
        echo "  ... and $((NEW_COMMITS - 20)) more"
    fi
done

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(dry run -- not merging)"
    git remote remove "$REMOTE_NAME"
    exit 0
fi

if [ "$TOTAL_NEW_COMMITS" -eq 0 ]; then
    echo ""
    echo "Nothing new to merge."
    git remote remove "$REMOTE_NAME"
    exit 0
fi

echo ""
for item in "${MERGE_BRANCHES[@]}"; do
    branch="${item%%|*}"
    new_commits="${item##*|}"
    [ "$new_commits" -eq 0 ] && continue
    echo "--- Merging ${branch} ---"
    git merge "$REMOTE_NAME/$branch" --no-edit
done

git remote remove "$REMOTE_NAME"

echo ""
echo "--- Done ---"
echo "Agent results merged into $(git branch --show-current)."
echo "Review with: git log --oneline -20"
