#!/bin/bash
set -euo pipefail

# Show what agents have pushed to the bare repo.

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
