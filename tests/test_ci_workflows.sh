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
echo "=== 3. Integration test runtime directory ==="

# tests/test.sh must not remove a directory the caller pointed
# SWARM_RUNTIME_DIR at, even when swarm refused it.
TEST_SH="$TESTS_DIR/test.sh"
assert_eq "integration run allocates its own runtime directory" "1" \
    "$(grep -cE '^TEST_RUNTIME_DIR=\$\(mktemp -d\)$' "$TEST_SH")"
assert_eq "integration run exports it as SWARM_RUNTIME_DIR" "1" \
    "$(grep -cF 'export SWARM_RUNTIME_DIR="$TEST_RUNTIME_DIR"' "$TEST_SH")"
assert_eq "cleanup removes only that directory" \
    '    rm_docker_dir "$TEST_RUNTIME_DIR"' \
    "$(awk '/^cleanup\(\) \{/,/^\}/' "$TEST_SH" | grep 'rm_docker_dir')"

echo ""
echo "=== 4. Unit test dependencies ==="

# Swarm and swarm harvest lock with flock(1), which macOS lacks.
assert_eq "macOS unit job installs flock" "1" \
    "$(grep -cE 'brew install .*flock' "$CI_YML")"

echo ""
echo "=== 5. The unit runner needs each file's summary ==="

# A test file that stops short (set -u, with an EXIT trap) ends with
# status 0 under Bash 3.2, the files' /bin/bash on macOS; the runner
# fails it for the summary it never printed.  A file that skips on
# purpose prints its summary, and passes.
_r=$(mktemp -d)
mkdir -p "$_r/tests" "$_r/lib"
cp "$TESTS_DIR/test.sh" "$TESTS_DIR/_test_env.sh" "$_r/tests/"
cp "$REPO_ROOT/lib/project.sh" "$_r/lib/"
git init -q "$_r"
printf '#!/bin/bash\necho "  1 passed, 0 failed"\n' > "$_r/tests/test_a.sh"
printf '#!/bin/bash\necho "SKIP: not here"\necho "  0 passed, 0 failed"\nexit 0\n' \
    > "$_r/tests/test_c.sh"
cat > "$_r/tests/test_b.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "  PASS: one"
echo "$swarm_test_unset_variable"
echo "  2 passed, 0 failed"
EOF
chmod +x "$_r/tests/"*.sh
_rc=0
_out=$(cd "$_r" && ./tests/test.sh --unit 2>&1) || _rc=$?
rm -rf "$_r"
assert_eq "a file that stops short fails the run" "1" "$_rc"
assert_eq "that file is the one failed" "true" \
    "$(grep -qE 'FAIL +test_b\.sh' <<< "$_out" && echo true || echo false)"
assert_eq "the other passes" "true" \
    "$(grep -qE 'PASS +test_a\.sh' <<< "$_out" && echo true || echo false)"
assert_eq "so does one that skips with its summary" "true" \
    "$(grep -qE 'PASS +test_c\.sh' <<< "$_out" && echo true || echo false)"
# The test files that skip on purpose print their summary too.
for _f in "$TESTS_DIR"/test_*.sh; do
    if grep -q '^    echo "SKIP:' "$_f"; then
        assert_eq "$(basename "$_f") prints a summary when it skips" "true" \
            "$(awk '/^    echo "SKIP:/ { s = 1; next }
                    s && /^    exit 0/ { print (ok ? "true" : "false"); exit }
                    s && /passed, 0 failed/ { ok = 1 }' "$_f")"
    fi
done

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
