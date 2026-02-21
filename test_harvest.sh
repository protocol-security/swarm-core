#!/bin/bash
set -euo pipefail

# Unit tests for harvest.sh logic.
# Uses local git repos (no Docker or API key required).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# Create a source repo, bare clone, and working clone.
setup_repos() {
    rm -rf "$TMPDIR/source" "$TMPDIR/bare" "$TMPDIR/work"

    git init -q "$TMPDIR/source"
    cd "$TMPDIR/source"
    git -c user.name=test -c user.email=t@t commit -q --allow-empty -m "init"

    git clone -q --bare "$TMPDIR/source" "$TMPDIR/bare"
    git -C "$TMPDIR/bare" branch agent-work HEAD 2>/dev/null || true

    git clone -q "$TMPDIR/bare" "$TMPDIR/work"
    cd "$TMPDIR/work"
    git checkout -q -b agent-work origin/agent-work 2>/dev/null || git checkout -q agent-work
}

# Simulate agent commits on agent-work via the bare repo.
add_agent_commits() {
    local n=$1
    local agent_dir="$TMPDIR/agent-clone"
    rm -rf "$agent_dir"
    git clone -q "$TMPDIR/bare" "$agent_dir"
    cd "$agent_dir"
    git checkout -q agent-work
    for i in $(seq 1 "$n"); do
        echo "work $i" > "file-$i.txt"
        git add "file-$i.txt"
        git -c user.name=agent -c user.email=a@a commit -q -m "Agent commit $i"
    done
    git push -q origin agent-work
    rm -rf "$agent_dir"
}

# --- Harvest logic (from harvest.sh) ---

harvest() {
    local bare_repo="$1" work_dir="$2" dry_run="${3:-false}"
    local remote_name="_agent-harvest"
    cd "$work_dir"
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true

    git remote remove "$remote_name" 2>/dev/null || true
    git remote add "$remote_name" "$bare_repo"
    git fetch -q "$remote_name" agent-work

    local commit_log new_commits
    commit_log=$(git log --oneline "$remote_name/agent-work" ^HEAD)
    new_commits=$(echo "$commit_log" | grep -c . || true)

    if [ "$dry_run" = true ]; then
        git remote remove "$remote_name"
        echo "dry:${new_commits}"
        return
    fi

    if [ "$new_commits" -eq 0 ]; then
        git remote remove "$remote_name"
        echo "noop:0"
        return
    fi

    git merge -q "$remote_name/agent-work" --no-edit
    git remote remove "$remote_name"
    echo "merged:${new_commits}"
}

# ============================================================
echo "=== 1. Harvest with agent commits ==="

setup_repos
add_agent_commits 3
result=$(harvest "$TMPDIR/bare" "$TMPDIR/work")
assert_eq "3 commits merged" "merged:3" "$result"

cd "$TMPDIR/work"
assert_eq "file-1 exists" "true" "$([ -f file-1.txt ] && echo true || echo false)"
assert_eq "file-3 exists" "true" "$([ -f file-3.txt ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 2. Harvest with no new commits ==="

setup_repos
result=$(harvest "$TMPDIR/bare" "$TMPDIR/work")
assert_eq "no commits" "noop:0" "$result"

# ============================================================
echo ""
echo "=== 3. Dry run ==="

setup_repos
add_agent_commits 5
result=$(harvest "$TMPDIR/bare" "$TMPDIR/work" true)
assert_eq "dry run 5 commits" "dry:5" "$result"

cd "$TMPDIR/work"
assert_eq "file-1 not merged" "false" "$([ -f file-1.txt ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 4. Harvest twice (idempotent) ==="

setup_repos
add_agent_commits 2
harvest "$TMPDIR/bare" "$TMPDIR/work" > /dev/null
result=$(harvest "$TMPDIR/bare" "$TMPDIR/work")
assert_eq "second harvest is noop" "noop:0" "$result"

# ============================================================
echo ""
echo "=== 5. --dry flag parsing ==="

parse_dry_flag() {
    local dry=false
    for arg in "$@"; do
        case "$arg" in
            --dry) dry=true ;;
        esac
    done
    echo "$dry"
}

assert_eq "no flag"    "false" "$(parse_dry_flag)"
assert_eq "--dry flag" "true"  "$(parse_dry_flag --dry)"
assert_eq "other flag" "false" "$(parse_dry_flag --verbose)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
