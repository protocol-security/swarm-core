#!/bin/bash
set -euo pipefail

# Unit tests for GitHub Actions workflow shape.

PASS=0
FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION_YML="$REPO_ROOT/.github/workflows/integration.yml"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== 1. Integration workflow jobs ==="

assert_eq "workflow keeps manual dispatch" "1" \
    "$(grep -cE '^  workflow_dispatch:' "$INTEGRATION_YML")"
assert_eq "workflow keeps smoke job" "1" \
    "$(grep -cE '^  smoke-test:' "$INTEGRATION_YML")"
assert_eq "workflow has no full-matrix job" "0" \
    "$(grep -cE '^  full-matrix:' "$INTEGRATION_YML" || true)"
assert_eq "workflow does not run --all" "0" \
    "$(grep -cF './tests/test.sh --all' "$INTEGRATION_YML" || true)"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
