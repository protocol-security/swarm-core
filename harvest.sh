#!/bin/bash
set -euo pipefail

# Fetch agent-work from the bare repo, merge into current branch.
# Usage: ./harvest.sh [--dry]

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(swarm_project_resolve "$REPO_ROOT")" || exit 1
RUNTIME_DIR="$(swarm_runtime_dir "$PROJECT")" || exit 1
BARE_REPO="${RUNTIME_DIR}/upstream.git"
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

The bare repo lives in the project's runtime directory, which
launch.sh creates when starting agents: SWARM_RUNTIME_DIR if set,
else \$XDG_STATE_HOME/swarm-core/<project> (by default
~/.local/state/swarm-core/<project>).
HELP
            exit 0
            ;;
        --dry)  DRY_RUN=true ;;
    esac
done

warn_dirty_interactive_containers() {
    [ "$DOCKER_UP" = true ] || return 0
    local name id state dirty tmpd tmpf branch

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Act on the ID of a container this checkout created.
        id=$(swarm_own_container_id "$name" "$CHECKOUT_PATH" "$PROJECT") \
            || exit 1
        [ -n "$id" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$id" \
            2>/dev/null || echo "")
        dirty=""
        if [ "$state" = "running" ]; then
            dirty=$(docker exec "$id" bash -lc \
                'cd /workspace && [ -n "$(git status --porcelain=v1)" ] && echo true || echo false' \
                2>/dev/null || true)
        else
            # docker cp gives the copy the source file's mode, so it
            # goes into a private directory.
            tmpd=$(mktemp -d)
            tmpf="${tmpd}/interactive_state"
            docker cp "${id}:/workspace/agent_logs/interactive_state" \
                "$tmpf" 2>/dev/null || true
            if [ -s "$tmpf" ]; then
                dirty=$(grep '^dirty=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
                branch=$(grep '^branch=' "$tmpf" \
                    | head -1 | cut -d= -f2- || true)
            fi
            rm -rf "$tmpd"
        fi
        if [ "$dirty" = "true" ]; then
            echo "WARNING: ${name} has uncommitted interactive work" >&2
            [ -n "${branch:-}" ] && echo "         branch: ${branch}" >&2
        fi
    done < <(swarm_interactive_container_names "$PROJECT" 2>/dev/null \
        | sort || true)
}

swarm_refuse_legacy_state "$(swarm_project_id "$(basename "$REPO_ROOT")")" \
    || exit 1
if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found." >&2
    exit 1
fi
swarm_runtime_check "$RUNTIME_DIR" || exit 1
swarm_runtime_owner_check "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || exit 1
swarm_engagement_env_check || exit 1
swarm_engagement_join "$RUNTIME_DIR/state.json" || exit 1
CHECKOUT_PATH="$(swarm_checkout_path "$REPO_ROOT")"
# Harvest looks into interactive containers only when Docker answers.
# Without Docker, or with its daemon down, it touches no container and
# skips this check; the merge itself needs only git.
DOCKER_UP=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_UP=true
    swarm_containers_verify "$PROJECT" "$REPO_ROOT" || exit 1
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
        echo "  $(swarm_bare_rm_command "$RUNTIME_DIR")" >&2
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

# Tag a restore point on the pre-merge HEAD so this harvest can be
# undone with `git reset --hard <tag>`.  The tag lives in refs/tags
# and never collides with the harvested branches in refs/heads, so
# it is safe alongside agent-work.  Skip if HEAD is already tagged.
if ! git tag --points-at HEAD | grep -q '^swarm-harvest-'; then
    harvest_tag="swarm-harvest-$(date +%Y-%m-%d-%H%M%S)"
    git tag "$harvest_tag"
    echo "Tagged restore point: ${harvest_tag}"
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
