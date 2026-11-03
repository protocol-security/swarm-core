#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/preserve.sh: the checks that keep agent work from
# being deleted.  Uses local git repos (no Docker or API key required).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=../lib/preserve.sh
source "$REPO_ROOT/lib/preserve.sh"

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

g() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}

# A checkout with two commits, and a bare repo cloned from it.
WORK="$TMPDIR/work"
BARE="$TMPDIR/bare.git"
AGENT="$TMPDIR/agent"
git init -q "$WORK"
g -C "$WORK" commit -q --allow-empty -m one
ONE=$(git -C "$WORK" rev-parse HEAD)
g -C "$WORK" commit -q --allow-empty -m two
git clone -q --bare "$WORK" "$BARE"
git -C "$BARE" update-ref refs/heads/agent-work HEAD
git clone -q "$BARE" "$AGENT"

# Run the check and print "<status>|<stdout>".
check() {
    local out rc=0
    out=$(swarm_preservation_check "$BARE" "$WORK" 2>/dev/null) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

# Push a new agent commit from the agent clone to REF and print it.
agent_push() {
    local ref="$1"
    git -C "$AGENT" fetch -q origin
    git -C "$AGENT" checkout -q --detach origin/agent-work
    g -C "$AGENT" commit -q --allow-empty -m "agent work for ${ref}"
    git -C "$AGENT" push -q origin "HEAD:${ref}"
    git -C "$AGENT" rev-parse HEAD
}

echo "=== 1. Every tip contained ==="
assert_eq "fresh bare repo: nothing to preserve" "0|" "$(check)"
git -C "$BARE" update-ref refs/heads/swarm/abc/interactive-x "$ONE"
assert_eq "an ancestor of HEAD counts as contained" "0|" "$(check)"
git -C "$BARE" update-ref -d refs/heads/swarm/abc/interactive-x

echo ""
echo "=== 2. Uncontained tips in each namespace ==="
for ref in refs/heads/agent-work refs/heads/swarm/abc/interactive-x \
        refs/heads/agent-parked/1-20260101T000000Z refs/swarm-runs/r1/x; do
    sha=$(agent_push "$ref")
    assert_eq "${ref} blocks" "1|${ref} ${sha}" "$(check)"
    # The checkout fetches the work but has not merged it: still missing.
    git -C "$WORK" fetch -q "$BARE" "$ref"
    assert_eq "${ref} fetched but not merged still blocks" \
        "1|${ref} ${sha}" "$(check)"
    g -C "$WORK" merge -q --ff-only "$sha"
    assert_eq "${ref} merged into HEAD no longer blocks" "0|" "$(check)"
    git -C "$BARE" update-ref refs/heads/agent-work "$sha"
done

echo ""
echo "=== 3. Every uncontained ref is listed ==="
a=$(agent_push refs/heads/agent-parked/1-a)
b=$(agent_push refs/heads/agent-parked/2-b)
out=$(check)
assert_eq "status 1 with two refs" "1" "${out%%|*}"
assert_eq "both refs are listed" "2" \
    "$(printf '%s\n' "${out#*|}" | grep -c 'agent-parked/' || true)"
git -C "$BARE" update-ref -d refs/heads/agent-parked/1-a "$a"
git -C "$BARE" update-ref -d refs/heads/agent-parked/2-b "$b"

echo ""
echo "=== 4. Refs outside the preservation namespaces are ignored ==="
c=$(agent_push refs/heads/scratch)
assert_eq "an agent branch elsewhere does not block" "0|" "$(check)"
git -C "$BARE" update-ref -d refs/heads/scratch "$c"

echo ""
echo "=== 5. A ref that is not a commit fails the check ==="
blob=$(printf 'x' | git -C "$BARE" hash-object -w --stdin)
git -C "$BARE" update-ref refs/swarm-runs/blob "$blob"
assert_eq "non-commit ref: status 2" "2" "$(check | cut -d'|' -f1)"
git -C "$BARE" update-ref -d refs/swarm-runs/blob

echo ""
echo "=== 5b. Broken refs fail the check instead of being skipped ==="
# for-each-ref warns about these and leaves them out of its output.
mkdir -p "$BARE/refs/heads/agent-parked"
printf 'not a sha\n' > "$BARE/refs/heads/agent-parked/garbage"
assert_eq "malformed loose ref: status 2" "2" "$(check | cut -d'|' -f1)"
rm -f "$BARE/refs/heads/agent-parked/garbage"
printf '%s\n' "0123456789012345678901234567890123456789" \
    > "$BARE/refs/heads/agent-parked/missing"
assert_eq "ref to a missing object: status 2" "2" \
    "$(check | cut -d'|' -f1)"
rm -f "$BARE/refs/heads/agent-parked/missing"
assert_eq "clean again after removing them" "0|" "$(check)"

echo ""
echo "=== 6. Not a bare repository ==="
rc=0
swarm_preservation_check "$WORK" "$WORK" >/dev/null 2>&1 || rc=$?
assert_eq "a non-bare repo: status 2" "2" "$rc"
rc=0
swarm_preservation_check "$TMPDIR/missing.git" "$WORK" >/dev/null 2>&1 \
    || rc=$?
assert_eq "a missing path: status 2" "2" "$rc"
ln -s "$BARE" "$TMPDIR/link.git"
rc=0
swarm_preservation_check "$TMPDIR/link.git" "$WORK" >/dev/null 2>&1 \
    || rc=$?
assert_eq "a symlink: status 2" "2" "$rc"

echo ""
echo "=== 7. A checkout git cannot read fails the check ==="
d=$(agent_push refs/heads/agent-parked/3-d)
rc=0
swarm_preservation_check "$BARE" "$TMPDIR/not-a-repo" >/dev/null 2>&1 \
    || rc=$?
assert_eq "an unreadable checkout: status 2" "2" "$rc"
git -C "$BARE" update-ref -d refs/heads/agent-parked/3-d "$d"

# HEAD is readable, but the object store behind the tips is not.
f=$(agent_push refs/heads/agent-parked/5-f)
# A broken alternates entry only in the checkout: HEAD still resolves.
printf '%s\n' "$TMPDIR/no-such-objects" > "$WORK/.git/objects/info/alternates"
rc=0
swarm_preservation_check "$BARE" "$WORK" >/dev/null 2>"$TMPDIR/err" \
    || rc=$?
assert_eq "an object store git cannot read: status 2, not missing work" \
    "2" "$rc"
assert_eq "the git error is passed on" "1" \
    "$(grep -c 'cannot read' "$TMPDIR/err" || true)"
rm -f "$WORK/.git/objects/info/alternates"
# Same with a tip the checkout has: git reads it but still complains.
git -C "$WORK" fetch -q "$BARE" refs/heads/agent-parked/5-f
printf '%s\n' "$TMPDIR/no-such-objects" > "$WORK/.git/objects/info/alternates"
rc=0
swarm_preservation_check "$BARE" "$WORK" >/dev/null 2>"$TMPDIR/err" \
    || rc=$?
assert_eq "a present tip in a broken object store: status 2" "2" "$rc"
rm -f "$WORK/.git/objects/info/alternates"
git -C "$BARE" update-ref -d refs/heads/agent-parked/5-f "$f"

echo ""
echo "=== 7b. Grafts and replace objects cannot fake containment ==="
# An agent commit on a side line, not in HEAD's history.
e=$(agent_push refs/heads/agent-parked/4-e)
git -C "$WORK" fetch -q "$BARE" refs/heads/agent-parked/4-e
side=$(g -C "$WORK" commit-tree -p "$e" -m side "$(git -C "$WORK" \
    rev-parse 'HEAD^{tree}')")
assert_eq "side work blocks" "1" "$(check | cut -d'|' -f1)"
# A graft that makes HEAD a child of the agent commit.
head=$(git -C "$WORK" rev-parse HEAD)
printf '%s %s %s\n' "$head" "$(git -C "$WORK" rev-parse HEAD~1)" "$e" \
    > "$WORK/.git/info/grafts"
assert_eq "still blocks with a graft" "1" "$(check | cut -d'|' -f1)"
rm -f "$WORK/.git/info/grafts"
# A replace object that swaps HEAD for a commit with the agent parent.
fake=$(g -C "$WORK" commit-tree -p "$(git -C "$WORK" rev-parse HEAD~1)" \
    -p "$e" -m fake "$(git -C "$WORK" rev-parse 'HEAD^{tree}')")
git -C "$WORK" replace "$head" "$fake"
assert_eq "plain git is fooled by the replace object" "0" \
    "$(git -C "$WORK" merge-base --is-ancestor "$e" HEAD && echo 0 || echo 1)"
assert_eq "still blocks with a replace object" "1" \
    "$(check | cut -d'|' -f1)"
git -C "$WORK" replace -d "$head"
: "$side"
git -C "$BARE" update-ref -d refs/heads/agent-parked/4-e "$e"

echo ""
echo "=== 8. The explanation says what to do with each ref ==="
msg=$(printf '%s\n' "refs/heads/agent-work 0123456789abcdef" \
    "refs/heads/swarm/r/interactive-x 0123456789abcdef" \
    "refs/heads/agent-parked/1-x 0123456789abcdef" \
    | swarm_preservation_explain "$BARE" 2>&1)
assert_eq "agent-work: harvest" "1" \
    "$(printf '%s\n' "$msg" | grep -c '^  agent-work .*harvest' || true)"
assert_eq "interactive branch: harvest" "1" \
    "$(printf '%s\n' "$msg" \
        | grep -c '^  swarm/r/interactive-x .*harvest' || true)"
assert_eq "parked branch: fetch and review" "1" \
    "$(printf '%s\n' "$msg" \
        | grep -c '^  agent-parked/1-x .*git fetch' || true)"
msg=$(printf '%s\n' 'refs/swarm-runs/$USER;x 0123456789abcdef' \
    | swarm_preservation_explain "$BARE" 2>&1)
assert_eq "a ref with shell characters is quoted" "1" \
    "$(printf '%s\n' "$msg" | grep -cF 'refs/swarm-runs/\$USER\;x' || true)"
msg=$(printf '%s\n' "refs/heads/agent-work 0123456789abcdef" \
    | swarm_preservation_explain "$BARE" 2>&1)
assert_eq "the explicit delete command is shown" "1" \
    "$(printf '%s\n' "$msg" | grep -c 'update-ref -d <ref> <sha>' || true)"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
