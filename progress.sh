#!/bin/bash
set -euo pipefail

# Show recent commits on agent-work and running containers.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Show recent commits on agent-work and running containers.
Clones the bare repo to a temp directory, displays the last
15 commits on agent-work, and lists running containers.
HELP
    exit 0
fi

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git docker
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(swarm_project_id "$(basename "$REPO_ROOT")")"
RUNTIME_DIR="$(swarm_runtime_dir "$PROJECT")" || exit 1
BARE_REPO="${RUNTIME_DIR}/upstream.git"

if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found. Are agents running?" >&2
    exit 1
fi
swarm_runtime_check "$RUNTIME_DIR" || exit 1

CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
git clone --quiet "$BARE_REPO" "$CHECK_DIR"
cd "$CHECK_DIR"
git checkout --quiet agent-work

echo "=== Recent commits ==="
git log --oneline -15

echo ""
echo "=== Status ==="
docker ps --filter "name=${PROJECT}-agent" --format "{{.Names}}: {{.Status}}" 2>/dev/null \
    || echo "(docker not available)"
