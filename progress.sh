#!/bin/bash
set -euo pipefail

# Show recent commits on agent-work and the swarm's containers.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Show recent commits on agent-work and the swarm's containers.
Clones the bare repo to a temp directory, displays the last
15 commits on agent-work, and lists the containers with their state.
HELP
    exit 0
fi

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(swarm_project_resolve "$REPO_ROOT")" || exit 1
RUNTIME_DIR="$(swarm_runtime_dir "$PROJECT")" || exit 1
BARE_REPO="${RUNTIME_DIR}/upstream.git"

if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found. Are agents running?" >&2
    exit 1
fi
swarm_runtime_check "$RUNTIME_DIR" || exit 1
swarm_runtime_owner_check "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || exit 1
# Containers are read only when the Docker daemon answers; the commit
# history needs only git.
DOCKER_UP=false
if docker info >/dev/null 2>&1; then
    DOCKER_UP=true
    swarm_containers_verify "$PROJECT" "$REPO_ROOT" || exit 1
fi

CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
git clone --quiet "$BARE_REPO" "$CHECK_DIR"
cd "$CHECK_DIR"
git checkout --quiet agent-work

echo "=== Recent commits ==="
git log --oneline -15

echo ""
echo "=== Status ==="
if [ "$DOCKER_UP" = true ] \
        && own=$(swarm_own_containers "$PROJECT" "$REPO_ROOT" \
            2>/dev/null); then
    printf '%s\n' "$own" | while read -r name id; do
        [ -n "$name" ] || continue
        docker container inspect -f "${name}: {{.State.Status}}" \
            "$id" 2>/dev/null || true
    done
else
    echo "(docker not available)"
fi
