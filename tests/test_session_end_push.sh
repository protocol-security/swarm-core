#!/bin/bash
set -euo pipefail

# Guard against the regression reported in issue #82:
#   session-end `git pull --rebase && git push` at
#   lib/harness.sh fails every retry when the target repo
#   installs worktree-touching post-checkout / post-rewrite
#   hooks, because the rebase's internal checkouts fire the
#   hooks and re-dirty the tree.  Pin the
#   `-c core.hooksPath=/dev/null` fix structurally, exercise
#   the hook-suppression mechanism end-to-end, and pin the
#   park-push retry loop both structurally and behaviorally.

# Isolate from host gitconfig (signing keys, hooks, templates).
# This test exercises rebase/push mechanics, not signing.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_FILE="$REPO_ROOT/lib/harness.sh"
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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        needle:  ${needle}"
        echo "        haystack:"
        printf '%s\n' "$haystack" | head -5 | sed 's/^/          /'
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
echo "=== 1. Structural: primary rebase path suppresses hooks ==="

# Both git invocations on the primary session-end push must pass
# `-c core.hooksPath=/dev/null`.  Without the override, a consumer
# repo's post-checkout / post-rewrite hook that regenerates docs
# or stamps build artifacts fires inside the rebase's internal
# checkouts under .git/rebase-merge/ and re-dirties the tree,
# failing every retry.
assert_eq "primary git pull --rebase uses core.hooksPath=/dev/null" \
    "1" \
    "$(grep -cE 'git -c core\.hooksPath=/dev/null pull --rebase origin agent-work' \
        "$HARNESS_FILE")"
assert_eq "primary git push uses core.hooksPath=/dev/null" \
    "1" \
    "$(grep -cE 'git -c core\.hooksPath=/dev/null push origin agent-work' \
        "$HARNESS_FILE")"

# The pre-existing scratch-fallback overrides must still be there --
# regression guard in case a future refactor accidentally drops
# them.  worktree add, cherry-pick, and commit each need the flag.
assert_eq "scratch worktree add keeps core.hooksPath=/dev/null" \
    "1" \
    "$(grep -cE 'git -c core\.hooksPath=/dev/null worktree add' \
        "$HARNESS_FILE")"

# ============================================================
echo ""
echo "=== 2. Structural: park push has bounded retry with backoff ==="

# The salvage-park push inside _scratch_worktree_push must retry
# with backoff instead of failing on the first rejection.  This
# is what keeps a transient /upstream hiccup from silently
# dropping the parked commit when scratch push already failed.
assert_eq "park push wrapped in 3-attempt for-loop" \
    "1" \
    "$(grep -cE 'for _ptry in 1 2 3; do' "$HARNESS_FILE")"

# The loop must sleep before (or between) attempts so two agents
# that both hit /upstream at the exact same instant don't
# retry in lockstep.  `sleep $((RANDOM % 5 + 1))` matches the
# primary rebase path's backoff.
PARK_BLOCK=$(awk '
    /for _ptry in 1 2 3; do/      { inside = 1 }
    inside                        { print }
    # Capture past the loop'\''s `done` into the trailing
    # `if [ "$_park_ok" != true ]; then ... fi` gate so the
    # failure-log assertion sees it, then stop at its `fi`.
    inside && /^        done$/    { after_done = 1; next }
    after_done && /^        fi$/  { inside = 0; after_done = 0 }
' "$HARNESS_FILE")
# Single-quoted literal patterns to grep for -- intentional, not
# shell expansions.
# shellcheck disable=SC2016
assert_contains "park retry sleeps with 1..5s jitter" \
    'sleep $((RANDOM % 5 + 1))' "$PARK_BLOCK"
# shellcheck disable=SC2016
assert_contains "park retry pushes to the agent-parked ref" \
    'git push origin "HEAD:${_park_ref}"' "$PARK_BLOCK"
assert_contains "park retry logs attempt number on failure" \
    'scratch push: park retry' "$PARK_BLOCK"

# After the loop, the "parking also failed" error must gate on
# _park_ok, not on the last attempt's exit status, so a successful
# attempt 2 or 3 doesn't get reported as a failure.
# shellcheck disable=SC2016
assert_contains "failure log is gated on _park_ok" \
    '[ "$_park_ok" != true ]' "$PARK_BLOCK"

# ============================================================
echo ""
echo "=== 3. Mechanism: core.hooksPath=/dev/null suppresses hooks ==="

# Prove that the flag we added to harness.sh actually does what
# the fix-commit message claims: a post-checkout hook installed
# via the default .git/hooks/ path does NOT fire when git is
# invoked with `-c core.hooksPath=/dev/null`.  This is the
# elementary brick that the §4 rebase-scenario test rests on.
HOOKDIR="$TMPDIR/hookrepo"
mkdir -p "$HOOKDIR"
(
    cd "$HOOKDIR"
    git init --quiet -b main
    git -c user.name=t -c user.email=t@t commit \
        --quiet --allow-empty -m "root"
    git -c user.name=t -c user.email=t@t commit \
        --quiet --allow-empty -m "second"

    cat > .git/hooks/post-checkout <<'HOOK'
#!/bin/bash
echo fired >> "$PWD/hook.log"
HOOK
    chmod +x .git/hooks/post-checkout
)

# Baseline: without the flag, checkout fires the hook.
rm -f "$HOOKDIR/hook.log"
git -C "$HOOKDIR" checkout --quiet HEAD~1
git -C "$HOOKDIR" checkout --quiet main
assert_eq "post-checkout fires by default (2 checkouts -> 2 lines)" \
    "2" \
    "$(wc -l < "$HOOKDIR/hook.log" | tr -d ' ')"

# With the flag: hook is silenced for both checkouts.
rm -f "$HOOKDIR/hook.log"
git -C "$HOOKDIR" -c core.hooksPath=/dev/null \
    checkout --quiet HEAD~1
git -C "$HOOKDIR" -c core.hooksPath=/dev/null \
    checkout --quiet main
if [ -f "$HOOKDIR/hook.log" ]; then
    hook_lines=$(wc -l < "$HOOKDIR/hook.log" | tr -d ' ')
else
    hook_lines=0
fi
assert_eq "core.hooksPath=/dev/null suppresses post-checkout" \
    "0" "$hook_lines"

# ============================================================
echo ""
echo "=== 4. Regression: dirtying hook doesn't break the rebase ==="

# Reproduce the bug's shape: a bare remote, two clones that
# diverge on agent-work so `pull --rebase` must actually rebase,
# and a post-checkout hook in the second clone that modifies a
# tracked file (mimicking a docs-regenerator or artifact-stamp
# hook).  Without the fix, the rebase-internal checkouts fire
# the hook and leave the tree dirty; with the fix, the rebase
# runs against a quiet worktree and lands clean.
BARE="$TMPDIR/upstream.git"
A="$TMPDIR/clone_a"
B="$TMPDIR/clone_b"

git init --quiet --bare -b agent-work "$BARE"

git clone --quiet "$BARE" "$A"
(
    cd "$A"
    git config user.name  t
    git config user.email t@t
    git checkout --quiet -b agent-work
    printf 'base\n' > tracked.txt
    git add tracked.txt
    git commit --quiet -m "base"
    git push --quiet origin agent-work
)

git clone --quiet "$BARE" "$B"
(
    cd "$B"
    git config user.name  t
    git config user.email t@t
    git checkout --quiet agent-work
)

# A lands a commit on origin/agent-work so B's push path needs
# a non-ff rebase.
(
    cd "$A"
    printf 'base\nfrom-a\n' > tracked.txt
    git commit --quiet -am "a1"
    git push --quiet origin agent-work
)

# B makes its own commit and installs the hostile hook only
# after the commit, so the hook's first firing is during the
# rebase-internal checkouts, not at `git commit` time.
(
    cd "$B"
    printf 'base\nfrom-b\n' > other.txt
    git add other.txt
    git commit --quiet -m "b1"

    cat > .git/hooks/post-checkout <<'HOOK'
#!/bin/bash
# A docs-regenerator stand-in: every checkout rewrites a
# tracked file to a "built" form that differs from whatever
# the commit actually contains.
printf 'rebuilt-by-hook\n' > tracked.txt
HOOK
    chmod +x .git/hooks/post-checkout
)

# Snapshot B's pre-rebase state so we can restore it between the
# two arms of the experiment.
B_BASE_SHA=$(git -C "$B" rev-parse HEAD)

reset_b() {
    # Drop any untracked files and hard-reset to the captured SHA.
    # `-f` on clean is needed because the hook may have left
    # build artifacts; `-d` for untracked dirs.
    git -C "$B" -c core.hooksPath=/dev/null reset --hard \
        --quiet "$B_BASE_SHA"
    git -C "$B" -c core.hooksPath=/dev/null clean -fdx --quiet
    # Abort any rebase left behind from the previous arm.
    if [ -d "$B/.git/rebase-merge" ] || [ -d "$B/.git/rebase-apply" ]; then
        git -C "$B" rebase --abort 2>/dev/null \
            || rm -rf "$B/.git/rebase-merge" "$B/.git/rebase-apply"
    fi
    # Rewind origin/agent-work in B to the shared ancestor so
    # the next rebase actually has something to rebase onto.
    # (We re-fetch inside each arm.)
    :
}

# --- Arm A: rebase WITHOUT the fix --- #
reset_b
rc_without=0
(
    cd "$B"
    git fetch --quiet origin agent-work
    git pull --rebase --quiet origin agent-work 2>&1
) > "$TMPDIR/pull_without.log" 2>&1 || rc_without=$?
# Snapshot the worktree status immediately after the rebase.
status_without=$(git -C "$B" status --porcelain=v1 2>/dev/null)

# The observable failure shape is one of:
#   a. `git pull --rebase` exited non-zero (rebase aborted), or
#   b. `git pull --rebase` returned 0 but the tree is dirty
#      (hook's rewrite of tracked.txt survived as unstaged mod).
# Either one would make the subsequent `git push` either fail
# or push a dirty state.  We accept either failure mode because
# the exact shape depends on the git version (some aborts, some
# merges the hook's output into the rebase).
if [ "$rc_without" -ne 0 ] || [ -n "$status_without" ]; then
    echo "  PASS: without fix, rebase is broken (rc=${rc_without}, dirty=$([ -n "$status_without" ] && echo yes || echo no))"
    PASS=$((PASS + 1))
else
    echo "  FAIL: without fix, rebase should have failed or left dirty tree"
    echo "        rc=${rc_without}"
    echo "        status:"
    printf '%s\n' "$status_without" | sed 's/^/          /'
    FAIL=$((FAIL + 1))
fi

# --- Arm B: rebase WITH the fix --- #
reset_b
rc_with=0
(
    cd "$B"
    git fetch --quiet origin agent-work
    git -c core.hooksPath=/dev/null pull --rebase --quiet \
        origin agent-work 2>&1
) > "$TMPDIR/pull_with.log" 2>&1 || rc_with=$?
status_with=$(git -C "$B" status --porcelain=v1 2>/dev/null)

assert_eq "with fix, pull --rebase exits 0" "0" "$rc_with"
assert_eq "with fix, worktree is clean after rebase" "" "$status_with"

# The rebased commit should be B's b1 sitting on top of A's a1.
head_subject=$(git -C "$B" log -1 --format='%s' 2>/dev/null)
parent_subject=$(git -C "$B" log -1 --format='%s' HEAD^ 2>/dev/null)
assert_eq "with fix, HEAD is still b1 (rebased)" "b1" "$head_subject"
assert_eq "with fix, HEAD^ is a1 from origin"    "a1" "$parent_subject"

# And a subsequent push actually lands.
(
    cd "$B"
    git -c core.hooksPath=/dev/null push --quiet origin agent-work
) > "$TMPDIR/push_with.log" 2>&1 \
    && push_rc=0 || push_rc=$?
assert_eq "with fix, push lands on origin" "0" "$push_rc"

# ============================================================
echo ""
echo "=== 5. Regression: park retry survives transient push fail ==="

# Recreate the exact park retry idiom the harness runs and drive
# it with a fake `git` that fails a configurable number of times
# before succeeding.  The structural test in §2 pins the shape;
# this test pins the behavior: with a 3-attempt loop and a fail
# budget of 2, the third attempt must succeed and _park_ok must
# end up true.  With a fail budget of 3, all attempts fail and
# _park_ok stays false so the harness logs the loss.

FAKEBIN="$TMPDIR/fakebin"
mkdir -p "$FAKEBIN"

# Fake git that decrements a counter file; fails while the
# counter is positive, succeeds once it hits zero.  Only the
# `push` subcommand is instrumented -- everything else is a
# no-op exit 0 so the loop wrapper can do status checks etc.
cat > "$FAKEBIN/git" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "push" ]; then
    n=$(cat "${FAIL_COUNTER:?}" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then
        echo "$((n-1))" > "$FAIL_COUNTER"
        echo "fake: push rejected (remaining fails=$((n-1)))" >&2
        exit 1
    fi
    echo "fake: push accepted"
    exit 0
fi
exit 0
FAKE
chmod +x "$FAKEBIN/git"

# Verbatim reproduction of the park retry block's logic so we
# can drive it headless.  The §2 structural tests keep the
# harness in sync with this shape.
park_retry() {
    local _park_ok=false
    local _park_ref
    # shellcheck disable=SC2034
    _park_ref="refs/heads/agent-parked/test-$(date -u +%Y%m%dT%H%M%SZ)"
    local _ptry
    local _attempts=0
    for _ptry in 1 2 3; do
        _attempts=$((_attempts + 1))
        # No real sleep in the test -- we're pinning the control
        # flow, not the backoff wall time.
        if git push origin "HEAD:${_park_ref}" 2>&1; then
            _park_ok=true
            break
        fi
    done
    echo "attempts=${_attempts} park_ok=${_park_ok}"
}

# Scenario A: two transient rejections, third attempt succeeds.
echo 2 > "$TMPDIR/fail_counter"
out_a=$(PATH="$FAKEBIN:$PATH" \
    FAIL_COUNTER="$TMPDIR/fail_counter" park_retry 2>&1)
assert_contains "2-fail scenario: 3 attempts used" \
    "attempts=3" "$out_a"
assert_contains "2-fail scenario: park_ok=true" \
    "park_ok=true" "$out_a"

# Scenario B: first attempt succeeds.
echo 0 > "$TMPDIR/fail_counter"
out_b=$(PATH="$FAKEBIN:$PATH" \
    FAIL_COUNTER="$TMPDIR/fail_counter" park_retry 2>&1)
assert_contains "0-fail scenario: exactly 1 attempt used" \
    "attempts=1" "$out_b"
assert_contains "0-fail scenario: park_ok=true" \
    "park_ok=true" "$out_b"

# Scenario C: all three attempts fail.
echo 3 > "$TMPDIR/fail_counter"
out_c=$(PATH="$FAKEBIN:$PATH" \
    FAIL_COUNTER="$TMPDIR/fail_counter" park_retry 2>&1)
assert_contains "3-fail scenario: 3 attempts used" \
    "attempts=3" "$out_c"
assert_contains "3-fail scenario: park_ok=false" \
    "park_ok=false" "$out_c"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
