#!/bin/bash
set -euo pipefail

# Unit tests for the manual interactive E2E fixture generator.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATOR="$REPO_ROOT/tests/manual_interactive_e2e.sh"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

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

run_setup_branch() {
    local branch="$1" profile="$2" driver="$3" model="$4"

    git checkout -q -B "$branch" main
    env \
        AGENT_ID="interactive-${profile}" \
        SWARM_DRIVER="$driver" \
        SWARM_MODEL="$model" \
        SWARM_INTERACTIVE_BRANCH="$branch" \
        SWARM_INTERACTIVE_PROFILE="$profile" \
        bash scripts/setup.sh

    printf 'profile=%s\n' "$profile" \
        > "test-results/manual-${profile}.md"
    git add test-results
    git -c commit.gpgsign=false commit -q \
        -m "Record ${profile} manual smoke"
}

echo "=== 1. Generated fixture can merge two interactive branches ==="

TARGET="$TMPDIR/manual-swarm"
"$GENERATOR" "$TARGET" >/dev/null

cd "$TARGET"
assert_eq "fixture repo created" "true" \
    "$([ -d .git ] && echo true || echo false)"
assert_eq "runbook created" "true" \
    "$([ -f MANUAL_STEPS.md ] && echo true || echo false)"
assert_eq "post-process setup script created" "true" \
    "$([ -x scripts/post-setup.sh ] && echo true || echo false)"
assert_eq "post_process.setup runs the lighter script" \
    "scripts/post-setup.sh" \
    "$(jq -r '.post_process.setup // empty' swarm.json)"

CODEX_BRANCH="swarm/test/interactive-codex-manual-123"
CLAUDE_BRANCH="swarm/test/interactive-claude-manual-456"

run_setup_branch "$CODEX_BRANCH" "codex-manual" "codex-cli" "gpt-5.4"
run_setup_branch \
    "$CLAUDE_BRANCH" "claude-manual" "claude-code" "claude-opus-4-6"

git checkout -q main
set +e
codex_merge_output=$(git merge --no-edit "$CODEX_BRANCH" 2>&1)
codex_merge_rc=$?
claude_merge_output=$(git merge --no-edit "$CLAUDE_BRANCH" 2>&1)
claude_merge_rc=$?
set -e

assert_eq "first interactive branch merges cleanly" "0" "$codex_merge_rc"
assert_eq "second interactive branch merges cleanly" "0" "$claude_merge_rc"
assert_eq "no shared setup log is created" "false" \
    "$([ -e test-results/setup.log ] && echo true || echo false)"
assert_eq "codex setup log exists" "true" \
    "$([ -f test-results/setup-swarm-test-interactive-codex-manual-123.log ] \
        && echo true || echo false)"
assert_eq "claude setup log exists" "true" \
    "$([ -f test-results/setup-swarm-test-interactive-claude-manual-456.log ] \
        && echo true || echo false)"
assert_eq "manual codex marker merged" "true" \
    "$([ -f test-results/manual-codex-manual.md ] \
        && echo true || echo false)"
assert_eq "manual claude marker merged" "true" \
    "$([ -f test-results/manual-claude-manual.md ] \
        && echo true || echo false)"

if [ "$codex_merge_rc" -ne 0 ]; then
    printf '%s\n' "$codex_merge_output"
fi
if [ "$claude_merge_rc" -ne 0 ]; then
    printf '%s\n' "$claude_merge_output"
fi

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
