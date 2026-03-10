#!/bin/bash
set -euo pipefail

# Show what agents have pushed to the bare repo.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Show what agents have pushed to the bare repo.
Clones the bare repo to a temp directory, displays recent
commits on agent-work, and lists running agent containers.
HELP
    exit 0
fi

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SWARM_DIR/lib/check-deps.sh"
check_deps git docker

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
CHECK_DIR="/tmp/${PROJECT}-progress-check"

if [ ! -d "$BARE_REPO" ]; then
    echo "ERROR: ${BARE_REPO} not found. Are agents running?" >&2
    exit 1
fi

cd /tmp
rm -rf "$CHECK_DIR"
git clone --quiet "$BARE_REPO" "$CHECK_DIR"
cd "$CHECK_DIR"
git checkout --quiet agent-work

echo "=== Recent commits ==="
git log --oneline -15

echo ""
echo "=== Status ==="
docker ps --filter "name=${PROJECT}-agent" --format "{{.Names}}: {{.Status}}" 2>/dev/null \
    || echo "(docker not available)"

rm -rf "$CHECK_DIR"
