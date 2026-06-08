#!/bin/bash
set -euo pipefail

# Unit tests for harvest.sh logic.
# Uses local git repos (no Docker or API key required).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARVEST_SH="$REPO_ROOT/harvest.sh"
HARVEST_BARE=""
GUARD_BARE=""
INTERACTIVE_BARE=""
TAG_BARE=""
cleanup() {
    rm -rf "$TMPDIR"
    [ -n "${HARVEST_BARE:-}" ] && rm -rf "$HARVEST_BARE"
    [ -n "${GUARD_BARE:-}" ]   && rm -rf "$GUARD_BARE"
    [ -n "${INTERACTIVE_BARE:-}" ] && rm -rf "$INTERACTIVE_BARE"
    [ -n "${TAG_BARE:-}" ] && rm -rf "$TAG_BARE"
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

# Create a source repo, bare clone, and working clone.
setup_repos() {
    rm -rf "$TMPDIR/source" "$TMPDIR/bare" "$TMPDIR/work"

    git init -q "$TMPDIR/source"
    cd "$TMPDIR/source"
    git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
        commit -q --allow-empty -m "init"

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
        git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
            commit -q -m "Agent commit $i"
    done
    git push -q origin agent-work
    rm -rf "$agent_dir"
}

add_interactive_commits() {
    local branch="$1" n="$2"
    local agent_dir="$TMPDIR/interactive-clone"
    rm -rf "$agent_dir"
    git clone -q "$TMPDIR/bare" "$agent_dir"
    cd "$agent_dir"
    git checkout -q -b "$branch" origin/agent-work
    for i in $(seq 1 "$n"); do
        echo "interactive $i" > "interactive-$i.txt"
        git add "interactive-$i.txt"
        git -c user.name=operator -c user.email=o@o \
            -c commit.gpgsign=false \
            commit -q -m "Interactive commit $i"
    done
    git push -q origin "HEAD:refs/heads/${branch}"
    rm -rf "$agent_dir"
}

# --- Harvest logic (from harvest.sh) ---

harvest() {
    local bare_repo="$1" work_dir="$2" dry_run="${3:-false}"
    local remote_name="_agent-harvest"
    local branches=(agent-work)
    local total_new=0
    local branch remote_ref commit_log new_commits
    cd "$work_dir"
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true

    git remote remove "$remote_name" 2>/dev/null || true
    git remote add "$remote_name" "$bare_repo"
    git fetch -q "$remote_name" '+refs/heads/*:refs/remotes/_agent-harvest/*'

    while IFS= read -r branch; do
        [ -n "$branch" ] && branches+=("$branch")
    done < <(git -C "$bare_repo" for-each-ref \
        --format='%(refname:short)' refs/heads/swarm 2>/dev/null \
        | grep -E '/interactive-' || true)

    for branch in "${branches[@]}"; do
        remote_ref="$remote_name/$branch"
        commit_log=$(git log --oneline "$remote_ref" ^HEAD 2>/dev/null || true)
        new_commits=$(echo "$commit_log" | grep -c . || true)
        total_new=$((total_new + new_commits))
    done

    if [ "$dry_run" = true ]; then
        git remote remove "$remote_name"
        echo "dry:${total_new}"
        return
    fi

    if [ "$total_new" -eq 0 ]; then
        git remote remove "$remote_name"
        echo "noop:0"
        return
    fi

    for branch in "${branches[@]}"; do
        remote_ref="$remote_name/$branch"
        commit_log=$(git log --oneline "$remote_ref" ^HEAD 2>/dev/null || true)
        new_commits=$(echo "$commit_log" | grep -c . || true)
        [ "$new_commits" -eq 0 ] && continue
        git merge -q "$remote_ref" --no-edit
    done
    git remote remove "$remote_name"
    echo "merged:${total_new}"
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
echo "=== 1.5 Harvest with interactive branch commits ==="

setup_repos
add_interactive_commits "swarm/test/interactive-hunter-a1b2" 2
result=$(harvest "$TMPDIR/bare" "$TMPDIR/work")
assert_eq "2 interactive commits merged" "merged:2" "$result"

cd "$TMPDIR/work"
assert_eq "interactive-1 exists" "true" \
    "$([ -f interactive-1.txt ] && echo true || echo false)"
assert_eq "interactive-2 exists" "true" \
    "$([ -f interactive-2.txt ] && echo true || echo false)"

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
echo "=== 6. Structural: preview pipe guarded against SIGPIPE ==="

preview_line=$(grep -E 'head -20' "$HARVEST_SH" | head -1)
assert_eq "preview line exists" \
    "true" \
    "$([ -n "$preview_line" ] && echo true || echo false)"
assert_eq "preview pipe ends with || true" \
    "true" \
    "$(printf '%s' "$preview_line" | grep -qE '\|\|[[:space:]]*true[[:space:]]*$' \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 7. Behavioural: harvest.sh --dry survives >20 commits ==="

HARVEST_PROJECT="swarmtest-harvest-sigpipe-$$"
HARVEST_WORK="$TMPDIR/$HARVEST_PROJECT"
HARVEST_BARE="/tmp/${HARVEST_PROJECT}-upstream.git"

rm -rf "$HARVEST_BARE" "$HARVEST_WORK"
mkdir -p "$HARVEST_WORK"
git init -q "$HARVEST_WORK"
cd "$HARVEST_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$HARVEST_WORK" "$HARVEST_BARE"
git -C "$HARVEST_BARE" branch agent-work HEAD 2>/dev/null || true

# Seed 100 commits with ~1 KiB subject padding so the
# `git log --oneline` output (~100 KiB) exceeds the kernel
# pipe buffer (64 KiB) and has many more than 20 lines.  Both
# conditions are needed to make the preview pipe on harvest.sh
# line 55 trigger SIGPIPE without the `|| true` guard.  Empty
# commits keep setup fast (~0.15 s).
HARVEST_AGENT="$TMPDIR/harvest-sigpipe-agent"
rm -rf "$HARVEST_AGENT"
git clone -q "$HARVEST_BARE" "$HARVEST_AGENT"
cd "$HARVEST_AGENT"
git checkout -q agent-work
LONG_PAD=$(awk 'BEGIN { for (i = 0; i < 1000; i++) printf "x" }')
for i in $(seq 1 100); do
    git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
        commit -q --allow-empty -m "Agent commit $i $LONG_PAD"
done
git push -q origin agent-work

cd "$HARVEST_WORK"
if output=$(bash "$HARVEST_SH" --dry 2>&1); then
    rc=0
else
    rc=$?
fi

assert_eq "harvest.sh --dry exits 0 on oversized log" "0" "$rc"
assert_eq "shows 100 new commits header" "true" \
    "$(printf '%s\n' "$output" | grep -q '^100 new commits on agent-work:' \
        && echo true || echo false)"
assert_eq "shows overflow tail" "true" \
    "$(printf '%s\n' "$output" | grep -qE '\.\.\. and 80 more' \
        && echo true || echo false)"
assert_eq "shows dry-run notice" "true" \
    "$(printf '%s\n' "$output" | grep -q 'dry run' \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 7.5 Behavioural: harvest.sh sees interactive branches ==="

INTERACTIVE_PROJECT="swarmtest-harvest-interactive-$$"
INTERACTIVE_WORK="$TMPDIR/$INTERACTIVE_PROJECT"
INTERACTIVE_BARE="/tmp/${INTERACTIVE_PROJECT}-upstream.git"
INTERACTIVE_AGENT="$TMPDIR/harvest-interactive-agent"
INTERACTIVE_BRANCH="swarm/test/interactive-hunter-a1b2"

rm -rf "$INTERACTIVE_WORK" "$INTERACTIVE_BARE" "$INTERACTIVE_AGENT"
mkdir -p "$INTERACTIVE_WORK"
git init -q "$INTERACTIVE_WORK"
cd "$INTERACTIVE_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$INTERACTIVE_WORK" "$INTERACTIVE_BARE"
git -C "$INTERACTIVE_BARE" branch agent-work HEAD 2>/dev/null || true

git clone -q "$INTERACTIVE_BARE" "$INTERACTIVE_AGENT"
cd "$INTERACTIVE_AGENT"
git checkout -q -b "$INTERACTIVE_BRANCH" origin/agent-work
echo "human work" > human.txt
git add human.txt
git -c user.name=operator -c user.email=o@o -c commit.gpgsign=false \
    commit -q -m "Human guided commit"
git push -q origin "HEAD:refs/heads/${INTERACTIVE_BRANCH}"
rm -rf "$INTERACTIVE_AGENT"

cd "$INTERACTIVE_WORK"
if int_output=$(bash "$HARVEST_SH" --dry 2>&1); then
    int_rc=0
else
    int_rc=$?
fi
assert_eq "interactive dry-run exits 0" "0" "$int_rc"
assert_eq "interactive branch header shown" "true" \
    "$(printf '%s\n' "$int_output" \
        | grep -q "^1 new commits on ${INTERACTIVE_BRANCH}:" \
        && echo true || echo false)"

if int_merge_output=$(bash "$HARVEST_SH" 2>&1); then
    int_merge_rc=0
else
    int_merge_rc=$?
fi
assert_eq "interactive merge exits 0" "0" "$int_merge_rc"
assert_eq "interactive merge names branch" "true" \
    "$(printf '%s\n' "$int_merge_output" \
        | grep -q -- "--- Merging ${INTERACTIVE_BRANCH} ---" \
        && echo true || echo false)"
assert_eq "interactive file merged" "true" \
    "$([ -f human.txt ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 8. SIGPIPE regression: guarded pipe survives big log ==="

# Synthetic log large enough to overflow the kernel pipe buffer
# (typically 64 KiB on Linux).  5000 lines x ~50 bytes ≈ 250 KiB.
# Written to a file so we can feed it to subshells without
# blowing ARG_MAX.
big_log_file="$TMPDIR/big_log.txt"
awk 'BEGIN { for (i = 0; i < 5000; i++)
    print "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }' \
    > "$big_log_file"

# The contract we actually care about: under `set -euo pipefail`
# the unguarded form must abort before the next statement runs,
# and the guarded form must not.  The exit code varies by
# platform -- bash builtins that hit EPIPE may report 141
# (SIGPIPE) on Linux/newer bash or 1 (generic write error) on
# macOS/bash-3.2 -- so we test the observable behaviour instead
# of pinning a specific code.
set +e
bash -c '
    set -euo pipefail
    LOG=$(cat "$1")
    echo "$LOG" | head -20 >/dev/null
    echo REACHED_AFTER_PIPE
' _ "$big_log_file" > "$TMPDIR/unguarded.out" 2>&1
unguarded_rc=$?
set -e
assert_eq "unguarded pipe exits non-zero" "true" \
    "$([ "$unguarded_rc" -ne 0 ] && echo true || echo false)"
assert_eq "unguarded pipe aborts before next statement" "false" \
    "$(grep -q '^REACHED_AFTER_PIPE$' "$TMPDIR/unguarded.out" \
        && echo true || echo false)"

# The actual harvest.sh idiom (line 55): `|| true` must recover.
set +e
bash -c '
    set -euo pipefail
    LOG=$(cat "$1")
    echo "$LOG" | head -20 >/dev/null || true
    echo REACHED_AFTER_PIPE
' _ "$big_log_file" > "$TMPDIR/guarded.out" 2>&1
guarded_rc=$?
set -e
assert_eq "guarded pipe exits 0" "0" "$guarded_rc"
assert_eq "guarded pipe continues past the preview" "true" \
    "$(grep -q '^REACHED_AFTER_PIPE$' "$TMPDIR/guarded.out" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 9. Behavioural: harvest.sh refuses divergent bare ==="

# Reproduces issue #97: an upstream history rewrite (force-push,
# rebase) leaves the bare's agent-work pointing at a tip whose
# ancestry no longer matches the working tree's HEAD.  Without
# the guard, harvest.sh silently 3-way-merges and re-introduces
# commits the operator already removed; with the guard it aborts
# with a clear remediation.

GUARD_PROJECT="swarmtest-harvest-guard-$$"
GUARD_WORK="$TMPDIR/$GUARD_PROJECT"
GUARD_BARE="/tmp/${GUARD_PROJECT}-upstream.git"
GUARD_AGENT="$TMPDIR/harvest-guard-agent"

rm -rf "$GUARD_WORK" "$GUARD_BARE" "$GUARD_AGENT"
mkdir -p "$GUARD_WORK"
git init -q "$GUARD_WORK"
cd "$GUARD_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m A
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m B
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m C

git clone -q --bare "$GUARD_WORK" "$GUARD_BARE"
# Move bare's agent-work back to B (HEAD~1) and have an "agent"
# commit on top of B.  agent-work then descends from B but not
# from HEAD (=C), so the guard's --is-ancestor check fails.
git -C "$GUARD_BARE" branch -f agent-work HEAD~1

git clone -q "$GUARD_BARE" "$GUARD_AGENT"
cd "$GUARD_AGENT"
git checkout -q agent-work
git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
    commit -q --allow-empty -m "agent commit on sibling"
git push -q origin agent-work
rm -rf "$GUARD_AGENT"

cd "$GUARD_WORK"
HEAD_BEFORE=$(git rev-parse HEAD)
set +e
guard_output=$(bash "$HARVEST_SH" 2>&1)
guard_rc=$?
set -e
HEAD_AFTER=$(git rev-parse HEAD)

assert_eq "guard exits non-zero on divergent bare" "true" \
    "$([ "$guard_rc" -ne 0 ] && echo true || echo false)"
assert_eq "guard prints the diagnostic line" "true" \
    "$(printf '%s\n' "$guard_output" \
        | grep -q 'does not descend from HEAD' \
        && echo true || echo false)"
assert_eq "guard names short HEAD in diagnostic" "true" \
    "$(printf '%s\n' "$guard_output" \
        | grep -qE "HEAD:[[:space:]]+${HEAD_BEFORE:0:7}" \
        && echo true || echo false)"
assert_eq "guard names the bare path in remediation" "true" \
    "$(printf '%s\n' "$guard_output" \
        | grep -qF "rm -rf ${GUARD_BARE}" \
        && echo true || echo false)"
assert_eq "no merge commit produced" "$HEAD_BEFORE" "$HEAD_AFTER"
assert_eq "_agent-harvest remote cleaned up after failure" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"

# Sanity check the happy path: when agent-work descends from
# HEAD again, the same harvest.sh invocation succeeds.  Catches
# a regression where the guard accidentally rejects valid runs.
git -C "$GUARD_BARE" branch -f agent-work "$HEAD_BEFORE"
git clone -q "$GUARD_BARE" "$GUARD_AGENT"
cd "$GUARD_AGENT"
git checkout -q agent-work
git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
    commit -q --allow-empty -m "agent fast-forward"
git push -q origin agent-work
rm -rf "$GUARD_AGENT"

cd "$GUARD_WORK"
set +e
ff_output=$(bash "$HARVEST_SH" 2>&1)
ff_rc=$?
set -e

assert_eq "fast-forward harvest still exits 0" "0" "$ff_rc"
assert_eq "fast-forward shows new commit header" "true" \
    "$(printf '%s\n' "$ff_output" \
        | grep -q '^1 new commits on agent-work:' \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 10. Restore tag created before harvest ==="

# harvest.sh tags the pre-merge branch tip with a local
# swarm-harvest-<date>-<time> tag so a harvest can be undone with
# `git reset --hard <tag>`.  The tag lives in refs/tags and is
# skipped on --dry and when nothing is new.

TAG_PROJECT="swarmtest-harvest-tag-$$"
TAG_WORK="$TMPDIR/$TAG_PROJECT"
TAG_BARE="/tmp/${TAG_PROJECT}-upstream.git"
TAG_AGENT="$TMPDIR/harvest-tag-agent"

rm -rf "$TAG_WORK" "$TAG_BARE" "$TAG_AGENT"
mkdir -p "$TAG_WORK"
git init -q "$TAG_WORK"
cd "$TAG_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$TAG_WORK" "$TAG_BARE"
git -C "$TAG_BARE" branch agent-work HEAD 2>/dev/null || true

git clone -q "$TAG_BARE" "$TAG_AGENT"
cd "$TAG_AGENT"
git checkout -q agent-work
echo "tag work" > tagwork.txt
git add tagwork.txt
git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
    commit -q -m "Agent commit for restore-tag test"
git push -q origin agent-work
rm -rf "$TAG_AGENT"

cd "$TAG_WORK"
# A dry run must not create a restore tag.
bash "$HARVEST_SH" --dry >/dev/null 2>&1 || true
assert_eq "dry run creates no restore tag" "0" \
    "$(git tag --list 'swarm-harvest-*' | grep -c . || true)"

# A real harvest tags the pre-merge HEAD, then merges.
TAG_HEAD_BEFORE=$(git rev-parse HEAD)
bash "$HARVEST_SH" >/dev/null 2>&1 || true
assert_eq "harvest creates one restore tag" "1" \
    "$(git tag --list 'swarm-harvest-*' | grep -c . || true)"
TAG_NAME=$(git tag --list 'swarm-harvest-*' | head -1)
assert_eq "restore tag points at pre-merge HEAD" "$TAG_HEAD_BEFORE" \
    "$(git rev-parse "${TAG_NAME}^{commit}")"

# A second harvest with nothing new must not add another tag.
bash "$HARVEST_SH" >/dev/null 2>&1 || true
assert_eq "noop harvest adds no restore tag" "1" \
    "$(git tag --list 'swarm-harvest-*' | grep -c . || true)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
