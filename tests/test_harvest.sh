#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for swarm harvest logic.
# Uses local git repos (no Docker or API key required).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARVEST_SH="$REPO_ROOT/libexec/harvest"
LEGACY_BARE=""
cleanup() {
    rm -rf "$TMPDIR"
    if [ -n "$LEGACY_BARE" ]; then
        rm -rf "$LEGACY_BARE"
    fi
}
trap cleanup EXIT

# Keep the host's Docker out of these tests: this docker answers like a
# client whose daemon is down and logs what it was asked.  Sections that
# need containers put their own fake in front of it.
_down_bin="$TMPDIR/docker-down"
_down_log="$TMPDIR/docker-down.log"
mkdir -p "$_down_bin"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 1\n' "$_down_log" \
    > "$_down_bin/docker"
chmod +x "$_down_bin/docker"
PATH="$_down_bin:$PATH"

# Point swarm harvest at a private runtime directory below TMPDIR, with an
# engagement recorded as this engine records it before it makes the
# bare repo (record_engagement writes it again).  record_base BARE
# records BARE's HEAD, the commit it was made from, as the engagement's
# base, which harvest needs.
ENGAGEMENT_BASE=""
use_runtime() {
    SWARM_RUNTIME_DIR="$TMPDIR/runtime-$1"
    export SWARM_RUNTIME_DIR
    mkdir -m 700 "$SWARM_RUNTIME_DIR"
    ENGAGEMENT_BASE=""
    record_engagement
}
record_engagement() {
    jq -n --arg b "$ENGAGEMENT_BASE" '{schema: "swarm-core.state/v1",
           engagement_id: "eng-1", engagement_token: "t1",
           docker_daemon: "d1"}
        + (if $b == "" then {} else {base_commit: $b} end)' \
        > "$SWARM_RUNTIME_DIR/state.json"
    chmod 600 "$SWARM_RUNTIME_DIR/state.json"
}
record_base() {
    ENGAGEMENT_BASE=$(git -C "$1" rev-parse HEAD)
    record_engagement
}

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

# --- Harvest logic (from swarm harvest) ---

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
    "$(grep -qE '\|\|[[:space:]]*true[[:space:]]*$' <<< "$preview_line" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 7. Behavioural: swarm harvest --dry survives >20 commits ==="

HARVEST_PROJECT="swarmtest-harvest-sigpipe-$$"
HARVEST_WORK="$TMPDIR/$HARVEST_PROJECT"
use_runtime sigpipe
HARVEST_BARE="$SWARM_RUNTIME_DIR/upstream.git"

rm -rf "$HARVEST_BARE" "$HARVEST_WORK"
mkdir -p "$HARVEST_WORK"
git init -q "$HARVEST_WORK"
cd "$HARVEST_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$HARVEST_WORK" "$HARVEST_BARE"
record_base "$HARVEST_BARE"
git -C "$HARVEST_BARE" branch agent-work HEAD 2>/dev/null || true

# Seed 100 commits with ~1 KiB subject padding so the
# `git log --oneline` output (~100 KiB) exceeds the kernel
# pipe buffer (64 KiB) and has many more than 20 lines.  Both
# conditions are needed to make the preview pipe on swarm harvest
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

assert_eq "swarm harvest --dry exits 0 on oversized log" "0" "$rc"
assert_eq "shows 100 new commits header" "true" \
    "$(grep -q '^100 new commits on agent-work:' <<< "$output" \
        && echo true || echo false)"
assert_eq "shows overflow tail" "true" \
    "$(grep -qE '\.\.\. and 80 more' <<< "$output" \
        && echo true || echo false)"
assert_eq "shows dry-run notice" "true" \
    "$(grep -q 'dry run' <<< "$output" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 7.5 Behavioural: swarm harvest sees interactive branches ==="

INTERACTIVE_PROJECT="swarmtest-harvest-interactive-$$"
INTERACTIVE_WORK="$TMPDIR/$INTERACTIVE_PROJECT"
use_runtime interactive
INTERACTIVE_BARE="$SWARM_RUNTIME_DIR/upstream.git"
INTERACTIVE_AGENT="$TMPDIR/harvest-interactive-agent"
INTERACTIVE_BRANCH="swarm/test/interactive-hunter-a1b2"

rm -rf "$INTERACTIVE_WORK" "$INTERACTIVE_BARE" "$INTERACTIVE_AGENT"
mkdir -p "$INTERACTIVE_WORK"
git init -q "$INTERACTIVE_WORK"
cd "$INTERACTIVE_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$INTERACTIVE_WORK" "$INTERACTIVE_BARE"
record_base "$INTERACTIVE_BARE"
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
    "$(grep -q "^1 new commits on ${INTERACTIVE_BRANCH}:" <<< "$int_output" \
        && echo true || echo false)"

if int_merge_output=$(bash "$HARVEST_SH" 2>&1); then
    int_merge_rc=0
else
    int_merge_rc=$?
fi
assert_eq "interactive merge exits 0" "0" "$int_merge_rc"
assert_eq "interactive merge names branch" "true" \
    "$(grep -q -- "--- Merging ${INTERACTIVE_BRANCH} ---" \
        <<< "$int_merge_output" \
        && echo true || echo false)"
assert_eq "interactive file merged" "true" \
    "$([ -f human.txt ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 7.6 Behavioural: interactive state copy stays private ==="

# docker cp gives the copy the mode of the source file, so a 0644
# interactive_state stays readable by other users unless the copy
# lands in a private directory of its own.  The fake docker reports
# one stopped interactive container and logs where the copy went.
# TMPDIR points at a world-writable directory like /tmp; GNU mktemp
# honours it, macOS mktemp uses the per-user temp directory instead.
_fake_bin="$TMPDIR/fake-docker"
_cp_log="$TMPDIR/docker-cp.log"
_shared_tmp="$TMPDIR/shared-tmp"
mkdir -p "$_fake_bin" "$_shared_tmp"
chmod 1777 "$_shared_tmp"
_ctr_name="${INTERACTIVE_PROJECT}-agent-interactive-hunter-a1b2"
_ctr_owner=$(cd -P "$INTERACTIVE_WORK" && pwd -P)
cat > "$_fake_bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    ps)
        # Owner listing and name listing, both JSON.
        case "\$*" in
            *)
                printf '{"name":"%s","project":"%s","owner":"%s"}\n' \
                    "$_ctr_name" "\${FAKE_PROJECT-$INTERACTIVE_PROJECT}" \
                    "\${FAKE_OWNER-$_ctr_owner}" ;;
        esac ;;
    container)
        printf '{"id":"cid-1","labels":{"swarm-core.checkout":"%s",%s}}\n' \
            "\${FAKE_OWNER-$_ctr_owner}" \
            "\"swarm-core.project\":\"$INTERACTIVE_PROJECT\"" ;;
    info) exit 0 ;;
    inspect) echo "exited" ;;
    cp)
        printf 'dirty=true\nbranch=${INTERACTIVE_BRANCH}\n' > "\$3"
        chmod 644 "\$3"
        printf '%s|%s\n' "\$3" \
            "\$(ls -ld "\$(dirname "\$3")" | cut -c1-10)" >> "$_cp_log"
        ;;
esac
EOF
chmod +x "$_fake_bin/docker"

cd "$INTERACTIVE_WORK"
_dirty_out=$(PATH="$_fake_bin:$PATH" TMPDIR="$_shared_tmp" \
    bash "$HARVEST_SH" --dry 2>&1 || true)
_cp_entry=$(head -1 "$_cp_log" 2>/dev/null || true)
_cp_dest="${_cp_entry%%|*}"
assert_eq "dirty interactive container is reported" "true" \
    "$(grep -q 'has uncommitted interactive work' <<< "$_dirty_out" \
        && echo true || echo false)"
assert_eq "copy lands in an owner-only directory" "drwx------" \
    "${_cp_entry##*|}"
assert_eq "copy is removed after the check" "false" \
    "$([ -n "$_cp_dest" ] && [ -e "$_cp_dest" ] && echo true || echo false)"
assert_eq "copy directory is removed after the check" "false" \
    "$([ -n "$_cp_dest" ] && [ -e "$(dirname "$_cp_dest")" ] \
        && echo true || echo false)"
# ============================================================
echo ""
echo "=== 7.7 Behavioural: harvest again after merging both ==="

# The first harvest fast-forwards to agent-work and merges the
# interactive branch with a merge commit, so agent-work no longer
# descends from HEAD.  Both branches are already in HEAD, so
# a second harvest has nothing to merge and must not trip the
# divergence guard.

AGAIN_PROJECT="swarmtest-harvest-again-$$"
AGAIN_WORK="$TMPDIR/$AGAIN_PROJECT"
use_runtime again
AGAIN_BARE="$SWARM_RUNTIME_DIR/upstream.git"
AGAIN_AGENT="$TMPDIR/harvest-again-agent"
AGAIN_BRANCH="swarm/test/interactive-again-c3d4"

rm -rf "$AGAIN_WORK" "$AGAIN_BARE" "$AGAIN_AGENT"
mkdir -p "$AGAIN_WORK"
git init -q "$AGAIN_WORK"
cd "$AGAIN_WORK"
git config user.name test
git config user.email t@t
git config commit.gpgsign false
git commit -q --allow-empty -m "init"
git clone -q --bare "$AGAIN_WORK" "$AGAIN_BARE"
record_base "$AGAIN_BARE"
git -C "$AGAIN_BARE" branch agent-work HEAD 2>/dev/null || true

git clone -q "$AGAIN_BARE" "$AGAIN_AGENT"
cd "$AGAIN_AGENT"
git checkout -q agent-work
echo "agent work" > agent.txt
git add agent.txt
git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
    commit -q -m "Agent commit"
git push -q origin agent-work
git checkout -q -b "$AGAIN_BRANCH" HEAD~1
echo "human work" > human.txt
git add human.txt
git -c user.name=operator -c user.email=o@o -c commit.gpgsign=false \
    commit -q -m "Human guided commit"
git push -q origin "HEAD:refs/heads/${AGAIN_BRANCH}"
rm -rf "$AGAIN_AGENT"

cd "$AGAIN_WORK"
if again_first=$(bash "$HARVEST_SH" 2>&1); then
    again_first_rc=0
else
    again_first_rc=$?
fi
assert_eq "first harvest exits 0" "0" "$again_first_rc"
assert_eq "first harvest merges the interactive branch" "true" \
    "$(grep -q -- "--- Merging ${AGAIN_BRANCH} ---" <<< "$again_first" \
        && echo true || echo false)"
assert_eq "first harvest merged both files" "true" \
    "$([ -f agent.txt ] && [ -f human.txt ] && echo true || echo false)"
assert_eq "agent-work no longer descends from HEAD" "false" \
    "$(git merge-base --is-ancestor HEAD \
        "$(git -C "$AGAIN_BARE" rev-parse agent-work)" \
        && echo true || echo false)"

again_head=$(git rev-parse HEAD)
again_tags=$(git tag | wc -l | tr -d ' ')
if again_second=$(bash "$HARVEST_SH" 2>&1); then
    again_second_rc=0
else
    again_second_rc=$?
fi
assert_eq "second harvest exits 0" "0" "$again_second_rc"
assert_eq "second harvest has nothing to merge" "true" \
    "$(grep -q '^Nothing new to merge\.$' <<< "$again_second" \
        && echo true || echo false)"
assert_eq "second harvest shows no guard error" "false" \
    "$(grep -q 'does not descend from HEAD' <<< "$again_second" \
        && echo true || echo false)"
assert_eq "second harvest leaves HEAD alone" "$again_head" \
    "$(git rev-parse HEAD)"
assert_eq "second harvest adds no tag" "$again_tags" \
    "$(git tag | wc -l | tr -d ' ')"
assert_eq "second harvest removes its remote" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"

if again_dry=$(bash "$HARVEST_SH" --dry 2>&1); then
    again_dry_rc=0
else
    again_dry_rc=$?
fi
assert_eq "dry run after merge exits 0" "0" "$again_dry_rc"
assert_eq "dry run lists no new commits" "true" \
    "$(grep -q "^0 new commits on ${AGAIN_BRANCH}:" <<< "$again_dry" \
        && echo true || echo false)"

# An interactive branch that HEAD has moved past is skipped, and
# new agent work is still merged in the same harvest.
OLD_WORK="$TMPDIR/swarmtest-harvest-older-$$"
use_runtime older
OLD_BARE="$SWARM_RUNTIME_DIR/upstream.git"
OLD_AGENT="$TMPDIR/harvest-older-agent"
OLD_BRANCH="swarm/test/interactive-older-e5f6"

rm -rf "$OLD_WORK" "$OLD_BARE" "$OLD_AGENT"
git init -q "$OLD_WORK"
cd "$OLD_WORK"
git config user.name test
git config user.email t@t
git config commit.gpgsign false
git commit -q --allow-empty -m "init"
git branch "$OLD_BRANCH"
git commit -q --allow-empty -m "local"
git clone -q --bare "$OLD_WORK" "$OLD_BARE"
record_base "$OLD_BARE"
git -C "$OLD_BARE" branch agent-work HEAD 2>/dev/null || true

git clone -q "$OLD_BARE" "$OLD_AGENT"
cd "$OLD_AGENT"
git checkout -q agent-work
git -c user.name=agent -c user.email=a@a -c commit.gpgsign=false \
    commit -q --allow-empty -m "Agent commit after local"
git push -q origin agent-work
rm -rf "$OLD_AGENT"

cd "$OLD_WORK"
git branch -D -q "$OLD_BRANCH"
if older_output=$(bash "$HARVEST_SH" 2>&1); then
    older_rc=0
else
    older_rc=$?
fi
assert_eq "older interactive branch: harvest exits 0" "0" "$older_rc"
assert_eq "older interactive branch: 0 new commits" "true" \
    "$(grep -q "^0 new commits on ${OLD_BRANCH}:" <<< "$older_output" \
        && echo true || echo false)"
assert_eq "older interactive branch: agent work merged" \
    "Agent commit after local" "$(git log -1 --format=%s)"

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

# The actual swarm harvest idiom (line 55): `|| true` must recover.
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
echo "=== 9. Behavioural: swarm harvest refuses divergent bare ==="

# Reproduces issue #97: an upstream history rewrite (force-push,
# rebase) leaves the bare's agent-work pointing at a tip whose
# ancestry no longer matches the working tree's HEAD.  Without
# the guard, swarm harvest silently 3-way-merges and re-introduces
# commits the operator already removed; with the guard it aborts
# with a clear remediation.

GUARD_PROJECT="swarmtest-harvest-guard-$$"
GUARD_WORK="$TMPDIR/$GUARD_PROJECT"
# Shell metacharacters in the path check the quoting of the rm hint.
use_runtime 'guard $HOME "q"'
GUARD_BARE="$SWARM_RUNTIME_DIR/upstream.git"
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
record_base "$GUARD_BARE"
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
    "$(grep -q 'is not built on the commit this' <<< "$guard_output" \
        && echo true || echo false)"
assert_eq "guard names the engagement's base" "true" \
    "$(grep -qE "base:[[:space:]]+${HEAD_BEFORE:0:12}" <<< "$guard_output" \
        && echo true || echo false)"
assert_eq "guard sends the user to cleanup --allow-unharvested" "true" \
    "$(grep -q 'swarm cleanup --allow-unharvested' <<< "$guard_output" \
        && echo true || echo false)"
assert_eq "guard prints no removal command" "0" \
    "$(grep -cE 'docker run|rm -rf' <<< "$guard_output" || true)"
assert_eq "no merge commit produced" "$HEAD_BEFORE" "$HEAD_AFTER"
assert_eq "_agent-harvest remote cleaned up after failure" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"

# Sanity check the happy path: when agent-work descends from
# HEAD again, the same swarm harvest invocation succeeds.  Catches
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
    "$(grep -q '^1 new commits on agent-work:' <<< "$ff_output" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 10. Restore tag created before harvest ==="

# swarm harvest tags the pre-merge branch tip with a local
# swarm-harvest-<date>-<time> tag so a harvest can be undone with
# `git reset --hard <tag>`.  The tag lives in refs/tags and is
# skipped on --dry and when nothing is new.

TAG_PROJECT="swarmtest-harvest-tag-$$"
TAG_WORK="$TMPDIR/$TAG_PROJECT"
use_runtime tag
TAG_BARE="$SWARM_RUNTIME_DIR/upstream.git"
TAG_AGENT="$TMPDIR/harvest-tag-agent"

rm -rf "$TAG_WORK" "$TAG_BARE" "$TAG_AGENT"
mkdir -p "$TAG_WORK"
git init -q "$TAG_WORK"
cd "$TAG_WORK"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
git clone -q --bare "$TAG_WORK" "$TAG_BARE"
record_base "$TAG_BARE"
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

# Two harvests in the same second, with new work in between, both tag:
# the later name gets a suffix (a date first on PATH stops the clock).
TAG_CLOCK="$TMPDIR/tag-clock"
mkdir -p "$TAG_CLOCK"
printf '#!/bin/bash\necho 2030-01-01-000000\n' > "$TAG_CLOCK/date"
chmod +x "$TAG_CLOCK/date"
tag_twice() {
    local agent="$TMPDIR/tag-agent-$1"
    git clone -q "$TAG_BARE" "$agent"
    git -C "$agent" checkout -q agent-work
    echo "$1" > "$agent/tag-$1.txt"
    git -C "$agent" add "tag-$1.txt"
    git -C "$agent" -c user.name=agent -c user.email=a@a \
        -c commit.gpgsign=false commit -q -m "Agent commit $1"
    git -C "$agent" push -q origin agent-work
    rm -rf "$agent"
    PATH="$TAG_CLOCK:$PATH" bash "$HARVEST_SH" >/dev/null 2>&1
}
tag_rc=0
tag_twice one || tag_rc=$?
tag_twice two || tag_rc=$?
assert_eq "two harvests in one second both succeed" "0" "$tag_rc"
assert_eq "with two restore tags of that second" \
    "swarm-harvest-2030-01-01-000000 swarm-harvest-2030-01-01-000000-2" \
    "$(git tag --list 'swarm-harvest-2030-*' | sort | tr '\n' ' ' \
        | sed 's/ $//')"

# ============================================================
echo ""
echo "=== 11. Behavioural: swarm harvest refuses legacy /tmp state ==="

LEGACY_PROJECT="swarmtest-harvest-legacy-$$"
LEGACY_WORK="$TMPDIR/$LEGACY_PROJECT"
LEGACY_BARE="/tmp/${LEGACY_PROJECT}-upstream.git"
use_runtime legacy
git init -q "$LEGACY_WORK"
git -C "$LEGACY_WORK" -c user.name=test -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m "init"
git clone -q --bare "$LEGACY_WORK" "$SWARM_RUNTIME_DIR/upstream.git"
record_base "$SWARM_RUNTIME_DIR/upstream.git"
mkdir -p "$LEGACY_BARE"

cd "$LEGACY_WORK"
legacy_rc=0
legacy_output=$(bash "$HARVEST_SH" --dry 2>&1) || legacy_rc=$?
assert_eq "legacy state stops harvest" "1" "$legacy_rc"
assert_eq "legacy message names the old path" "true" \
    "$(grep -qF "git fetch ${LEGACY_BARE}" <<< "$legacy_output" \
        && echo true || echo false)"
assert_eq "legacy state is left in place" "true" \
    "$([ -d "$LEGACY_BARE" ] && echo true || echo false)"
rm -rf "$LEGACY_BARE"

legacy_rc=0
bash "$HARVEST_SH" --dry >/dev/null 2>&1 || legacy_rc=$?
assert_eq "harvest runs once the old state is gone" "0" "$legacy_rc"

# ============================================================
echo ""
echo "=== 12. Behavioural: swarm harvest refuses an open runtime dir ==="

chmod 755 "$SWARM_RUNTIME_DIR"
open_rc=0
open_output=$(bash "$HARVEST_SH" --dry 2>&1) || open_rc=$?
assert_eq "group/world readable runtime stops harvest" "1" "$open_rc"
assert_eq "message names the mode fix" "true" \
    "$(grep -qF 'chmod 700' <<< "$open_output" \
        && echo true || echo false)"
chmod 700 "$SWARM_RUNTIME_DIR"

# ============================================================
echo ""
echo "=== 13. Behavioural: swarm harvest refuses another checkout's runtime ==="

# The runtime directory from section 11 now names another checkout.
jq -n --arg root "$TMPDIR/elsewhere/${LEGACY_PROJECT}" \
    '{schema: "swarm-core.state/v1", repo_root: $root}' \
    > "$SWARM_RUNTIME_DIR/state.json"
cd "$LEGACY_WORK"
owner_rc=0
owner_output=$(bash "$HARVEST_SH" --dry 2>&1) || owner_rc=$?
assert_eq "another checkout's runtime stops harvest" "1" "$owner_rc"
assert_eq "message names SWARM_PROJECT" "true" \
    "$(grep -q SWARM_PROJECT <<< "$owner_output" \
        && echo true || echo false)"
record_engagement

# ============================================================
echo ""
echo "=== 15. swarm harvest and swarm progress need jq ==="

# They read the JSON state file.  Run them with a PATH that has git
# and dirname but no jq.
_nojq_bin="$TMPDIR/nojq-bin"
mkdir -p "$_nojq_bin"
ln -s "$(command -v git)" "$_nojq_bin/git"
ln -s "$(command -v dirname)" "$_nojq_bin/dirname"
ln -s "$(command -v docker 2>/dev/null || command -v true)" \
    "$_nojq_bin/docker"
cd "$LEGACY_WORK"
for _tool in harvest progress; do
    nojq_rc=0
    nojq_out=$(PATH="$_nojq_bin" /bin/bash "$REPO_ROOT/libexec/$_tool" 2>&1) \
        || nojq_rc=$?
    assert_eq "${_tool} without jq fails" "1" "$nojq_rc"
    assert_eq "${_tool} names jq as missing" "true" \
        "$(grep -q 'Missing required tools: jq' <<< "$nojq_out" \
            && echo true || echo false)"
done

# ============================================================
echo ""
echo "=== 16. Behavioural: swarm harvest refuses foreign containers ==="

# swarm harvest runs docker exec and docker cp in interactive containers,
# so a container named for this project id has to be this checkout's.
cd "$INTERACTIVE_WORK"
for _fake_owner in /elsewhere/proj ""; do
    ctr_rc=0
    _fake_project="$INTERACTIVE_PROJECT"
    [ -n "$_fake_owner" ] || _fake_project=""
    ctr_out=$(PATH="$_fake_bin:$PATH" FAKE_OWNER="$_fake_owner" \
        FAKE_PROJECT="$_fake_project" \
        SWARM_RUNTIME_DIR="$TMPDIR/runtime-interactive" \
        bash "$HARVEST_SH" --dry 2>&1) || ctr_rc=$?
    assert_eq "container owned by '${_fake_owner:-nobody}' stops harvest" \
        "1" "$ctr_rc"
    assert_eq "message names the container (${_fake_owner:-nobody})" \
        "true" \
        "$(grep -qF "$_ctr_name" <<< "$ctr_out" \
            && echo true || echo false)"
done

# ============================================================
echo ""
echo "=== 17. Behavioural: swarm harvest with the Docker daemon down ==="

# The merge needs only git.  With Docker installed but its daemon down,
# harvest skips every container operation instead of failing.
DOWN_WORK="$TMPDIR/swarmtest-harvest-down-$$"
git init -q "$DOWN_WORK"
git -C "$DOWN_WORK" -c user.name=test -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m "init"
use_runtime down
git clone -q --bare "$DOWN_WORK" "$SWARM_RUNTIME_DIR/upstream.git"
record_base "$SWARM_RUNTIME_DIR/upstream.git"
git -C "$SWARM_RUNTIME_DIR/upstream.git" branch agent-work HEAD
cd "$DOWN_WORK"
: > "$_down_log"
down_rc=0
bash "$HARVEST_SH" --dry >/dev/null 2>&1 || down_rc=$?
assert_eq "harvest runs with the daemon down" "0" "$down_rc"
# check_deps asks for the version; harvest itself only asks whether the
# daemon is up.
assert_eq "no container operation is attempted" "" \
    "$(grep -vE '^(--version|info)( |$)' "$_down_log" || true)"

# ============================================================
echo ""
echo "=== 18. Behavioural: swarm progress with the Docker daemon down ==="

# swarm progress shows the commit history with git alone and reports the
# containers as unavailable.
cd "$DOWN_WORK"
progress_rc=0
progress_out=$(bash "$REPO_ROOT/libexec/progress" 2>&1) || progress_rc=$?
assert_eq "progress runs with the daemon down" "0" "$progress_rc"
assert_eq "progress shows the history" "true" \
    "$(grep -qF '=== Recent commits ===' <<< "$progress_out" \
        && echo true || echo false)"
assert_eq "progress reports Docker as unavailable" "true" \
    "$(grep -qF '(docker not available)' <<< "$progress_out" \
        && echo true || echo false)"
# The history comes from the bare repo's agent-work, read in place: no
# clone, nothing left in TMPDIR, and none of the bare repo's pager or
# signature settings, which agents can write, take effect.
_pb="$SWARM_RUNTIME_DIR/upstream.git"
_pb_commit=$(git --git-dir="$_pb" -c user.name=agent -c user.email=a@a \
    commit-tree -p refs/heads/agent-work -m "agent progress marker" \
    "refs/heads/agent-work^{tree}")
git --git-dir="$_pb" update-ref refs/heads/agent-work "$_pb_commit"
git --git-dir="$_pb" config core.pager "touch $TMPDIR/progress-pager-ran"
git --git-dir="$_pb" config log.showSignature true
git --git-dir="$_pb" config gpg.program "touch $TMPDIR/progress-gpg-ran"
_pb_tmp=$(mktemp -d)
progress_rc=0
progress_out=$(TMPDIR="$_pb_tmp" bash "$REPO_ROOT/libexec/progress" 2>&1) \
    || progress_rc=$?
assert_eq "progress shows agent-work's latest commit" "0 true" \
    "$progress_rc $(grep -qF 'agent progress marker' <<< "$progress_out" \
        && echo true || echo false)"
assert_eq "progress leaves nothing in TMPDIR" "" "$(ls -A "$_pb_tmp")"
assert_eq "progress runs no pager or gpg of the bare repo's" "false false" \
    "$([ -e "$TMPDIR/progress-pager-ran" ] && echo true || echo false) $(
        [ -e "$TMPDIR/progress-gpg-ran" ] && echo true || echo false)"
assert_eq "progress turns the pager off" "1" \
    "$(grep -c 'git --no-pager' "$REPO_ROOT/libexec/progress")"
rmdir "$_pb_tmp"
git --git-dir="$_pb" config --unset core.pager
git --git-dir="$_pb" config --unset log.showSignature
git --git-dir="$_pb" config --unset gpg.program
# Bash 3.2 (macOS's /bin/bash, which the script's shebang runs) gives an
# EXIT trap status 0 when set -u stops the script.  An echo that, through
# BASH_ENV, reads an unset variable when it prints the history's title
# (in the script's own shell, after the trap is set).
# The status /bin/bash gives an EXIT trap when set -u stops a script: 0
# on Bash 3.2 (the bug), where the trap must say why it ends with 1; 1 on
# later versions, where Bash's own status and error say it.
printf '%s\n' 'set -euo pipefail' "trap 'echo \"\$?\"' EXIT" \
    ': "$swarm_probe_unset"' > "$TMPDIR/stop-probe.sh"
_stop_status=$(/bin/bash "$TMPDIR/stop-probe.sh" 2>/dev/null || true)
_stop_says=0
[ "$_stop_status" = 0 ] && _stop_says=1
cat > "$TMPDIR/progress-stop-env.sh" <<'EOF'
echo() {
    if [ -n "${SWARM_TEST_STOP:-}" ] \
            && [ "${1:-}" = "=== Recent commits ===" ]; then
        : "$swarm_test_unset_variable"
    fi
    builtin echo "$@"
}
EOF
progress_rc=0
progress_out=$(BASH_ENV="$TMPDIR/progress-stop-env.sh" SWARM_TEST_STOP=1 \
    "$REPO_ROOT/libexec/progress" 2>&1) || progress_rc=$?
assert_eq "progress stopped on an unset variable ends with 1" "1" \
    "$progress_rc"
assert_eq "saying so where Bash 3.2 would end with 0" "$_stop_says" \
    "$(grep -c 'swarm progress stopped before the end of its run' \
        <<< "$progress_out")"
progress_rc=0
BASH_ENV="$TMPDIR/progress-stop-env.sh" "$REPO_ROOT/libexec/progress" \
    >/dev/null 2>&1 || progress_rc=$?
assert_eq "the same run without the stop ends with 0" "0" "$progress_rc"
# The check is made only on Bash before 4.1 (later versions end a run
# that set -u stops with a nonzero status themselves; every version runs
# the EXIT trap with $? at 0 when a signal ends the script).  The
# shared version test (lib/project.sh) and the script's trap, extracted;
# the trap runs in a child of each Bash the runner has, with the version
# test stubbed both ways.
_px_extract() {  # FUNCTION FILE
    awk -v f="$1" '$0 ~ "^" f "\\(\\)[[:space:]]*\\{" { p = 1 }
         p { print }
         p && /^\}[[:space:]]*$/ { exit }' "$2"
}
_px_extract swarm_stop_guard_needed "$REPO_ROOT/lib/project.sh" \
    > "$TMPDIR/progress-guard.sh"
_px_extract progress_exit_trap "$REPO_ROOT/libexec/progress" \
    > "$TMPDIR/progress-trap.sh"
_px_guard() {
    (
        # shellcheck source=/dev/null
        source "$TMPDIR/progress-guard.sh"
        if swarm_stop_guard_needed "$1" "$2"; then
            echo yes
        else
            echo no
        fi
    )
}
_px_guards="$(_px_guard 3 2) $(_px_guard 4 0) $(_px_guard 4 1)"
_px_guards="$_px_guards $(_px_guard 4 4) $(_px_guard 5 2) $(_px_guard 10 0)"
assert_eq "the check is made on Bash 3.2 and 4.0, not from 4.1 on" \
    "yes yes no no no no" "$_px_guards"
_px_bashes="/bin/bash"
_px_brew=""
if command -v brew >/dev/null 2>&1; then
    _px_brew="$(brew --prefix)/bin/bash"
fi
if [ -n "$_px_brew" ] && [ -x "$_px_brew" ]; then
    _px_bashes="$_px_bashes $_px_brew"
elif [ "$(uname)" = Darwin ]; then
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has the Homebrew bash" "yes" "no"
    else
        echo "  SKIP: no Homebrew bash, so only /bin/bash is checked"
    fi
fi
_px_run() {  # BASH NEEDED(0 yes, 1 no) END
    cat > "$TMPDIR/progress-trap-run.sh" <<EOF
set -euo pipefail
PROGRESS_EXIT_OK=false
# shellcheck source=/dev/null
source "$TMPDIR/progress-trap.sh"
swarm_stop_guard_needed() { return $2; }
trap progress_exit_trap EXIT
$3
EOF
    "$1" "$TMPDIR/progress-trap-run.sh" 2>&1
}
for _px_b in $_px_bashes; do
    _px_rc=0
    _px_out=$(_px_run "$_px_b" 0 ':') || _px_rc=$?
    assert_eq "$_px_b: no flag where the check is made: status 1" "1" \
        "$_px_rc"
    assert_eq "$_px_b:   saying so once" "1" \
        "$(grep -c 'swarm progress stopped before the end of its run' \
            <<< "$_px_out")"
    _px_rc=0
    _px_out=$(_px_run "$_px_b" 1 ':') || _px_rc=$?
    assert_eq "$_px_b: no flag where it is not: status 0" "0" "$_px_rc"
    assert_eq "$_px_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_px_out")"
    _px_rc=0
    _px_out=$(_px_run "$_px_b" 0 'PROGRESS_EXIT_OK=true') || _px_rc=$?
    assert_eq "$_px_b: the flag: status 0" "0" "$_px_rc"
    assert_eq "$_px_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_px_out")"
    _px_rc=0
    _px_out=$(_px_run "$_px_b" 0 'exit 3') || _px_rc=$?
    assert_eq "$_px_b: another status stays" "3" "$_px_rc"
    assert_eq "$_px_b:   with no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_px_out")"
done

# ============================================================
echo ""
echo "=== 19. Behavioural: swarm harvest checks the engagement ==="

record_engagement
cd "$DOWN_WORK"
eng_rc=0
SWARM_ENGAGEMENT_ID=eng-2 bash "$HARVEST_SH" --dry >/dev/null 2>&1 \
    || eng_rc=$?
assert_eq "harvest refuses another engagement" "1" "$eng_rc"
eng_rc=0
SWARM_ENGAGEMENT_ID=eng-1 bash "$HARVEST_SH" --dry >/dev/null 2>&1 \
    || eng_rc=$?
assert_eq "harvest joins the recorded engagement" "0" "$eng_rc"
record_engagement

# ============================================================
echo ""
echo "=== 20. Behavioural: swarm harvest takes the engagement lock ==="

cd "$DOWN_WORK"
exec 8>>"$SWARM_RUNTIME_DIR/engagement.lock"
flock -n 8
lock_rc=0
"$BASH" "$HARVEST_SH" --dry >/dev/null 2>&1 8>&- || lock_rc=$?
assert_eq "harvest fails while another operation holds the lock" "1" \
    "$lock_rc"
lock_rc=0
SWARM_LOCK_FD=8 "$BASH" "$HARVEST_SH" --dry >/dev/null 2>&1 || lock_rc=$?
assert_eq "harvest runs under the caller's lock (SWARM_LOCK_FD)" "0" \
    "$lock_rc"
exec 8>&-

# ============================================================
echo ""
echo "=== 21. Behavioural: swarm harvest and the engagement it was started for ==="

# An engagement an earlier release started (no Docker daemon recorded)
# is refused before the checkout is touched, with the way to finish it;
# the Docker daemon is down here, and the check needs only the state
# file.
cd "$DOWN_WORK"
jq -n '{schema: "swarm-core.state/v1", engagement_id: "eng-1"}' \
    > "$SWARM_RUNTIME_DIR/state.json"
refs_before=$(git for-each-ref)
old_rc=0
old_out=$(bash "$HARVEST_SH" 2>&1) || old_rc=$?
assert_eq "an earlier release's engagement: harvest refused" "1" "$old_rc"
assert_eq "saying how to finish it" "true" \
    "$(grep -qF 'Finish it with the release that made it' <<< "$old_out" \
        && echo true || echo false)"
assert_eq "the checkout's refs are as they were" "$refs_before" \
    "$(git for-each-ref)"
assert_eq "no harvest remote is left" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"
# A token names the engagement swarm harvest was started for.
record_engagement
tok_rc=0
tok_out=$(SWARM_ENGAGEMENT_TOKEN=t2 bash "$HARVEST_SH" --dry 2>&1) \
    || tok_rc=$?
assert_eq "another engagement's token: harvest refused" "1" "$tok_rc"
assert_eq "saying the engagement is gone" "true" \
    "$(grep -qF 'the engagement this command was started for is gone' \
        <<< "$tok_out" && echo true || echo false)"
tok_rc=0
SWARM_ENGAGEMENT_TOKEN=t1 bash "$HARVEST_SH" --dry >/dev/null 2>&1 \
    || tok_rc=$?
assert_eq "its own token: harvest runs" "0" "$tok_rc"
# This engine records the engagement before it makes the bare repo, so
# a bare repo with none recorded is an earlier release's too: with no
# state file, and with one that holds only the checkout's claim.
for _st in none claim; do
    case "$_st" in
        none) rm -f "$SWARM_RUNTIME_DIR/state.json" ;;
        claim)
            jq -n --arg r "$(cd -P "$DOWN_WORK" && pwd -P)" \
                '{schema: "swarm-core.state/v1", repo_root: $r}' \
                > "$SWARM_RUNTIME_DIR/state.json" ;;
    esac
    refs_before=$(git for-each-ref)
    un_rc=0
    un_out=$(bash "$HARVEST_SH" 2>&1) || un_rc=$?
    assert_eq "a bare repo, no engagement ($_st): harvest refused" "1" \
        "$un_rc"
    assert_eq "as an earlier release's ($_st)" "true" \
        "$(grep -qF 'Finish it with the release that made it' \
            <<< "$un_out" && echo true || echo false)"
    assert_eq "the checkout's refs are as they were ($_st)" \
        "$refs_before" "$(git for-each-ref)"
done
record_engagement

# ============================================================
echo ""
echo "=== 22. Behavioural: swarm harvest merges what is built on the base ==="

# The engagement starts at the checkout's HEAD, recorded as its base.
# Work built on that base merges even once HEAD moved on: local commits
# after the start (flow C), an interactive branch merged by an earlier
# harvest while the agents kept pushing (flow B).  A HEAD whose history
# no longer has the base (rewritten), a branch not built on it, and a
# state with no base refuse, and leave HEAD as it was.
BASE_WORK="$TMPDIR/swarmtest-harvest-base-$$"
use_runtime base
BASE_BARE="$SWARM_RUNTIME_DIR/upstream.git"
BASE_AGENT="$TMPDIR/harvest-base-agent"
bg() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
git init -q "$BASE_WORK"
# swarm harvest merges with plain git, so the checkout names who merges.
git -C "$BASE_WORK" config user.name test
git -C "$BASE_WORK" config user.email t@t
git -C "$BASE_WORK" config commit.gpgsign false
printf 'one\ntwo\nthree\n' > "$BASE_WORK/f"
bg -C "$BASE_WORK" add f
bg -C "$BASE_WORK" commit -qm start
git clone -q --bare "$BASE_WORK" "$BASE_BARE"
git -C "$BASE_BARE" branch agent-work HEAD
record_base "$BASE_BARE"
git clone -q "$BASE_BARE" "$BASE_AGENT"
git -C "$BASE_AGENT" checkout -q agent-work
# An agent commit on agent-work; FILE CONTENT MESSAGE.
agent_commit() {
    printf '%s\n' "$2" > "$BASE_AGENT/$1"
    bg -C "$BASE_AGENT" add "$1"
    bg -C "$BASE_AGENT" commit -qm "$3"
    git -C "$BASE_AGENT" push -q origin agent-work
}
cd "$BASE_WORK"
# Flow C: a local commit after the start, then agent work.
printf 'local\n' > "$BASE_WORK/local.txt"
bg add local.txt
bg commit -qm "local after start"
agent_commit a.txt a "agent one"
c_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || c_rc=$?
assert_eq "local commits after the start: harvest merges" "0" "$c_rc"
assert_eq "the agent's work is in HEAD" "true" \
    "$([ -f "$BASE_WORK/a.txt" ] && echo true || echo false)"
assert_eq "and so are the local commits" "true" \
    "$([ -f "$BASE_WORK/local.txt" ] && echo true || echo false)"
# Print true when the record of harvests lists commit C.
recorded() {
    jq -r --arg c "$1" '(.harvested // []) | index($c) != null' \
        "$SWARM_RUNTIME_DIR/state.json"
}
assert_eq "the merged tip is recorded" "true" \
    "$(recorded "$(git -C "$BASE_BARE" rev-parse agent-work)")"
# Flow B: an interactive branch merged by a harvest, then more agent
# work on agent-work, which does not have that merge.
git -C "$BASE_AGENT" checkout -q -b swarm/abc/interactive-x-1
printf 'mine\n' > "$BASE_AGENT/i.txt"
bg -C "$BASE_AGENT" add i.txt
bg -C "$BASE_AGENT" commit -qm "interactive work"
git -C "$BASE_AGENT" push -q origin HEAD:refs/heads/swarm/abc/interactive-x-1
git -C "$BASE_AGENT" checkout -q agent-work
bash "$HARVEST_SH" >/dev/null 2>&1
agent_commit b.txt b "agent two"
b_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || b_rc=$?
assert_eq "agents pushing after an interactive merge: harvest merges" \
    "0" "$b_rc"

assert_eq "the later agent work is in HEAD" "true" \
    "$([ -f "$BASE_WORK/b.txt" ] && [ -f "$BASE_WORK/i.txt" ] \
        && echo true || echo false)"
# A conflict stops the merge with the way out, and HEAD as it was.
printf 'one\nTWO local\nthree\n' > "$BASE_WORK/f"
bg commit -qam "local edit of f"
agent_commit f "one
TWO agent
three" "agent edit of f"
before=$(git rev-parse HEAD)
x_rc=0
x_out=$(bash "$HARVEST_SH" 2>&1) || x_rc=$?
assert_eq "a conflict: harvest stops" "1" "$x_rc"
assert_eq "saying how to finish or give up" "true" \
    "$(grep -qF 'Resolve the conflicts and commit, or give up with git merge --abort' \
        <<< "$x_out" && echo true || echo false)"
assert_eq "naming where HEAD was" "true" \
    "$(grep -qF "git reset --hard ${before:0:12}" <<< "$x_out" \
        && echo true || echo false)"
assert_eq "no harvest remote is left" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"
p_rc=0
p_out=$(bash "$HARVEST_SH" 2>&1) || p_rc=$?
assert_eq "a merge in progress: the next harvest refuses" "1" "$p_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "a merge is in progress" <<< "$p_out" \
        && echo true || echo false)"
git merge --abort
assert_eq "git merge --abort brings HEAD back" "$before" \
    "$(git rev-parse HEAD)"
# Given up, that merge is not taken for one HEAD dropped by mistake, nor
# for nothing: harvest refuses until --again says to merge it again.
bg -C "$BASE_AGENT" revert --no-edit HEAD >/dev/null
git -C "$BASE_AGENT" push -q origin agent-work
p_rc=0
p_out=$(bash "$HARVEST_SH" 2>&1) || p_rc=$?
assert_eq "a merge given up: harvest refuses" "1" "$p_rc"
assert_eq "naming --again" "true" \
    "$(grep -qF "harvest left to merge: that merge stopped" \
        <<< "$p_out" && grep -qF "swarm harvest --again" <<< "$p_out" \
        && echo true || echo false)"
p_rc=0
bash "$HARVEST_SH" --again >/dev/null 2>&1 || p_rc=$?
assert_eq "--again merges it" "0" "$p_rc"
# A conflict resolved by hand: the next harvest, with nothing new,
# records it, and a rebase that drops it later refuses.
agent_commit h.txt "agent h" "agent adds h"
bash "$HARVEST_SH" >/dev/null 2>&1
printf 'mine h\n' > h.txt
bg commit -qam "local edit of h"
agent_commit h.txt "agent h again" "agent edit of h"
bash "$HARVEST_SH" >/dev/null 2>&1 || true
printf 'resolved h\n' > h.txt
bg add h.txt
bg commit -qm "resolve h"
resolved=$(git rev-parse HEAD)
bash "$HARVEST_SH" >/dev/null 2>&1
assert_eq "a conflict resolved by hand is recorded" "true" \
    "$(recorded "$(git -C "$BASE_BARE" rev-parse agent-work)")"
git reset -q --hard HEAD~1
k_rc=0
k_out=$(bash "$HARVEST_SH" 2>&1) || k_rc=$?
assert_eq "the resolved merge dropped: refused" "1" "$k_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "HEAD no longer has what an earlier harvest merged" \
        <<< "$k_out" && echo true || echo false)"
git reset -q --hard "$resolved"
# An interactive branch gone from the bare repo is still kept: dropping
# its work from HEAD refuses.
git -C "$BASE_AGENT" checkout -q -b swarm/abc/interactive-y-1
printf 'gone\n' > "$BASE_AGENT/y.txt"
bg -C "$BASE_AGENT" add y.txt
bg -C "$BASE_AGENT" commit -qm "interactive work y"
git -C "$BASE_AGENT" push -q origin HEAD:refs/heads/swarm/abc/interactive-y-1
git -C "$BASE_AGENT" checkout -q agent-work
before_y=$(git rev-parse HEAD)
bash "$HARVEST_SH" >/dev/null 2>&1
after_y=$(git rev-parse HEAD)
git -C "$BASE_BARE" update-ref -d refs/heads/swarm/abc/interactive-y-1
git reset -q --hard "$before_y"
y_rc=0
y_out=$(bash "$HARVEST_SH" 2>&1) || y_rc=$?
assert_eq "a deleted branch's work dropped from HEAD: refused" "1" "$y_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "HEAD no longer has what an earlier harvest merged" \
        <<< "$y_out" && echo true || echo false)"
git reset -q --hard "$after_y"
# agent-work set back in the bare repo does not lower what HEAD must
# keep: the record stays at the later tip.
agent_commit z.txt z "agent z"
bash "$HARVEST_SH" >/dev/null 2>&1
later=$(git -C "$BASE_BARE" rev-parse agent-work)
git -C "$BASE_BARE" update-ref refs/heads/agent-work "$later~1"
bash "$HARVEST_SH" >/dev/null 2>&1
assert_eq "agent-work set back: the record keeps the later tip" "true" \
    "$(recorded "$later")"
assert_eq "and leaves out the earlier one, which the later one has" \
    "false" "$(recorded "$(git -C "$BASE_BARE" rev-parse agent-work)")"
git -C "$BASE_BARE" update-ref refs/heads/agent-work "$later"
git -C "$BASE_AGENT" fetch -q origin
git -C "$BASE_AGENT" reset -q --hard origin/agent-work
# A history rewritten after a harvest, dropping some of what it merged
# (the base is still there): refused, since merging again would bring
# that back; --again merges it on purpose.
agent_commit d.txt d "agent four"
bash "$HARVEST_SH" >/dev/null 2>&1
git reset -q --hard HEAD~1
printf 'own\n' > own.txt
bg add own.txt
bg commit -qm "own work instead"
agent_commit e.txt e "agent five"
before=$(git rev-parse HEAD)
w_rc=0
w_out=$(bash "$HARVEST_SH" 2>&1) || w_rc=$?
assert_eq "HEAD without what a harvest merged: refused" "1" "$w_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "HEAD no longer has what an earlier harvest merged" \
        <<< "$w_out" && echo true || echo false)"
assert_eq "and naming --again" "true" \
    "$(grep -qF "swarm harvest --again" <<< "$w_out" \
        && echo true || echo false)"
assert_eq "HEAD is as it was" "$before" "$(git rev-parse HEAD)"
w_rc=0
bash "$HARVEST_SH" --again >/dev/null 2>&1 || w_rc=$?
assert_eq "--again merges it" "0" "$w_rc"
assert_eq "the dropped work is back, on purpose" "true" \
    "$([ -f d.txt ] && [ -f e.txt ] && echo true || echo false)"
# Each merge is recorded before it starts: when that record cannot be
# written, nothing is merged.
agent_commit s.txt s "agent six"
before=$(git rev-parse HEAD)
cat > "$TMPDIR/mv-fails.sh" <<'EOF'
mv() {
    local last
    for last; do :; done
    case "$last" in
        */state.json) return 1 ;;
    esac
    command mv "$@"
}
EOF
s_rc=0
s_out=$(BASH_ENV="$TMPDIR/mv-fails.sh" bash "$HARVEST_SH" 2>&1) || s_rc=$?
assert_eq "the record cannot be written: harvest stops" "1" "$s_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "cannot record what was harvested" <<< "$s_out" \
        && grep -qF "agent-work not merged" <<< "$s_out" \
        && echo true || echo false)"
assert_eq "before merging anything" "$before" "$(git rev-parse HEAD)"
bash "$HARVEST_SH" >/dev/null 2>&1
# Harvest runs no hooks, so a test acts during its merges through this
# git, put first on PATH for swarm harvest alone: around a merge (the
# command after git's -c options), it runs the command HV_BEFORE_MERGE,
# the merge, then HV_AFTER_MERGE if the merge succeeded, as a post-merge
# hook would, with swarm harvest's pid in HV_PARENT.  It passes every
# command on as it was given.
_hv_bin="$TMPDIR/hv-bin"
mkdir -p "$_hv_bin"
cat > "$_hv_bin/git" <<'EOF'
#!/bin/bash
i=1
while [ "${!i:-}" = -c ]; do i=$((i + 2)); done
[ "${!i:-}" = merge ] || exec "$HV_REAL_GIT" "$@"
HV_PARENT=$PPID
export HV_PARENT
[ -z "${HV_BEFORE_MERGE:-}" ] || sh -c "$HV_BEFORE_MERGE"
rc=0
"$HV_REAL_GIT" "$@" || rc=$?
if [ "$rc" -eq 0 ] && [ -n "${HV_AFTER_MERGE:-}" ]; then
    sh -c "$HV_AFTER_MERGE"
fi
exit "$rc"
EOF
chmod +x "$_hv_bin/git"
HV_REAL_GIT=$(command -v git)
export HV_REAL_GIT
# A harvest killed after a merge, before its last record: that merge
# was recorded as pending, so dropping it is refused.
agent_commit k.txt k "agent seven"
before=$(git rev-parse HEAD)
k_rc=0
PATH="$_hv_bin:$PATH" HV_AFTER_MERGE='kill -9 "$HV_PARENT"' \
    bash "$HARVEST_SH" >/dev/null 2>&1 || k_rc=$?
assert_eq "a harvest killed after its merge" "137" "$k_rc"
assert_eq "the merge is in HEAD" "true" \
    "$([ -f k.txt ] && echo true || echo false)"
git reset -q --hard "$before"
k_rc=0
k_out=$(bash "$HARVEST_SH" 2>&1) || k_rc=$?
assert_eq "that merge dropped: refused" "1" "$k_rc"
assert_eq "naming --again" "true" \
    "$(grep -qF "harvest left to merge: that merge stopped" <<< "$k_out" \
        && grep -qF "swarm harvest --again" <<< "$k_out" \
        && echo true || echo false)"
k_rc=0
bash "$HARVEST_SH" --again >/dev/null 2>&1 || k_rc=$?
assert_eq "--again merges it" "0" "$k_rc"
assert_eq "and it is back" "true" \
    "$([ -f k.txt ] && echo true || echo false)"
# A Git config that leaves merges uncommitted (mergeOptions --no-commit
# on the branch) does not apply: harvest commits each merge.
agent_commit m.txt m "agent eight"
m_branch=$(git branch --show-current)
git config "branch.${m_branch}.mergeOptions" --no-commit
m_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || m_rc=$?
git config --unset "branch.${m_branch}.mergeOptions"
assert_eq "mergeOptions --no-commit: harvest still commits" "0" "$m_rc"
assert_eq "with no merge left in progress" "false" \
    "$(git rev-parse -q --verify MERGE_HEAD >/dev/null \
        && echo true || echo false)"
assert_eq "and the merged tip recorded" "true" \
    "$(recorded "$(git -C "$BASE_BARE" rev-parse agent-work)")"
# Whatever else leaves a merge uncommitted (here a git that adds
# --no-commit after harvest's own options), harvest stops there with
# the merge pending: given up, it is not taken again without --again.
agent_commit n.txt n "agent nine"
n_tip=$(git -C "$BASE_BARE" rev-parse agent-work)
n_git=$(command -v git)
mkdir -p "$TMPDIR/nocommit-bin"
cat > "$TMPDIR/nocommit-bin/git" <<EOF
#!/bin/bash
# The command follows the options harvest passes with -c.
i=1
while [ "\${!i:-}" = -c ]; do i=\$((i + 2)); done
j=\$((i + 1))
if [ "\${!i:-}" = merge ] && [ "\${!j:-}" != --abort ]; then
    exec "$n_git" "\$@" --no-commit
fi
exec "$n_git" "\$@"
EOF
chmod +x "$TMPDIR/nocommit-bin/git"
n_rc=0
n_out=$(PATH="$TMPDIR/nocommit-bin:$PATH" bash "$HARVEST_SH" 2>&1) \
    || n_rc=$?
assert_eq "a merge left uncommitted: harvest stops" "1" "$n_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "git left the merge of agent-work uncommitted" \
        <<< "$n_out" && echo true || echo false)"
assert_eq "its tip stays pending" "$n_tip" \
    "$(jq -r '.harvest_pending | join(" ")' \
        "$SWARM_RUNTIME_DIR/state.json")"
git merge --abort
n_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || n_rc=$?
assert_eq "that merge given up: refused" "1" "$n_rc"
n_rc=0
bash "$HARVEST_SH" --again >/dev/null 2>&1 || n_rc=$?
assert_eq "--again merges it" "0" "$n_rc"
assert_eq "and commits it" "true" \
    "$(git merge-base --is-ancestor "$n_tip" HEAD && echo true || echo false)"
# A tag in the checkout named like the remote's branch is what git
# would merge by that name: harvest refuses until it is gone.
agent_commit t.txt t "agent ten"
before=$(git rev-parse HEAD)
git tag "_agent-harvest/agent-work" "$(git -C "$BASE_BARE" rev-parse agent-work~1)"
t_rc=0
t_out=$(bash "$HARVEST_SH" 2>&1) || t_rc=$?
assert_eq "a tag named like the remote branch: refused" "1" "$t_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "_agent-harvest/agent-work also names a tag or a branch" \
        <<< "$t_out" && echo true || echo false)"
assert_eq "HEAD is as it was" "$before" "$(git rev-parse HEAD)"
git tag -d "_agent-harvest/agent-work" >/dev/null
t_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || t_rc=$?
assert_eq "the tag gone: harvest merges" "0" "$t_rc"
# Tags in the bare repo (agents can push them) stay there.
git -C "$BASE_AGENT" tag planted
git -C "$BASE_AGENT" push -q origin planted
agent_commit u.txt u "agent eleven"
bash "$HARVEST_SH" >/dev/null 2>&1
assert_eq "a tag pushed to the bare repo is not fetched" "false" \
    "$(git rev-parse -q --verify refs/tags/planted >/dev/null \
        && echo true || echo false)"
# A merge git does not start (a local file in the way): no conflict
# steps and no reset --hard, which would delete local changes.
agent_commit g.txt "agent g" "agent adds g"
printf 'mine\n' > g.txt
l_rc=0
l_out=$(bash "$HARVEST_SH" 2>&1) || l_rc=$?
assert_eq "a local file in the way: harvest stops" "1" "$l_rc"
assert_eq "saying git did not start the merge" "true" \
    "$(grep -qF "did not start merging agent-work" <<< "$l_out" \
        && echo true || echo false)"
assert_eq "without a reset --hard" "0" \
    "$(grep -c 'reset --hard' <<< "$l_out" || true)"
assert_eq "the local file is still there" "mine" "$(cat g.txt)"
rm -f g.txt
l_rc=0
bash "$HARVEST_SH" >/dev/null 2>&1 || l_rc=$?
assert_eq "once it is out of the way, harvest merges" "0" "$l_rc"
# HEAD rewritten past the base: refused, HEAD untouched.
agent_commit c.txt c "agent three"
base_branch=$(git branch --show-current)
git checkout -q --orphan rewritten
bg commit -qm "a new history"
before=$(git rev-parse HEAD)
r_rc=0
r_out=$(bash "$HARVEST_SH" 2>&1) || r_rc=$?
assert_eq "HEAD's history without the base: refused" "1" "$r_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "HEAD's history no longer has the commit this" \
        <<< "$r_out" && echo true || echo false)"
assert_eq "with no rm -rf" "0" "$(grep -c 'rm -rf' <<< "$r_out" || true)"
assert_eq "HEAD is as it was" "$before" "$(git rev-parse HEAD)"
assert_eq "no harvest remote is left" "" \
    "$(git remote | grep -E '^_agent-harvest$' || true)"
git checkout -q "$base_branch"
# A branch that is not built on the base: refused.
git -C "$BASE_AGENT" checkout -q --orphan other
bg -C "$BASE_AGENT" commit -qm "unrelated"
git -C "$BASE_AGENT" push -q -f origin other:agent-work
o_rc=0
o_out=$(bash "$HARVEST_SH" 2>&1) || o_rc=$?
assert_eq "a branch not built on the base: refused" "1" "$o_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "is not built on the commit this" <<< "$o_out" \
        && echo true || echo false)"
# A state with no base: refused before anything is fetched.
ENGAGEMENT_BASE=""
record_engagement
n_rc=0
n_out=$(bash "$HARVEST_SH" --dry 2>&1) || n_rc=$?
assert_eq "no base recorded: refused" "1" "$n_rc"
assert_eq "saying so" "true" \
    "$(grep -qF "records no base commit" <<< "$n_out" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 23. Behavioural: --again merges again what no branch brings back ==="

# An earlier harvest merged agent work and was undone (git reset --hard
# to its restore tag); then the bare repo stopped bringing that work
# back: agent-work moved back, an interactive branch was deleted.
# Without --again, harvest refuses; with it, what the record holds is
# merged by id from this checkout, and recorded.  A recorded commit the
# checkout does not have refuses and stays recorded; a harvest --again
# stopped half way keeps what it has not merged in the record.
AG_WORK="$TMPDIR/swarmtest-harvest-again-$$"
use_runtime restore
AG_BARE="$SWARM_RUNTIME_DIR/upstream.git"
AG_AGENT="$TMPDIR/harvest-again-agent"
ag() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
git init -q "$AG_WORK"
git -C "$AG_WORK" config user.name test
git -C "$AG_WORK" config user.email t@t
git -C "$AG_WORK" config commit.gpgsign false
printf 'one\n' > "$AG_WORK/f"
ag -C "$AG_WORK" add f
ag -C "$AG_WORK" commit -qm start
git clone -q --bare "$AG_WORK" "$AG_BARE"
git -C "$AG_BARE" branch agent-work HEAD
record_base "$AG_BARE"
AG_BASE=$(git -C "$AG_BARE" rev-parse HEAD)
git clone -q "$AG_BARE" "$AG_AGENT"
git -C "$AG_AGENT" checkout -q agent-work
# Commit FILE CONTENT on BRANCH of the agent's clone and push it; print
# the commit.
ag_commit() {
    git -C "$AG_AGENT" checkout -q "$1" 2>/dev/null \
        || git -C "$AG_AGENT" checkout -q -b "$1" "$AG_BASE"
    printf '%s\n' "$3" > "$AG_AGENT/$2"
    ag -C "$AG_AGENT" add "$2"
    ag -C "$AG_AGENT" commit -qm "$2"
    git -C "$AG_AGENT" push -q origin "$1"
    git -C "$AG_AGENT" rev-parse HEAD
}
# Run swarm harvest ARGS in the checkout; print its status.
ag_harvest() {
    local rc=0
    (cd "$AG_WORK" && bash "$HARVEST_SH" "$@" > "$TMPDIR/ag.out" 2>&1) \
        || rc=$?
    printf '%s' "$rc"
}
ag_in_head() {
    git -C "$AG_WORK" merge-base --is-ancestor "$1" HEAD 2>/dev/null \
        && echo yes || echo no
}
ag_state() {  # JQ-FILTER ARGS...: change the state file.
    local f="$SWARM_RUNTIME_DIR/state.json"
    jq "$@" "$f" > "$f.x" && mv "$f.x" "$f" && chmod 600 "$f"
}
ag_field() {  # FIELD COMMIT: true when the record's FIELD lists COMMIT.
    jq -r --arg f "$1" --arg c "$2" '(.[$f] // []) | index($c) != null' \
        "$SWARM_RUNTIME_DIR/state.json"
}
# agent-work, harvested, undone, then moved back in the bare repo.
AG_A=$(ag_commit agent-work a.txt a)
assert_eq "agent-work harvested" "0 yes" "$(ag_harvest) $(ag_in_head "$AG_A")"
git -C "$AG_WORK" reset -q --hard \
    "$(git -C "$AG_WORK" tag --list 'swarm-harvest-*' | tail -1)"
git -C "$AG_BARE" update-ref refs/heads/agent-work "$AG_BASE"
assert_eq "undone and agent-work moved back: harvest refuses" "1 no" \
    "$(ag_harvest) $(ag_in_head "$AG_A")"
assert_eq "--again merges the recorded commit by id" "0 yes" \
    "$(ag_harvest --again) $(ag_in_head "$AG_A")"
assert_eq "and keeps it recorded" "true" "$(ag_field harvested "$AG_A")"
assert_eq "a harvest after that has nothing to refuse" "0" "$(ag_harvest)"
# An interactive branch, harvested, undone, then deleted.
AG_I=$(ag_commit swarm/again/interactive-x-1 i.txt i)
assert_eq "the interactive branch harvested" "0 yes" \
    "$(ag_harvest) $(ag_in_head "$AG_I")"
git -C "$AG_WORK" reset -q --hard \
    "$(git -C "$AG_WORK" tag --list 'swarm-harvest-*' | tail -1)"
git -C "$AG_BARE" update-ref -d refs/heads/swarm/again/interactive-x-1
assert_eq "undone and the branch deleted: --again brings it back" "0 yes" \
    "$(ag_harvest --again) $(ag_in_head "$AG_I")"
# A recorded commit this checkout does not have: refused, still recorded.
AG_GONE=$(printf '%040d' 7)
ag_state --arg c "$AG_GONE" '.harvested += [$c]'
assert_eq "--again with a recorded commit no one has: refused" "1" \
    "$(ag_harvest --again)"
assert_eq "naming it" "1" \
    "$(grep -c "cannot merge ${AG_GONE:0:12}" "$TMPDIR/ag.out" || true)"
assert_eq "and leaving it recorded" "true" "$(ag_field harvested "$AG_GONE")"
ag_state --arg c "$AG_GONE" '.harvested -= [$c]'
# Two recorded commits, neither in the other's history, both gone from
# the bare repo, the agent-work one in conflict with HEAD: --again stops
# on that conflict and keeps whatever it has not merged in the record;
# once the conflict is resolved, --again finishes.
AG_B=$(ag_commit agent-work f two)
AG_J=$(ag_commit swarm/again/interactive-y-1 j.txt j)
assert_eq "both harvested" "0 yes yes" \
    "$(ag_harvest) $(ag_in_head "$AG_B") $(ag_in_head "$AG_J")"
git -C "$AG_WORK" reset -q --hard \
    "$(git -C "$AG_WORK" tag --list 'swarm-harvest-*' | tail -1)"
git -C "$AG_BARE" update-ref refs/heads/agent-work "$AG_A"
git -C "$AG_BARE" update-ref -d refs/heads/swarm/again/interactive-y-1
printf 'local\n' > "$AG_WORK/f"
ag -C "$AG_WORK" commit -qam "local change to f"
assert_eq "--again stops on the conflict" "1" "$(ag_harvest --again)"
assert_eq "what it has not merged stays in the record" "true true" \
    "$(ag_field harvest_pending "$AG_B") $( [ "$(ag_in_head "$AG_J")" = yes ] \
        && ag_field harvested "$AG_J" || ag_field harvest_pending "$AG_J")"
printf 'merged\n' > "$AG_WORK/f"
ag -C "$AG_WORK" add f
ag -C "$AG_WORK" commit -qm "Resolve the conflict"
assert_eq "once resolved, --again finishes" "0 yes yes" \
    "$(ag_harvest --again) $(ag_in_head "$AG_B") $(ag_in_head "$AG_J")"
assert_eq "with nothing left pending" "[]" \
    "$(jq -c '.harvest_pending // []' "$SWARM_RUNTIME_DIR/state.json")"
# While --again merges the first of two recorded commits, the record
# keeps the second (a harvest killed during that merge loses neither):
# the git on _hv_bin copies the state as the first merge starts.
AG_K=$(ag_commit swarm/again/interactive-k-1 k.txt k)
AG_L=$(ag_commit swarm/again/interactive-l-1 l.txt l)
assert_eq "two more harvested" "0 yes yes" \
    "$(ag_harvest) $(ag_in_head "$AG_K") $(ag_in_head "$AG_L")"
git -C "$AG_WORK" reset -q --hard \
    "$(git -C "$AG_WORK" tag --list 'swarm-harvest-*' | tail -1)"
git -C "$AG_BARE" update-ref -d refs/heads/swarm/again/interactive-k-1
git -C "$AG_BARE" update-ref -d refs/heads/swarm/again/interactive-l-1
assert_eq "--again merges both" "0 yes yes" \
    "$(PATH="$_hv_bin:$PATH" HV_SRC="$SWARM_RUNTIME_DIR/state.json" \
        HV_DST="$TMPDIR/ag-during.json" \
        HV_BEFORE_MERGE='[ -e "$HV_DST" ] || cp "$HV_SRC" "$HV_DST"' \
        ag_harvest --again) $(ag_in_head "$AG_K") $(ag_in_head "$AG_L")"
assert_eq "during the first merge, both were in the record" "true true" \
    "$(jq -r --arg k "$AG_K" --arg l "$AG_L" '
        [((.harvested // []) + (.harvest_pending // [])) | index($k),
         index($l)] | map(. != null) | map(tostring) | join(" ")' \
        "$TMPDIR/ag-during.json" 2>/dev/null)"
# A harvest stopped on a conflict, the merge given up and the branch
# deleted: the commit is only pending in the record, and --again merges
# it by id.
AG_P=$(ag_commit swarm/again/interactive-p-1 f pee)
assert_eq "a harvest that stops on a conflict" "1" "$(ag_harvest)"
git -C "$AG_WORK" merge --abort
git -C "$AG_BARE" update-ref -d refs/heads/swarm/again/interactive-p-1
assert_eq "its commit only pending" "true false" \
    "$(ag_field harvest_pending "$AG_P") $(ag_field harvested "$AG_P")"
assert_eq "a plain harvest refuses" "1" "$(ag_harvest)"
assert_eq "--again shows it as recorded" "1" \
    "$(ag_harvest --again --dry >/dev/null; grep -c \
        "from ${AG_P:0:12}, which an earlier harvest recorded" \
        "$TMPDIR/ag.out" || true)"
printf 'p merged\n' > "$TMPDIR/ag-f"
assert_eq "--again merges it, stopping on the same conflict" "1" \
    "$(ag_harvest --again)"
cp "$TMPDIR/ag-f" "$AG_WORK/f"
ag -C "$AG_WORK" add f
ag -C "$AG_WORK" commit -qm "Resolve the conflict again"
assert_eq "resolved: in HEAD, and recorded as harvested" "yes true" \
    "$(ag_in_head "$AG_P") $( (cd "$AG_WORK" && bash "$HARVEST_SH" \
        >/dev/null 2>&1); ag_field harvested "$AG_P")"
# A recorded commit not built on the engagement's base: refused.
AG_ORPHAN=$(ag -C "$AG_WORK" commit-tree -m orphan \
    "$(git -C "$AG_WORK" mktree < /dev/null)")
ag_state --arg c "$AG_ORPHAN" '.harvested += [$c]'
assert_eq "--again with a recorded commit off the base: refused" "1" \
    "$(ag_harvest --again)"
assert_eq "saying why" "1" \
    "$(grep -c 'not built on the commit this engagement started from' \
        "$TMPDIR/ag.out" || true)"
ag_state --arg c "$AG_ORPHAN" '.harvested -= [$c]'
# Undone with agent-work still bringing the recorded commit back:
# --again merges the branch, and does not list that commit on its own.
AG_C=$(ag_commit agent-work c.txt c)
assert_eq "agent-work harvested once more" "0 yes" \
    "$(ag_harvest) $(ag_in_head "$AG_C")"
git -C "$AG_WORK" reset -q --hard \
    "$(git -C "$AG_WORK" tag --list 'swarm-harvest-*' | tail -1)"
assert_eq "undone, the branch still there: --again merges it" "0 yes" \
    "$(ag_harvest --again) $(ag_in_head "$AG_C")"
assert_eq "through the branch, not by id" "1 0" \
    "$(grep -c '^--- Merging agent-work ---$' "$TMPDIR/ag.out" || true) $(
        grep -c 'no branch brings back' "$TMPDIR/ag.out" || true)"

echo ""
echo "=== 24. Behavioural: swarm harvest runs no hook or fsmonitor command ==="

# Harvest puts the agents' files in the checkout.  With core.hooksPath
# at a directory of it (as husky sets it), a hook the Git config defines
# running a file of it (Git 2.54 and later), or core.fsmonitor naming
# one, Git would run what an agent's branch wrote, here on the host.
# The agent's branch adds a hook for every event, the script the
# configured hooks run and the fsmonitor command.  Harvest runs none of
# them: on a fast-forward; with them on disk, on a dry run, and on a
# real merge with local changes (Git asks the submodule's status then)
# and the caller's settings turning them back on; on a merge a conflict
# stops.  A plain git command in the checkout runs them afterwards, so
# they were there to run.  A hook name -c cannot pass, and a config
# harvest cannot read, refuse.
HK_WORK="$TMPDIR/swarmtest-harvest-hooks-$$"
use_runtime hooks
HK_BARE="$SWARM_RUNTIME_DIR/upstream.git"
HK_AGENT="$TMPDIR/harvest-hooks-agent"
HK_RAN="$TMPDIR/hooks-ran"
hk() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
# Every event githooks(5) lists (Git 2.56).
HK_EVENTS="applypatch-msg pre-applypatch post-applypatch pre-commit
pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase
post-checkout post-merge pre-push pre-receive update proc-receive
post-receive post-update reference-transaction push-to-checkout
pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman
p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit
post-index-change"
git init -q "$HK_WORK"
git -C "$HK_WORK" config user.name test
git -C "$HK_WORK" config user.email t@t
git -C "$HK_WORK" config commit.gpgsign false
mkdir "$HK_WORK/.githooks"
printf 'hooks\n' > "$HK_WORK/.githooks/README"
printf 'one\n' > "$HK_WORK/f"
printf 'mine\n' > "$HK_WORK/dirty.txt"
hk -C "$HK_WORK" add .githooks f dirty.txt
hk -C "$HK_WORK" commit -qm start
# A submodule checked out, whose own hooks directory has a hook for
# every event, each running the checkout's .githooks/configured.
git init -q "$TMPDIR/hk-subsrc"
printf 'sub\n' > "$TMPDIR/hk-subsrc/s"
hk -C "$TMPDIR/hk-subsrc" add s
hk -C "$TMPDIR/hk-subsrc" commit -qm sub
hk -C "$HK_WORK" -c protocol.file.allow=always submodule --quiet add \
    "$TMPDIR/hk-subsrc" sub
hk -C "$HK_WORK" commit -qm "a submodule"
for _hk_ev in $HK_EVENTS; do
    printf '#!/bin/sh\ntest ! -x ../.githooks/configured || ../.githooks/configured subfile\n' \
        > "$HK_WORK/.git/modules/sub/hooks/$_hk_ev"
    chmod +x "$HK_WORK/.git/modules/sub/hooks/$_hk_ev"
done
git clone -q --bare "$HK_WORK" "$HK_BARE"
git -C "$HK_BARE" branch agent-work HEAD
record_base "$HK_BARE"
git clone -q "$HK_BARE" "$HK_AGENT"
git -C "$HK_AGENT" checkout -q agent-work
for _hk_ev in $HK_EVENTS; do
    printf '#!/bin/sh\necho %s >> "%s"\n' "$_hk_ev" "$HK_RAN" \
        > "$HK_AGENT/.githooks/$_hk_ev"
    chmod +x "$HK_AGENT/.githooks/$_hk_ev"
done
printf '#!/bin/sh\necho "configured $1" >> "%s"\n' "$HK_RAN" \
    > "$HK_AGENT/.githooks/configured"
chmod +x "$HK_AGENT/.githooks/configured"
printf 'agent\n' > "$HK_AGENT/a.txt"
hk -C "$HK_AGENT" add a.txt .githooks
hk -C "$HK_AGENT" commit -qm "agent work, and hooks"
git -C "$HK_AGENT" push -q origin agent-work
git -C "$HK_WORK" config core.hooksPath .githooks
git -C "$HK_WORK" config core.fsmonitor .githooks/fsmonitor-watchman
# Hooks the config defines, with names harvest must take as they are
# (empty, with spaces, quotes, a backslash, a byte that is not UTF-8,
# two that differ in case only): hook N runs the checkout's
# .githooks/configured cN once it is there.  The one named "" sits in a
# file the config includes, so that a test below can take it away; the
# last comes from a file the config includes once a remote's URL ends
# in upstream.git, as harvest's own does.
# Print the config lines that define hook NAME, as hook N (in a quoted
# subsection, a backslash and a double quote take a backslash).
hk_hook_cfg() {
    local ev name="$1"
    name=${name//\\/\\\\}
    name=${name//\"/\\\"}
    printf '[hook "%s"]\n\tcommand = test ! -x .githooks/configured || .githooks/configured c%s\n' \
        "$name" "$2"
    for ev in $HK_EVENTS; do
        printf '\tevent = %s\n' "$ev"
    done
}
_hk_n=0
for _hk_name in Hk-Configured hk.dotted 'hk "odd" name' 'hk\back' '' \
        ' lead' 'trail ' "$(printf 'hk\377byte')" HkCase hkcase; do
    _hk_n=$((_hk_n + 1))
    if [ -z "$_hk_name" ]; then
        hk_hook_cfg "$_hk_name" "$_hk_n" > "$TMPDIR/hk-empty.cfg"
    else
        hk_hook_cfg "$_hk_name" "$_hk_n" >> "$HK_WORK/.git/config"
    fi
done
: > "$TMPDIR/hk-nosub.cfg"
printf '[include]\n\tpath = %s\n\tpath = %s\n' "$TMPDIR/hk-empty.cfg" \
    "$TMPDIR/hk-nosub.cfg" >> "$HK_WORK/.git/config"
_hk_n=$((_hk_n + 1))
HK_HOOKS=$_hk_n
hk_hook_cfg hk-remote "$_hk_n" > "$TMPDIR/hk-remote-hooks.cfg"
printf '[includeIf "hasconfig:remote.*.url:**/upstream.git"]\n\tpath = %s\n' \
    "$TMPDIR/hk-remote-hooks.cfg" >> "$HK_WORK/.git/config"
# Run swarm harvest ARGS in the checkout, with what ran (one name per line
# in HK_RAN) cleared first, TMPDIR set to HK_HARVEST_TMPDIR and the
# shell options of HK_HARVEST_BASHOPTS on, if set; print its status.
hk_harvest() {
    local rc=0 out="$TMPDIR/hk.out" tmp="${HK_HARVEST_TMPDIR:-$TMPDIR}"
    : > "$HK_RAN"
    (cd "$HK_WORK" && env \
        ${HK_HARVEST_BASHOPTS:+"BASHOPTS=$HK_HARVEST_BASHOPTS"} \
        TMPDIR="$tmp" bash "$HARVEST_SH" "$@" > "$out" 2>&1) || rc=$?
    printf '%s' "$rc"
}
hk_ran() {
    tr '\n' ' ' < "$HK_RAN" | sed 's/ $//'
}
# Print true when the output of the last harvest has STRING.
hk_says() {
    grep -qF -- "$1" "$TMPDIR/hk.out" && echo true || echo false
}
assert_eq "a branch that adds hooks: harvest fast-forwards to it" \
    "0 $(git -C "$HK_AGENT" rev-parse HEAD)" \
    "$(hk_harvest) $(git -C "$HK_WORK" rev-parse HEAD)"
assert_eq "which puts them in the checkout" "true" \
    "$([ -x "$HK_WORK/.githooks/post-merge" ] \
        && [ -x "$HK_WORK/.githooks/configured" ] && echo true || echo false)"
assert_eq "and runs none of them" "" "$(hk_ran)"
# Plain git commands in the checkout now run them; their output goes.
printf 'local\n' > "$HK_WORK/local.txt"
hk -C "$HK_WORK" add local.txt 2>/dev/null
hk -C "$HK_WORK" commit -qm "local after start" 2>/dev/null
printf 'more\n' > "$HK_AGENT/b.txt"
hk -C "$HK_AGENT" add b.txt
hk -C "$HK_AGENT" commit -qm "more agent work"
git -C "$HK_AGENT" push -q origin agent-work
# A harvest cut short leaves its remote, which the next one removes
# first; this dry run has no directory for temporary files either (in
# which /bin/bash 3.2 would put a here-string).
git -C "$HK_WORK" remote add _agent-harvest "$HK_BARE" 2>/dev/null
git -C "$HK_WORK" update-ref refs/remotes/_agent-harvest/agent-work HEAD \
    2>/dev/null
assert_eq "with them on disk, a dry run" "0|" \
    "$(HK_HARVEST_TMPDIR="$TMPDIR/hk-no-such-dir" hk_harvest --dry)|$(hk_ran)"
# A real merge with local changes, stashed around it (merge.autoStash),
# and a file of the submodule that looks changed, so that the
# submodule's status writes its index.  The caller's Git config turns
# the hooks back on, GIT_CONFIG points git config elsewhere, GIT_DIR
# names the checkout's, the locale is UTF-8, and its Bash matches case
# patterns ignoring case (nocasematch, Bash 4.1 and later).
git -C "$HK_WORK" config merge.autoStash true
printf 'mine, changed\n' > "$HK_WORK/dirty.txt"
touch "$HK_WORK/sub/s"
hk_rc=$(HK_HARVEST_BASHOPTS=nocasematch LC_ALL=C.UTF-8 GIT_CONFIG=/dev/null \
    GIT_DIR="$HK_WORK/.git" \
    GIT_CONFIG_PARAMETERS="'core.hooksPath=.githooks' 'hook.Hk-Configured.enabled=true' 'core.fsmonitor=.githooks/fsmonitor-watchman'" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.hk.dotted.enabled \
    GIT_CONFIG_VALUE_0=true hk_harvest)
assert_eq "a real merge with local changes, the caller turning them on" \
    "0 3" "$hk_rc $(git -C "$HK_WORK" rev-list --no-walk --parents HEAD \
        | wc -w | tr -d ' ')"
assert_eq "local changes kept" "true|mine, changed" \
    "$([ -f "$HK_WORK/b.txt" ] && echo true || echo false)|$(
        cat "$HK_WORK/dirty.txt")"
assert_eq "runs none of them" "" "$(hk_ran)"
git -C "$HK_WORK" config --unset merge.autoStash
git -C "$HK_WORK" checkout -q -- dirty.txt 2>/dev/null
# A conflict stops the merge.
printf 'two, here\n' > "$HK_WORK/f"
hk -C "$HK_WORK" commit -qam "f here" 2>/dev/null
printf 'two, there\n' > "$HK_AGENT/f"
hk -C "$HK_AGENT" commit -qam "f there"
git -C "$HK_AGENT" push -q origin agent-work
assert_eq "a merge a conflict stops" "1 true" \
    "$(hk_harvest) $(hk_says "merging agent-work stopped")"
assert_eq "runs none of them either" "" "$(hk_ran)"
git -C "$HK_WORK" merge --abort 2>/dev/null
# Does this Git run hooks the config defines (Git 2.54 and later)?
git init -q "$TMPDIR/hk-probe"
hk -C "$TMPDIR/hk-probe" -c hook.hkprobe.event=pre-commit \
    -c "hook.hkprobe.command=touch '$TMPDIR/hk-probe-ran'" \
    commit -q --allow-empty -m probe
hk_configured=$([ -e "$TMPDIR/hk-probe-ran" ] && echo true || echo false)
: > "$HK_RAN"
git -C "$HK_WORK" remote add hk-probe "$HK_BARE" 2>/dev/null
hk -C "$HK_WORK" tag hk-probe 2>/dev/null
touch "$HK_WORK/sub/s"
git -C "$HK_WORK" status --porcelain >/dev/null 2>&1
git -C "$HK_WORK" remote remove hk-probe 2>/dev/null
assert_eq "a plain git command runs the hooks, the fsmonitor command, and the submodule's" \
    "true true true" "$(grep -qx reference-transaction "$HK_RAN" \
        && echo true || echo false) $(grep -qx fsmonitor-watchman "$HK_RAN" \
        && echo true || echo false) $(grep -qx "configured subfile" "$HK_RAN" \
        && echo true || echo false)"
assert_eq "and each configured hook, on a Git that has them" \
    "$(for _hk_c in $(seq 1 "$HK_HOOKS"); do echo "$hk_configured"; done \
        | tr '\n' ' ' | sed 's/ $//')" \
    "$(for _hk_c in $(seq 1 "$HK_HOOKS"); do grep -qx "configured c${_hk_c}" \
        "$HK_RAN" && echo true || echo false; done | tr '\n' ' ' \
        | sed 's/ $//')"
# A hook defined with no subsection ([hook] command): Git 2.54 runs it
# as the hook named "", later ones not at all.  Alone here, with no hook
# named "" whose disable would cover it.
git init -q "$TMPDIR/hk-nosub-probe"
printf '[hook]\n\tcommand = touch %s\n\tevent = pre-commit\n' \
    "$TMPDIR/hk-nosub-ran" >> "$TMPDIR/hk-nosub-probe/.git/config"
hk -C "$TMPDIR/hk-nosub-probe" commit -q --allow-empty -m probe 2>/dev/null
hk_nosub=$([ -e "$TMPDIR/hk-nosub-ran" ] && echo true || echo false)
cp "$TMPDIR/hk-empty.cfg" "$TMPDIR/hk-empty.keep"
: > "$TMPDIR/hk-empty.cfg"
{
    printf '[hook]\n\tcommand = test ! -x .githooks/configured || .githooks/configured nosub\n'
    for _hk_ev in $HK_EVENTS; do
        printf '\tevent = %s\n' "$_hk_ev"
    done
} > "$TMPDIR/hk-nosub.cfg"
assert_eq "a hook defined with no subsection: harvest runs it not" "" \
    "$(hk_harvest > /dev/null; hk_ran)"
: > "$HK_RAN"
hk -C "$HK_WORK" tag hk-probe-nosub 2>/dev/null
assert_eq "a plain git command runs it, on a Git that does" "$hk_nosub" \
    "$(grep -qx 'configured nosub' "$HK_RAN" && echo true || echo false)"
: > "$TMPDIR/hk-nosub.cfg"
cp "$TMPDIR/hk-empty.keep" "$TMPDIR/hk-empty.cfg"
# A configured hook whose name -c cannot pass: harvest refuses before it
# runs any git that could start a hook.
git -C "$HK_WORK" config 'hook.hk=odd.command' true
git -C "$HK_WORK" config 'hook.hk=odd.event' post-merge
assert_eq "a hook named with \"=\": refused" "1 true" \
    "$(hk_harvest) $(hk_says "cannot turn off the Git hook hook.hk=odd")"
git -C "$HK_WORK" config --unset 'hook.hk=odd.command'
git -C "$HK_WORK" config --unset 'hook.hk=odd.event'
# A hook named with "=" that the config includes only once harvest adds
# its remote (Git 2.36 and later read that condition): harvest refuses
# then, and takes its remote away running nothing, from the checkout's
# config though GIT_CONFIG names another file.
git init -q "$TMPDIR/hk-cond"
printf '[hk]\n\tseen = yes\n' > "$TMPDIR/hk-cond.cfg"
printf '[includeIf "hasconfig:remote.*.url:**/hk-cond-remote"]\n\tpath = %s\n' \
    "$TMPDIR/hk-cond.cfg" >> "$TMPDIR/hk-cond/.git/config"
git -C "$TMPDIR/hk-cond" remote add r "$TMPDIR/hk-cond-remote"
if [ "$(git -C "$TMPDIR/hk-cond" config hk.seen 2>/dev/null)" = yes ]; then
    cp "$TMPDIR/hk-remote-hooks.cfg" "$TMPDIR/hk-remote-hooks.keep"
    printf '[hook "hk=remote"]\n\tcommand = true\n\tevent = post-merge\n' \
        >> "$TMPDIR/hk-remote-hooks.cfg"
    assert_eq "a hook named with \"=\" once harvest adds its remote: refused" \
        "1 true" \
        "$(GIT_CONFIG=/dev/null hk_harvest) $(
            hk_says "cannot turn off the Git hook hook.hk=remote")"
    assert_eq "its remote gone, and nothing run" "|" \
        "$(git -C "$HK_WORK" remote)|$(hk_ran)"
    cp "$TMPDIR/hk-remote-hooks.keep" "$TMPDIR/hk-remote-hooks.cfg"
else
    echo "  SKIP: this Git reads no hasconfig:remote.*.url condition"
fi
# The bare repo, as an agent can set it up: a partial clone of a
# promisor that has an object an agent-work commit needs and the bare
# repo lacks, a refspec for that object, and a reference-transaction
# hook.  A fetch whose upload-pack fetched that object (as one does
# with a caller's GIT_NO_LAZY_FETCH=0) would run the hook; harvest's
# fetch fails instead, running nothing.
printf 'lazy\n' > "$HK_AGENT/l.txt"
hk -C "$HK_AGENT" add l.txt
hk -C "$HK_AGENT" commit -qm "a blob the bare repo will lack"
git -C "$HK_AGENT" push -q origin agent-work
HK_LAZY=$(git -C "$HK_AGENT" rev-parse HEAD:l.txt)
git clone -q --bare "$HK_AGENT" "$TMPDIR/hk-promisor.git"
rm -f "$HK_BARE/objects/${HK_LAZY:0:2}/${HK_LAZY:2}"
git -C "$HK_BARE" config core.repositoryformatversion 1
git -C "$HK_BARE" config extensions.partialClone hkp
git -C "$HK_BARE" config remote.hkp.url "$TMPDIR/hk-promisor.git"
git -C "$HK_BARE" config remote.hkp.promisor true
git -C "$HK_BARE" config remote.hkp.fetch "+${HK_LAZY}:refs/cache/probe"
printf '#!/bin/sh\necho bare-rt >> "%s"\n' "$HK_RAN" \
    > "$HK_BARE/hooks/reference-transaction"
chmod +x "$HK_BARE/hooks/reference-transaction"
assert_eq "a bare repo that would fetch what it lacks: nothing run" \
    "false|" "$( [ "$(GIT_NO_LAZY_FETCH=0 hk_harvest)" = 0 ] && echo true \
        || echo false)|$(hk_ran)"
: > "$HK_RAN"
git init -q "$TMPDIR/hk-lazy-probe"
GIT_NO_LAZY_FETCH=0 git -C "$TMPDIR/hk-lazy-probe" fetch -q "$HK_BARE" \
    "+refs/heads/agent-work:refs/remotes/probe/agent-work" \
    > /dev/null 2>&1 || true
assert_eq "which a plain fetch runs" "true" \
    "$(grep -qx bare-rt "$HK_RAN" && echo true || echo false)"
# Whatever GIT_NO_LAZY_FETCH the caller sets, the git harvest runs sees
# none but 1 (which harvest sets itself to read the bare repo).
mkdir -p "$TMPDIR/hk-envlog"
cat > "$TMPDIR/hk-envlog/git" <<'EOF'
#!/bin/bash
echo "${GIT_NO_LAZY_FETCH-unset}" >> "$HK_ENVLOG"
exec "$HV_REAL_GIT" "$@"
EOF
chmod +x "$TMPDIR/hk-envlog/git"
for _hk_v in 0 false 1; do
    : > "$TMPDIR/hk-envlog.log"
    PATH="$TMPDIR/hk-envlog:$PATH" HK_ENVLOG="$TMPDIR/hk-envlog.log" \
        GIT_NO_LAZY_FETCH="$_hk_v" hk_harvest > /dev/null
    assert_eq "GIT_NO_LAZY_FETCH=${_hk_v} from the caller: harvest's git sees none other" \
        "true|" "$([ -s "$TMPDIR/hk-envlog.log" ] && echo true || echo false)|$(
            grep -vxE '1|unset' "$TMPDIR/hk-envlog.log" | sort -u)"
done
# A Git config harvest cannot read the hooks of: refused.
mkdir -p "$TMPDIR/hk-cfgfail"
cat > "$TMPDIR/hk-cfgfail/git" <<'EOF'
#!/bin/bash
for a in "$@"; do
    [ "$a" = --get-regexp ] && exit 3
done
exec "$HV_REAL_GIT" "$@"
EOF
chmod +x "$TMPDIR/hk-cfgfail/git"
assert_eq "a Git config harvest cannot read: refused" "1 true" \
    "$(PATH="$TMPDIR/hk-cfgfail:$PATH" hk_harvest) $(
        hk_says "cannot read the Git config of")"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
