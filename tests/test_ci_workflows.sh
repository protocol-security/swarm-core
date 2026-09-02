#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for GitHub Actions workflow shape.

PASS=0
FAIL=0
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
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
echo "=== 2. Shared test environment ==="

missing_env=""
for test_file in "$TESTS_DIR"/*.sh; do
    [ "$test_file" = "$TESTS_DIR/_test_env.sh" ] && continue
    if ! grep -qF \
            'source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"' \
            "$test_file"; then
        missing_env="${missing_env} $(basename "$test_file")"
    fi
done

assert_eq "all test scripts source the shared environment" "" "$missing_env"
assert_eq "CI checks every test script" "1" \
    "$(grep -cF 'tests/*.sh' "$CI_YML")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
