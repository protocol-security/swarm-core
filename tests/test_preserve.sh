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

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"
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
echo "=== 5c. A read that fails part of the way is no end of the list ==="
# An I/O error ends a read loop as the end of the list would; the refs
# after it, uncontained ones among them, would never be looked at.  A
# read override fails the first read of the list.
z=$(agent_push refs/heads/agent-parked/9-z)
rc=0
(
    # Shadows the builtin for the check below; it passes the caller's
    # options on.
    # shellcheck disable=SC2329,SC2162
    read() {
        if [ "${!#}" = ref ]; then return 1; fi
        builtin read "$@"
    }
    swarm_preservation_check "$BARE" "$WORK"
) >/dev/null 2>"$TMPDIR/read.err" || rc=$?
assert_eq "a failed read before an uncontained ref: status 2" "2" "$rc"
assert_eq "saying the refs could not be read in full" "1" \
    "$(grep -c 'cannot read the refs of' "$TMPDIR/read.err" || true)"
assert_eq "without the failure the ref is listed" "1|refs/heads/agent-parked/9-z ${z}" \
    "$(check)"
git -C "$BARE" update-ref -d refs/heads/agent-parked/9-z "$z"

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

# ============================================================
echo ""
echo "=== 9. The scanner keeps every object and git-dir file ==="

SCAN="$REPO_ROOT/lib/preserve-scan.sh"
# Scan into a new directory; print its path.  Extra args: env settings.
scan() {
    local mode="$1" root="$2" ctx="$3" out
    out=$(mktemp -d "$TMPDIR/scan.XXXXXX")
    shift 3
    env "$@" bash "$SCAN" "$mode" "$root" "$ctx" "$out" >/dev/null 2>&1 \
        || echo "rc=$?" > "$out/.rc"
    printf '%s' "$out"
}
# Import scan output into a fresh repository; print its path.
imported() {
    local dst
    dst=$(mktemp -d "$TMPDIR/dst.XXXXXX")
    git init -q "$dst"
    git -C "$dst" fetch -q --no-tags "$1/bundle" 'refs/v/*:refs/r/*'
    printf '%s' "$dst"
}
has_line() {
    grep -cF -- "$2" "$1/report" || true
}

W="$TMPDIR/ws"
git init -q "$W"
echo a > "$W/a"
echo 'ign*' > "$W/.gitignore"
g -C "$W" add .
g -C "$W" commit -q -m one
echo b > "$W/b"
g -C "$W" add b
g -C "$W" commit -q -m two
LOST=$(git -C "$W" rev-parse HEAD)
git -C "$W" reset -q --hard HEAD~1
echo wip > "$W/a"
STASHED=$(g -C "$W" stash create)
git -C "$W" checkout -q -- a
git -C "$W" reflog expire --expire=now --all
echo blob-only | git -C "$W" hash-object -w --stdin > "$TMPDIR/blobid"
echo note > "$W/.git/objects/info/rescue.patch"
printf '#!/bin/sh\necho hi\n' > "$W/.git/hooks/pre-commit"
chmod +x "$W/.git/hooks/pre-commit"
out=$(scan worktree "$W" full)
assert_eq "a clean workspace scans" "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "a clean workspace reports nothing to keep or discard" "0" \
    "$(grep -cE '^(block|uncommitted) ' "$out/report" || true)"
dst=$(imported "$out")
assert_eq "a commit only the expired reflog knew is kept" "commit" \
    "$(git -C "$dst" cat-file -t "$LOST" 2>/dev/null)"
assert_eq "a stash create result no ref names is kept" "commit" \
    "$(git -C "$dst" cat-file -t "$STASHED" 2>/dev/null)"
assert_eq "a blob nothing references is kept" "blob" \
    "$(git -C "$dst" cat-file -t "$(cat "$TMPDIR/blobid")" 2>/dev/null)"
assert_eq "every object of the inventory is in the bundle" "0" \
    "$(git -C "$dst" cat-file --batch-check < "$out/objects" \
        | grep -c ' missing$' || true)"
_files=$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n')
for _f in objects/info/rescue.patch hooks/pre-commit config index \
        ORIG_HEAD; do
    assert_eq "git-dir file ${_f} is stored" "1" \
        "$(printf '%s\n' "$_files" | awk -v f="$_f" '$4 == f' | wc -l \
            | tr -d ' ')"
done
rm -f "$W/.git/hooks/pre-commit"
_n=$(printf '%s\n' "$_files" \
    | awk '$4 == "objects/info/rescue.patch" { print $1 }')
assert_eq "a stored file has its content" "note" \
    "$(git -C "$dst" cat-file -p "refs/r/0/f/$_n")"
assert_eq "loose object files are stored as files too" "true" \
    "$([ "$(printf '%s\n' "$_files" \
        | awk '$4 ~ /^objects\/[0-9a-f][0-9a-f]\//' | wc -l)" -gt 0 ] \
        && echo true || echo false)"

# Content outside Git's history is reported, not packed.
echo dirty >> "$W/a"
echo x > "$W/ignored.txt"
echo u > "$W/untracked"
git -C "$W" update-index --skip-worktree .gitignore
mkdir -p "$W/agent_logs" "$W/.claude"
echo log > "$W/agent_logs/x.log"
out=$(scan worktree "$W" full)
assert_eq "a modified file is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted dirty .:  M a')"
assert_eq "an untracked file is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted dirty .: ?? untracked')"
assert_eq "an ignored file is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted ignored .: ignored.txt')"
assert_eq "a skip-worktree entry is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted hidden .: S .gitignore')"
assert_eq "agent logs are engine files" "0" \
    "$(has_line "$out" 'agent_logs')"
git -C "$W" update-index --no-skip-worktree .gitignore
git -C "$W" checkout -q -- a
rm -rf "$W/ignored.txt" "$W/untracked" "$W/agent_logs"

# Paths Git would quote (spaces) are matched whole against the engine
# paths; other quoted paths are reported whole.
mkdir -p "$W/agent_logs"
echo l > "$W/agent_logs/a b.log"
echo w > "$W/my file.txt"
out=$(scan worktree "$W" full)
assert_eq "an agent log with a space in its name is an engine file" "0" \
    "$(has_line "$out" 'a b.log')"
assert_eq "a file with a space in its name is reported unquoted" "1" \
    "$(has_line "$out" 'uncommitted dirty .: ?? my file.txt')"
rm -rf "$W/agent_logs" "$W/my file.txt"

# Context modes: the deletions under .claude the engine makes are not
# work; anything else there is.
mkdir -p "$W/.claude"
echo c > "$W/.claude/CLAUDE.md"
echo s > "$W/.claude/skill.md"
g -C "$W" add .claude
g -C "$W" commit -q -m claude
echo q > "$W/.claude/a b.md"
g -C "$W" add ".claude/a b.md"
g -C "$W" commit -q -m spaced
rm "$W/.claude/CLAUDE.md" "$W/.claude/skill.md" "$W/.claude/a b.md"
assert_eq "context none: deletions under .claude are not work" "0" \
    "$(has_line "$(scan worktree "$W" none)" 'uncommitted dirty')"
assert_eq "context slim: deleting CLAUDE.md is work" "1" \
    "$(has_line "$(scan worktree "$W" slim)" '.claude/CLAUDE.md')"
assert_eq "context full: every deletion is work" "3" \
    "$(has_line "$(scan worktree "$W" full)" 'uncommitted dirty .:  D')"
git -C "$W" checkout -q -- .claude

# Unfinished operations, wherever Git keeps their state.
mkdir "$W/.git/rebase-merge"
echo "$LOST" > "$W/.git/rebase-merge/autostash"
out=$(scan worktree "$W" full)
assert_eq "a paused rebase is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted operation .git/rebase-merge')"
rm -rf "$W/.git/rebase-merge"
echo "$STASHED" > "$W/.git/MERGE_AUTOSTASH"
out=$(scan worktree "$W" full)
assert_eq "a merge autostash is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted operation .git/MERGE_AUTOSTASH')"
rm -f "$W/.git/MERGE_AUTOSTASH"

# A file above the size limit is uncommitted instead of stored.
head -c 2048 /dev/zero > "$W/.git/big.bin"
out=$(scan worktree "$W" full SWARM_SCAN_FILE_LIMIT=1024)
assert_eq "a large git-dir file is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted large-file .git/big.bin 2048')"
rm -f "$W/.git/big.bin"

# A pack without its index cannot be proven to hold known objects, so
# its bytes are stored.
mkdir -p "$W/.git/objects/pack"
_hex=0123456789abcdef0123456789abcdef01234567
echo stray > "$W/.git/objects/pack/pack-$_hex.pack"
out=$(scan worktree "$W" full)
dst=$(imported "$out")
assert_eq "a pack without an index is stored as a file" "1" \
    "$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/pack/pack-$_hex.pack" '$4 == f' | wc -l \
        | tr -d ' ')"
rm -f "$W/.git/objects/pack/pack-$_hex.pack"

# Repository layouts the bundle cannot carry block.
E="$TMPDIR/empty-ws"
mkdir -p "$E"
assert_eq "an empty volume is empty" "empty" \
    "$(cat "$(scan worktree "$E" full)/report")"
echo f > "$E/file"
assert_eq "files without a repository block" "1" \
    "$(has_line "$(scan worktree "$E" full)" 'block nogit')"
E2="$TMPDIR/newline-only"
mkdir -p "$E2"
: > "$E2/"$'\n'
assert_eq "a volume holding only a file named by a newline is not empty" \
    "1" "$(has_line "$(scan worktree "$E2" full)" 'block nogit')"
# A path ending in a newline is not mistaken for its neighbour without
# one: the scan fails instead.
NLR="$TMPDIR/nlpair"
mkdir -p "$NLR"
git init -q "$NLR/repo"
g -C "$NLR/repo" commit -q --allow-empty -m plain
git init -q "$NLR/repo"$'\n'
_nlout=$(scan worktree "$NLR/repo"$'\n' full)
assert_eq "a root ending in a newline fails the scan" "rc=3" \
    "$(cat "$_nlout/.rc" 2>/dev/null)"

# A root whose path holds find pattern characters still finds nested
# repositories (the prune of its .git matches only that .git).
GL="$TMPDIR/glob*root"
git init -q "$GL"
g -C "$GL" commit -q --allow-empty -m g
mkdir -p "$GL/agent_logs"
# Unescaped, ".../glob*root/.git" would also match this repo's .git.
git init -q "$GL/agent_logs/root"
assert_eq "a nested repo under a root with * in its path blocks" "1" \
    "$(has_line "$(scan worktree "$GL" full)" 'block embedded agent_logs/root')"

# Repositories under other names inside the workspace block, also under
# engine paths.
git init -q --bare "$W/cache.git"
mkdir -p "$W/agent_logs"
git init -q --bare "$W/agent_logs/x.git"
out=$(scan worktree "$W" full)
assert_eq "a bare repo in the workspace blocks" "1" \
    "$(has_line "$out" 'block embedded cache.git')"
assert_eq "a bare repo under agent_logs blocks" "1" \
    "$(has_line "$out" 'block embedded agent_logs/x.git')"
rm -rf "$W/cache.git" "$W/agent_logs"

git -C "$W" config include.path /elsewhere
assert_eq "a config include blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block config-include .git')"
git -C "$W" config --unset include.path
ln -s /tmp "$W/.git/out-link"
assert_eq "a git-dir symlink to a directory out of the volume blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block outside-dir-link .git/out-link')"
ln -s ../../home/agent/result "$W/result"
ln -s "$W/nowhere" "$W/dangling"
ln -s loop-b "$W/loop-a"
ln -s loop-a "$W/loop-b"
out=$(scan worktree "$W" full)
assert_eq "a relative link out of the volume reports its target" "1" \
    "$(grep -c "^layer-link $(dirname "$(dirname "$(cd -P "$W" && pwd -P)")")/home/agent/result$" \
        "$out/report" || true)"
assert_eq "a dangling link inside the volume is not reported" "0" \
    "$(grep -cE '^(layer-link|block).*dangling' "$out/report" || true)"
assert_eq "a link loop blocks" "1" \
    "$(grep -cE '^block link-loop loop-[ab]$' "$out/report" | awk '{ print ($1 > 0) }')"
rm "$W/result" "$W/dangling" "$W/loop-a" "$W/loop-b"
ln -s "$(cd -P "$W" && pwd -P)"$'\n' "$W/nl-target"
assert_eq "a link whose target ends in a newline blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block newline-path nl-target')"
rm "$W/nl-target"
git -C "$W" config core.worktree "$(cd -P "$W" && pwd -P)"$'\n'
assert_eq "a core.worktree ending in a newline blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block core-worktree .git (newline in path)')"
git -C "$W" config --unset core.worktree
git init -q --bare "$TMPDIR/common-out.git"
CW="$TMPDIR/commondir-ws"
git init -q "$CW"
g -C "$CW" commit -q --allow-empty -m c
echo "$TMPDIR/common-out.git" > "$CW/.git/commondir"
assert_eq "a commondir outside the volume blocks" "1" \
    "$(has_line "$(scan worktree "$CW" full)" 'block commondir .git')"
rm "$W/.git/out-link"
git -C "$W" config core.hooksPath ../hooks
assert_eq "any core.hooksPath blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block core-hookspath .git')"
git -C "$W" config --unset core.hooksPath
mkdir -p "$W/lfs-in-ws"
ln -s "$W/lfs-in-ws" "$W/.git/lfs"
assert_eq "a git-dir symlink to a directory inside the volume is fine" "0" \
    "$(grep -c 'link.*\.git/lfs' "$(scan worktree "$W" full)/report" || true)"
rm "$W/.git/lfs"
rmdir "$W/lfs-in-ws"
git init -q --bare "$TMPDIR/alt-outside.git"
printf '%s' "$TMPDIR/alt-outside.git/objects" > "$W/.git/objects/info/alternates"
assert_eq "alternates outside the volume block (no final newline)" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block alternates .git/objects')"
rm "$W/.git/objects/info/alternates"
# A NUL byte in a file the scan parses with the shell blocks: Git would
# stop at it while the shell drops it, so they would read different
# paths.
git init -q --bare "$TMPDIR/nul-store.git"
printf '%s/objects\000/../..%s/.git/objects\n' \
    "$(cd -P "$TMPDIR/nul-store.git" && pwd -P)" "$(cd -P "$W" && pwd -P)" \
    > "$W/.git/objects/info/alternates"
out=$(scan worktree "$W" full)
assert_eq "alternates with a NUL byte: the scan completes" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "alternates with a NUL byte block" "1" \
    "$(has_line "$out" 'block alternates .git/objects (unreadable or NUL byte)')"
rm -f "$W/.git/objects/info/alternates"
NW="$TMPDIR/nul-wt-ws"
git init -q "$NW"
g -C "$NW" commit -q --allow-empty -m n
git -C "$NW" worktree add -q --detach "$NW/inside" 2>/dev/null
_nadm=$(find "$NW/.git/worktrees" -mindepth 1 -maxdepth 1 -type d | head -1)
printf '%s\000x\n' "$(cd -P "$NW" && pwd -P)/inside/.git" > "$_nadm/gitdir"
out=$(scan worktree "$NW" full)
assert_eq "a worktree back-pointer with a NUL byte blocks" "1" \
    "$(grep -c 'block missing-worktree .*(unreadable or NUL byte)' "$out/report" || true)"
assert_eq "so does the checkout's gitfile pointing at that admin dir" "1" \
    "$(grep -cE '^block (embedded|mismatched-worktree) inside' "$out/report" || true)"
printf '..\000/..\n' > "$_nadm/commondir"
assert_eq "a commondir with a NUL byte blocks" "1" \
    "$(grep -c 'block commondir .*(unreadable or NUL byte)' "$(scan worktree "$NW" full)/report" || true)"
GLK="$TMPDIR/gitlink-ws"
mkdir -p "$GLK"
ln -s /tmp "$GLK/.git"
assert_eq "a .git symlink is a gitlink, not nogit" "1" \
    "$(has_line "$(scan worktree "$GLK" full)" 'block gitlink')"
git init -q "$W/inner"
assert_eq "an embedded repository blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block embedded inner')"
rm -rf "$W/inner"
git -C "$W" worktree add -q "$TMPDIR/outside-wt" 2>/dev/null
assert_eq "a linked worktree outside the volume blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" \
        "block external $(cd -P "$TMPDIR" && pwd -P)/outside-wt")"
git -C "$W" worktree remove --force "$TMPDIR/outside-wt"
git -C "$W" config lfs.storage /elsewhere
assert_eq "an lfs.storage setting blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block lfs-storage .git /elsewhere')"
git -C "$W" config --unset lfs.storage

# Module repositories are found at any depth, initialized or not.
SUB="$TMPDIR/subsrc"
git init -q "$SUB"
g -C "$SUB" commit -q --allow-empty -m sub
g -C "$W" -c protocol.file.allow=always submodule add -q "$SUB" lib \
    >/dev/null 2>&1
g -C "$W" commit -q -m add-sub
g -C "$W/lib" commit -q --allow-empty -m "detached sub work"
SUBWORK=$(git -C "$W/lib" rev-parse HEAD)
git -C "$W/lib" checkout -q HEAD~1
git -C "$W" submodule deinit -q -f lib
out=$(scan worktree "$W" full)
assert_eq "a deinitialized module repo is a git dir" "1" \
    "$(grep -cE '^gitdir [0-9]+ \.git/modules/lib$' "$out/report" || true)"
assert_eq "its detached commit is kept" "commit" \
    "$(git -C "$(imported "$out")" cat-file -t "$SUBWORK" 2>/dev/null)"

# A core.worktree setting cannot point status at another directory.
mkdir -p "$TMPDIR/clean-elsewhere"
echo dirty-again >> "$W/.gitmodules"
git -C "$W" config core.worktree "$TMPDIR/clean-elsewhere"
out=$(scan worktree "$W" full)
assert_eq "core.worktree does not hide dirty files" "1" \
    "$(has_line "$out" 'uncommitted dirty .:  M .gitmodules')"
assert_eq "a core.worktree outside the volume blocks" "1" \
    "$(has_line "$out" 'block core-worktree .git ')"
git -C "$W" config --unset core.worktree
git -C "$W" checkout -q -- .gitmodules

# A graft that makes an unreached commit look reached does not drop it.
GRAFTED=$(g -C "$W" commit-tree -m grafted "$(git -C "$W" rev-parse 'HEAD^{tree}')")
echo "$(git -C "$W" rev-parse HEAD) $GRAFTED" > "$W/.git/info/grafts"
out=$(scan worktree "$W" full)
assert_eq "a grafted parent is still kept" "commit" \
    "$(git -C "$(imported "$out")" cat-file -t "$GRAFTED" 2>/dev/null)"
rm -f "$W/.git/info/grafts"

# A loose file shadowed by a packed copy of the same object is never
# read by Git, so its bytes are stored as a file.
git -C "$W" repack -q -a -d
_shadow=$(git -C "$W" rev-parse HEAD)
_sdir="$W/.git/objects/${_shadow:0:2}"
mkdir -p "$_sdir"
echo "not the packed bytes" > "$_sdir/${_shadow:2}"
out=$(scan worktree "$W" full)
assert_eq "a loose file shadowed by a pack is stored" "1" \
    "$(git -C "$(imported "$out")" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/${_shadow:0:2}/${_shadow:2}" '$4 == f' | wc -l \
        | tr -d ' ')"
rm -f "$_sdir/${_shadow:2}"

# The same, when the other copy is in an alternate's pack.
ALT="$TMPDIR/alt-src"
git init -q "$ALT"
echo alt-content > "$ALT/f"
g -C "$ALT" add f
g -C "$ALT" commit -q -m alt
git -C "$ALT" repack -q -a -d
_alt=$(git -C "$ALT" rev-parse HEAD)
echo "$ALT/.git/objects" > "$W/.git/objects/info/alternates"
mkdir -p "$W/.git/objects/${_alt:0:2}"
echo "other bytes" > "$W/.git/objects/${_alt:0:2}/${_alt:2}"
out=$(scan worktree "$W" full)
assert_eq "a loose file shadowed by an alternate's pack is stored" "1" \
    "$(git -C "$(imported "$out")" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/${_alt:0:2}/${_alt:2}" '$4 == f' | wc -l \
        | tr -d ' ')"
rm -f "$W/.git/objects/${_alt:0:2}/${_alt:2}" "$W/.git/objects/info/alternates"

# Two loose files with swapped contents: each name exists, but neither
# file holds its own object, so both are stored as files.
_ba=$(printf 'swap a\n' | git -C "$W" hash-object -w --stdin)
_bb=$(printf 'swap b\n' | git -C "$W" hash-object -w --stdin)
git -C "$W" update-ref refs/keep/a "$_ba"
git -C "$W" update-ref refs/keep/b "$_bb"
git -C "$W" repack -q -a -d
mkdir -p "$W/.git/objects/${_ba:0:2}" "$W/.git/objects/${_bb:0:2}"
printf 'swap b\n' | git -C "$TMPDIR/subsrc" hash-object --stdin -w >/dev/null
cp "$TMPDIR/subsrc/.git/objects/${_bb:0:2}/${_bb:2}" "$TMPDIR/swap.b"
printf 'swap a\n' | git -C "$TMPDIR/subsrc" hash-object --stdin -w >/dev/null
cp "$TMPDIR/subsrc/.git/objects/${_ba:0:2}/${_ba:2}" "$TMPDIR/swap.a"
cp "$TMPDIR/swap.b" "$W/.git/objects/${_ba:0:2}/${_ba:2}"
cp "$TMPDIR/swap.a" "$W/.git/objects/${_bb:0:2}/${_bb:2}"
out=$(scan worktree "$W" full)
assert_eq "loose files with swapped contents are both stored" "2" \
    "$(git -C "$(imported "$out")" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v a="objects/${_ba:0:2}/${_ba:2}" \
            -v b="objects/${_bb:0:2}/${_bb:2}" '$4 == a || $4 == b' \
        | wc -l | tr -d ' ')"
rm -f "$W/.git/objects/${_ba:0:2}/${_ba:2}" "$W/.git/objects/${_bb:0:2}/${_bb:2}"
git -C "$W" update-ref -d refs/keep/a
git -C "$W" update-ref -d refs/keep/b

# Verified pack data is not stored twice; a loose copy with extra bytes
# after its zlib stream is stored with them.
git -C "$W" repack -q -a -d
_pk=$(find "$W/.git/objects/pack" -name 'pack-*.pack' | head -1)
_head=$(git -C "$W" rev-parse HEAD)
mkdir -p "$W/.git/objects/${_head:0:2}"
git -C "$W" cat-file commit "$_head" \
    | git -C "$TMPDIR/subsrc" hash-object -t commit --stdin -w >/dev/null
cp "$TMPDIR/subsrc/.git/objects/${_head:0:2}/${_head:2}" \
    "$W/.git/objects/${_head:0:2}/${_head:2}"
chmod u+w "$W/.git/objects/${_head:0:2}/${_head:2}"
printf 'TRAILING' >> "$W/.git/objects/${_head:0:2}/${_head:2}"
out=$(scan worktree "$W" full)
dst=$(imported "$out")
assert_eq "a verified pack is not stored as a file" "0" \
    "$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/pack/${_pk##*/}" '$4 == f' | wc -l | tr -d ' ')"
_lf=$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
    | awk -v f="objects/${_head:0:2}/${_head:2}" '$4 == f { print $1 }')
assert_eq "a loose file with trailing bytes keeps them" "TRAILING" \
    "$(git -C "$dst" cat-file -p "refs/r/0/f/$_lf" | tail -c 8)"
rm -f "$W/.git/objects/${_head:0:2}/${_head:2}"

# A pack file that is a symlink is stored as a symlink, not exempted.
_pk=$(find "$W/.git/objects/pack" -name 'pack-*.pack' | head -1)
_pb="${_pk%.pack}"
ln -s /elsewhere/sidecar "$_pb.bitmap"
out=$(scan worktree "$W" full)
assert_eq "a symlinked pack sidecar is stored as a symlink" "1" \
    "$(git -C "$(imported "$out")" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/pack/${_pb##*/}.bitmap" '$2 == "120000" && $4 == f' \
        | wc -l | tr -d ' ')"
rm -f "$_pb.bitmap"

# Names and symlink targets keep every byte, newlines included.
_nl="odd"$'\n'"name"
echo payload > "$W/.git/$_nl"
ln -s "target"$'\n'"line" "$W/.git/nl-link"
out=$(scan worktree "$W" full)
dst=$(imported "$out")
# The manifest is NUL-separated; turn NULs into "|" to keep the name's
# own newline visible as one entry.
assert_eq "a file name with a newline is stored whole" "1" \
    "$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0\n' '|~' \
        | tr '|' '\n' | grep -c '^[0-9]* 100644 8 odd~name$' || true)"
_ln=$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
    | awk '$4 == "nl-link" { print $1 }')
assert_eq "a symlink target keeps its newline" \
    "target"$'\n'"line" "$(git -C "$dst" cat-file -p "refs/r/0/f/$_ln")"
rm -f "$W/.git/$_nl" "$W/.git/nl-link"
ln -s "trail"$'\n' "$W/.git/trail-link"
out=$(scan worktree "$W" full)
dst=$(imported "$out")
_ln=$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
    | awk '$4 == "trail-link" { print $1 }')
assert_eq "a symlink target keeps a trailing newline" "74 72 61 69 6c 0a" \
    "$(git -C "$dst" cat-file -p "refs/r/0/f/$_ln" | od -An -tx1 \
        | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')"
rm -f "$W/.git/trail-link"

# lfs.storage set only for a linked worktree still blocks.
git -C "$W" worktree add -q "$W/wt2" 2>/dev/null
git -C "$W" config extensions.worktreeConfig true
git -C "$W/wt2" config --worktree lfs.storage /elsewhere
assert_eq "a worktree's lfs.storage blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block lfs-storage .git/worktrees/wt2 /elsewhere')"
git -C "$W" worktree remove --force "$W/wt2"
git -C "$W" config --unset extensions.worktreeConfig

# A rename out of an engine path does not hide the new file's edits.
mkdir -p "$W/agent_logs"
echo old > "$W/agent_logs/old"
g -C "$W" add -f agent_logs/old
g -C "$W" commit -q -m old-log
git -C "$W" mv agent_logs/old valuable.txt
echo edited >> "$W/valuable.txt"
assert_eq "a file renamed from agent_logs is reported" "1" \
    "$(grep -c 'valuable.txt' "$(scan worktree "$W" full)/report" || true)"
git -C "$W" reset -q --hard HEAD
git -C "$W" rm -q agent_logs/old
g -C "$W" commit -q -m drop-old-log

# A submodule may be called logs; its worktrees are still found.
LSUB="$TMPDIR/logsrc"
git init -q "$LSUB"
g -C "$LSUB" commit -q --allow-empty -m logs
g -C "$W" -c protocol.file.allow=always submodule add -q "$LSUB" logs \
    >/dev/null 2>&1
git -C "$W/logs" worktree add -q --detach "$TMPDIR/logs-outside" \
    2>/dev/null
assert_eq "a worktree of a submodule called logs is found" "1" \
    "$(has_line "$(scan worktree "$W" full)" \
        "block external $(cd -P "$TMPDIR" && pwd -P)/logs-outside")"
git -C "$W/logs" worktree remove --force "$TMPDIR/logs-outside"
git -C "$W" rm -q -f logs
rm -rf "$W/.git/modules/logs"
git -C "$W" checkout -q HEAD -- .gitmodules

# Engine paths are only engine files in the workspace's own checkout;
# in a submodule they are work.
git -C "$W" -c protocol.file.allow=always submodule update -q --init \
    >/dev/null 2>&1
mkdir -p "$W/lib/agent_logs"
echo notes > "$W/lib/agent_logs/notes"
assert_eq "agent_logs inside a submodule is work" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'uncommitted dirty lib: ?? agent_logs/notes')"
rm -rf "$W/lib/agent_logs"

# A submodule of a linked worktree keeps its git dir under
# .git/worktrees/<wt>/modules/; its checkout is still checked.
git -C "$W" worktree add -q --detach "$W/wt-sub" 2>/dev/null
g -C "$W/wt-sub" -c protocol.file.allow=always submodule update -q --init \
    >/dev/null 2>&1
echo extra > "$W/wt-sub/lib/newfile"
assert_eq "a linked worktree's submodule checkout is checked" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'uncommitted dirty wt-sub/lib: ?? newfile')"
git -C "$W" worktree remove --force "$W/wt-sub"

# A linked worktree whose HEAD is a symlink is still found.
git -C "$W" worktree add -q --detach "$TMPDIR/symhead-outside" 2>/dev/null
_wtg=$(find "$W/.git/worktrees" -maxdepth 1 -mindepth 1 -type d | head -1)
_wth=$(cat "$_wtg/HEAD")
printf '%s\n' "$_wth" > "$TMPDIR/symhead-target"
rm "$_wtg/HEAD"
ln -s "$TMPDIR/symhead-target" "$_wtg/HEAD"
assert_eq "a worktree with a symlinked HEAD is found" "1" \
    "$(has_line "$(scan worktree "$W" full)" \
        "block external $(cd -P "$TMPDIR" && pwd -P)/symhead-outside")"
rm "$_wtg/HEAD"
git -C "$W" worktree remove --force "$TMPDIR/symhead-outside" 2>/dev/null \
    || { rm -rf "$_wtg" "$TMPDIR/symhead-outside"; git -C "$W" worktree prune; }

# A git dir whose path holds a newline cannot be listed; it blocks.
git init -q --bare "$W/.git/modules/a"$'\n'"b"
assert_eq "a git dir with a newline in its path blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block newline-path .git/modules/a\nb')"
rm -rf "$W/.git/modules/a"$'\n'"b"

# Worktrees added with --relative-paths point back with a relative
# path; one inside the volume is checked, one outside blocks.
# git ... -h exits 129, so its help is read without pipefail.
_wth=$(git -C "$W" worktree add -h 2>&1 || true)
if grep -q 'relative-paths' <<< "$_wth"; then
    git -C "$W" worktree add -q --detach --relative-paths "$W/rel-in" \
        2>/dev/null
    git -C "$W" worktree add -q --detach --relative-paths \
        "$TMPDIR/rel-out" 2>/dev/null
    echo inside-edit > "$W/rel-in/new-file"
    out=$(scan worktree "$W" full)
    assert_eq "a relative worktree inside the volume is checked" "1" \
        "$(has_line "$out" 'uncommitted dirty rel-in: ?? new-file')"
    assert_eq "a relative worktree inside the volume is not external" "0" \
        "$(has_line "$out" "block external $(cd -P "$W" && pwd -P)/rel-in")"
    git -C "$W" worktree remove --force "$W/rel-in"
    out=$(scan worktree "$W" full)
    assert_eq "a relative worktree outside the volume blocks" "1" \
        "$(has_line "$out" "block external $(cd -P "$TMPDIR" && pwd -P)/rel-out")"
    git -C "$W" worktree remove --force "$TMPDIR/rel-out"
else
    echo "  SKIP: git worktree add --relative-paths not supported"
fi

# A copy of a linked worktree points at an admin dir whose back-pointer
# names the original: the copy blocks instead of going unchecked.
mkdir -p "$W/agent_logs"
git -C "$W" worktree add -q --detach "$W/agent_logs/wt" 2>/dev/null
cp -R "$W/agent_logs/wt" "$W/agent_logs/copy"
echo edit > "$W/agent_logs/copy/edited"
assert_eq "a copied linked worktree blocks" "1" \
    "$(has_line "$(scan worktree "$W" full)" 'block mismatched-worktree agent_logs/copy')"
git -C "$W" worktree remove --force "$W/agent_logs/wt"
rm -rf "$W/agent_logs"

# A reflog file whose name holds a newline is read whole.
_rl=$(g -C "$W" commit-tree -m only-in-odd-reflog "$(git -C "$W" rev-parse 'HEAD^{tree}')")
printf '%s %s t <t@t> 0 +0000\tnote\n' "$(git -C "$W" rev-parse HEAD)" "$_rl" \
    > "$W/.git/logs/notes"$'\n'"saved"
out=$(scan worktree "$W" full)
assert_eq "a reflog file with a newline in its name scans" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "its entries are kept" "commit" \
    "$(git -C "$(imported "$out")" cat-file -t "$_rl" 2>/dev/null)"
rm -f "$W/.git/logs/notes"$'\n'"saved"

# SHA-256 repositories scan and import into a SHA-256 checkout.
S256="$TMPDIR/sha256"
git init -q --object-format=sha256 "$S256"
g -C "$S256" commit -q --allow-empty -m one
g -C "$S256" commit -q --allow-empty -m two
_lost256=$(git -C "$S256" rev-parse HEAD)
git -C "$S256" reset -q --hard HEAD~1
git -C "$S256" repack -q -a -d
_p256=$(find "$S256/.git/objects/pack" -name 'pack-*.pack' | head -1)
# The test runs from a SHA-1 repository; the pack is still read as
# SHA-256 and exempted, not stored as a file.
out=$(cd "$REPO_ROOT" && scan worktree "$S256" full)
assert_eq "a verified SHA-256 pack is not stored as a file" "0" \
    "$(git -C "$(cd "$TMPDIR" && git init -q --object-format=sha256 i256 \
        && git -C i256 fetch -q --no-tags "$out/bundle" 'refs/v/*:refs/r/*' \
        && echo "$TMPDIR/i256")" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk -v f="objects/pack/${_p256##*/}" '$4 == f' | wc -l | tr -d ' ')"
assert_eq "a SHA-256 workspace scans" "" "$(cat "$out/.rc" 2>/dev/null)"
C256="$TMPDIR/sha256-checkout"
git init -q --object-format=sha256 "$C256"
g -C "$C256" commit -q --allow-empty -m base
rc=0
swarm_recovery_import "$C256" "$out" "refs/swarm-recovery/e/s/v" \
    2>/dev/null || rc=$?
assert_eq "it imports into a SHA-256 checkout" "0" "$rc"
assert_eq "its lost commit is there" "commit" \
    "$(git -C "$C256" cat-file -t "$_lost256" 2>/dev/null)"

# ============================================================
echo ""
echo "=== 10. Bare repos: every ref, HEAD and file ==="

B="$TMPDIR/scan-bare.git"
git clone -q --bare "$WORK" "$B"
git -C "$B" update-ref refs/custom/x "$ONE"
git -C "$B" update-ref --no-deref HEAD "$ONE"
git -C "$B" config transfer.hideRefs refs/custom
out=$(scan gitdir "$B" -)
dst=$(imported "$out")
assert_eq "a bare repo scans" "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "every object of the bare is in the bundle" "0" \
    "$(git -C "$dst" cat-file --batch-check < "$out/objects" \
        | grep -c ' missing$' || true)"
assert_eq "its config file is stored" "1" \
    "$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
        | awk '$4 == "config"' | wc -l | tr -d ' ')"

# ============================================================
echo ""
echo "=== 11. Importing into the checkout ==="

IMP="$TMPDIR/import-checkout"
git clone -q "$WORK" "$IMP"
git -C "$IMP" config fetch.prune true
out=$(scan worktree "$W" full)
P1="refs/swarm-recovery/e1/s1/vol"
rc=0
swarm_recovery_import "$IMP" "$out" "$P1" 2>/dev/null || rc=$?
assert_eq "an import succeeds" "0" "$rc"
assert_eq "the lost commit is in the checkout" "commit" \
    "$(git -C "$IMP" cat-file -t "$LOST" 2>/dev/null)"
assert_eq "its refs are under the prefix" "true" \
    "$([ -n "$(git -C "$IMP" for-each-ref "$P1/")" ] && echo true || echo false)"
rc=0
swarm_recovery_import "$IMP" "$out" "$P1" 2>/dev/null || rc=$?
assert_eq "a prefix that holds refs is not written again" "1" "$rc"
_before=$(git -C "$IMP" for-each-ref "$P1/" | wc -l)
swarm_recovery_import "$IMP" "$out" "refs/swarm-recovery/e1/s2/vol" \
    2>/dev/null || true
assert_eq "a second snapshot leaves the first alone" "$_before" \
    "$(git -C "$IMP" for-each-ref "$P1/" | wc -l)"
rc=0
swarm_recovery_import "$IMP" "$out" "refs/heads/x" 2>/dev/null || rc=$?
assert_eq "only the recovery namespace is written" "1" "$rc"
_bad=$(mktemp -d "$TMPDIR/bad.XXXXXX")
echo garbage > "$_bad/bundle"
: > "$_bad/objects"
rc=0
swarm_recovery_import "$IMP" "$_bad" "refs/swarm-recovery/e1/s3/v" \
    2>/dev/null || rc=$?
assert_eq "a bundle that does not verify is refused" "1" "$rc"
# A missing inventory, or objects of it not in the checkout, fail the
# import, however many objects are missing.
_mo=$(scan worktree "$W" full)
rm -f "$_mo/objects"
rc=0
swarm_recovery_import "$IMP" "$_mo" "refs/swarm-recovery/e1/s4/v" \
    2>/dev/null || rc=$?
assert_eq "an import without an inventory fails" "1" "$rc"
_mo=$(scan worktree "$W" full)
for _i in $(seq 1 3000); do
    printf '%040x\n' "$_i"
done >> "$_mo/objects"
rc=0
swarm_recovery_import "$IMP" "$_mo" "refs/swarm-recovery/e1/s5/v" \
    2>/dev/null || rc=$?
assert_eq "an import with many missing objects fails" "1" "$rc"
# An object already in the checkout with the right name but other
# content is caught: fetch skips it, the content check does not.
CR="$TMPDIR/corrupt-src"
git init -q "$CR"
printf 'aaaa\n' > "$CR/f"
g -C "$CR" add f
g -C "$CR" commit -q -m f
_blob=$(git -C "$CR" rev-parse HEAD:f)
CC="$TMPDIR/corrupt-checkout"
git init -q "$CC"
g -C "$CC" commit -q --allow-empty -m base
out=$(scan worktree "$CR" full)
swarm_recovery_import "$CC" "$out" "refs/swarm-recovery/c/s1/v" 2>/dev/null
# Turn the imported pack into loose objects, so one can be replaced.
for _p in "$CC"/.git/objects/pack/pack-*.pack; do
    mv "$_p" "$TMPDIR/cc.pack"
    rm -f "${_p%.pack}".*
    git -C "$CC" unpack-objects -q < "$TMPDIR/cc.pack"
done
_other=$(printf 'bbbb\n' | git -C "$TMPDIR/subsrc" hash-object -w --stdin)
_bf="$CC/.git/objects/${_blob:0:2}/${_blob:2}"
chmod u+w "$_bf"
cp "$TMPDIR/subsrc/.git/objects/${_other:0:2}/${_other:2}" "$_bf"
rc=0
swarm_recovery_verify_checkout "$CC" 2>/dev/null || rc=$?
assert_eq "a checkout with a corrupt object fails verification" "1" "$rc"
# Two objects with each other's contents: every name is present, only
# the content check sees it.
printf 'cccc\n' > "$CR/g"
g -C "$CR" add g
g -C "$CR" commit -q -m g
_bg=$(git -C "$CR" rev-parse HEAD:g)
rm -rf "$CC"
git init -q "$CC"
g -C "$CC" commit -q --allow-empty -m base
out=$(scan worktree "$CR" full)
swarm_recovery_import "$CC" "$out" "refs/swarm-recovery/c/s1/v" 2>/dev/null
for _p in "$CC"/.git/objects/pack/pack-*.pack; do
    mv "$_p" "$TMPDIR/cc.pack"
    rm -f "${_p%.pack}".*
    git -C "$CC" unpack-objects -q < "$TMPDIR/cc.pack"
done
rc=0
swarm_recovery_verify_checkout "$CC" 2>/dev/null || rc=$?
assert_eq "a sound checkout passes verification" "0" "$rc"
_fa="$CC/.git/objects/${_blob:0:2}/${_blob:2}"
_fb="$CC/.git/objects/${_bg:0:2}/${_bg:2}"
chmod u+w "$_fa" "$_fb"
cp "$_fa" "$TMPDIR/swap.tmp"
cp "$_fb" "$_fa"
cp "$TMPDIR/swap.tmp" "$_fb"
rc=0
swarm_recovery_import "$CC" "$out" "refs/swarm-recovery/c/s2/v" \
    2>/dev/null || rc=$?
assert_eq "presence checks alone pass with swapped objects" "0" "$rc"
rc=0
swarm_recovery_verify_checkout "$CC" 2>/dev/null || rc=$?
assert_eq "swapped objects fail verification" "1" "$rc"
_id=$(swarm_recovery_snapshot_id)
assert_eq "snapshot ids are time and random hex" "true" \
    "$(grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' <<< "$_id" \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 12. The checkout must keep its objects itself ==="

ST="$TMPDIR/storage"
RT="$TMPDIR/storage-runtime"
mkdir -p "$RT"
git clone -q "$WORK" "$ST"
storage() {
    local rc=0
    swarm_checkout_storage_ok "$ST" "$RT" "$@" 2>/dev/null || rc=$?
    printf '%s' "$rc"
}
assert_eq "a plain clone is fine" "0" "$(storage)"
echo "$BARE/objects" > "$ST/.git/objects/info/alternates"
assert_eq "alternates are refused" "1" "$(storage)"
rm "$ST/.git/objects/info/alternates"
ln -s "$RT" "$ST/.git/objects/linked"
assert_eq "a symlink in the object store is refused" "1" "$(storage)"
rm "$ST/.git/objects/linked"
git clone -q --depth 1 "file://$WORK" "$TMPDIR/shallow" 2>/dev/null
rc=0
swarm_checkout_storage_ok "$TMPDIR/shallow" "$RT" 2>/dev/null || rc=$?
assert_eq "a shallow clone is refused" "1" "$rc"
# A failure of the pack/info listing alone fails the check.  Called
# in a command substitution, so the find override ends with it.  (Bash
# 3.2 cannot parse a case statement written inside $(...).)
storage_failing_pack_find() {
    # shellcheck disable=SC2329
    find() {
        case "$1" in
            */objects/pack) return 1 ;;
        esac
        command find "$@"
    }
    storage "$@"
}
mkdir -p "$RT/target-x"
assert_eq "a failed pack listing fails the check" "1" \
    "$(storage_failing_pack_find "$RT/target-x")"
rm -rf "$RT/target-x"
ln -s "$RT" "$ST/.git/refs/swarm-recovery"
assert_eq "recovery refs stored through a symlink are refused" "1" \
    "$(storage)"
rm "$ST/.git/refs/swarm-recovery"
git -C "$ST" config remote.origin.promisor 1
assert_eq "a promisor remote set to 1 is refused" "1" "$(storage)"
git -C "$ST" config --unset remote.origin.promisor
git -C "$ST" repack -q -a -d
_pack=$(find "$ST/.git/objects/pack" -name '*.pack' | head -1)
mkdir -p "$RT/upstream.git/objects/pack"
ln "$_pack" "$RT/upstream.git/objects/pack/shared.pack"
assert_eq "a pack file shared with a deletion target is refused" "1" \
    "$(storage "$RT/upstream.git")"
rm -rf "$RT/upstream.git"
mkdir -p "$RT/upstream.git"
assert_eq "an unrelated deletion target is fine" "0" \
    "$(storage "$RT/upstream.git")"
# Targets are compared with the git dir as well as its object store,
# whether or not this host has them (a volume's Mountpoint may be a path
# in Docker's own machine); a link on the way is followed.
assert_eq "a target inside the git dir, outside objects/, is refused" "1" \
    "$(storage "$ST/.git/hooks")"
assert_eq "a target that does not exist, inside the git dir, is refused" \
    "1" "$(storage "$ST/.git/volumes/x/_data")"
assert_eq "a target around the git dir is refused" "1" "$(storage "$ST")"
assert_eq "a target elsewhere that this host lacks is fine" "0" \
    "$(storage "/nonexistent-$$/var/lib/docker/volumes/x/_data")"
ln -s "$ST/.git" "$TMPDIR/gitalias"
assert_eq "a missing target behind a link into the git dir is refused" "1" \
    "$(storage "$TMPDIR/gitalias/volumes/x/_data")"
rm "$TMPDIR/gitalias"
# A linked worktree's own git dir, moved away from the common one: the
# targets are compared with it too.
WTP="$TMPDIR/wt-admin"
mkdir -p "$WTP"
git -C "$ST" worktree add -q "$TMPDIR/storage-wt" -b storage-wt
_wtgd=$(git -C "$TMPDIR/storage-wt" rev-parse --absolute-git-dir)
mv "$_wtgd" "$WTP/gd"
printf 'gitdir: %s\n' "$WTP/gd" > "$TMPDIR/storage-wt/.git"
(cd -P "$ST/.git" && pwd -P) > "$WTP/gd/commondir"
printf '%s\n' "$TMPDIR/storage-wt/.git" > "$WTP/gd/gitdir"
storage_wt() {
    local rc=0
    swarm_checkout_storage_ok "$TMPDIR/storage-wt" "$RT" "$@" \
        2>/dev/null || rc=$?
    printf '%s' "$rc"
}
assert_eq "a linked worktree is fine" "0" "$(storage_wt)"
assert_eq "its own git dir as a target is refused" "1" \
    "$(storage_wt "$WTP/gd")"
assert_eq "a target inside that git dir is refused" "1" \
    "$(storage_wt "$WTP/gd/logs")"
assert_eq "a target around that git dir is refused" "1" \
    "$(storage_wt "$WTP")"
assert_eq "a target that does not exist, inside that git dir, is refused" \
    "1" "$(storage_wt "$WTP/gd/volumes/x/_data")"
assert_eq "and the worktree still works" "storage-wt" \
    "$(git -C "$TMPDIR/storage-wt" symbolic-ref --short HEAD)"
# The same git dir bind-mounted at a target (in a user and mount
# namespace of its own) has another path but the same inodes.
if [ -r /proc/self/mountinfo ] && unshare -rm true 2>/dev/null; then
    mkdir "$RT/target-wt"
    rc=0
    unshare -rm "$BASH" -c '
        mount --bind "$1" "$2" || exit 9
        # shellcheck source=../lib/project.sh
        source "$3/lib/project.sh"
        # shellcheck source=../lib/preserve.sh
        source "$3/lib/preserve.sh"
        swarm_checkout_storage_ok "$4" "$5" "$2"' sh \
        "$WTP/gd" "$RT/target-wt" "$REPO_ROOT" "$TMPDIR/storage-wt" "$RT" \
        > "$TMPDIR/bind.out" 2>&1 || rc=$?
    assert_eq "that git dir bind-mounted at a target is refused" "1" "$rc"
    assert_eq "as sharing files with it" "1" \
        "$(grep -c 'shares files with what cleanup deletes' \
            "$TMPDIR/bind.out" || true)"
    rmdir "$RT/target-wt"
else
    echo "  SKIP: no bind mount here (unshare -rm)"
fi

echo ""
echo "=== 13. Files mode keeps what is left of a repository ==="

# What a deletion left of a repository: no history to walk, so every
# file is kept as a blob; files under objects/ whatever their size.
FM="$TMPDIR/remnant"
mkdir -p "$FM/objects/pack" "$FM/objects/ab"
head -c 5000 /dev/urandom > "$FM/objects/pack/pack-1.pack"
head -c 3000 /dev/urandom > "$FM/objects/ab/cdef"
head -c 4000 /dev/urandom > "$FM/rescue.patch"
echo small > "$FM/config"
ln -s ../config "$FM/link"
out=$(scan files "$FM" sha1 SWARM_SCAN_FILE_LIMIT=1000)
assert_eq "files mode succeeds" "no" \
    "$([ -e "$out/.rc" ] && echo yes || echo no)"
assert_eq "a large file outside objects/ is uncommitted" "1" \
    "$(has_line "$out" 'uncommitted large-file rescue.patch 4000')"
assert_eq "nothing else is reported" "1" "$(grep -c . "$out/report" || true)"
dst=$(imported "$out")
fl="$TMPDIR/fm.files"
git -C "$dst" cat-file blob refs/r/0/files | tr '\0' '\n' > "$fl"
for f in config link objects/ab/cdef objects/pack/pack-1.pack; do
    assert_eq "files mode keeps ${f}" "1" \
        "$(awk -v f="$f" '$4 == f' "$fl" | grep -c . || true)"
done
k=$(awk '$4 == "objects/pack/pack-1.pack" { print $1 }' "$fl")
assert_eq "a pack over the limit is kept byte for byte" \
    "$(git hash-object --no-filters "$FM/objects/pack/pack-1.pack")" \
    "$(git -C "$dst" rev-parse "refs/r/0/f/$k")"
k=$(awk '$4 == "link" { print $1 }' "$fl")
assert_eq "a link is kept as its target" "../config" \
    "$(git -C "$dst" cat-file blob "refs/r/0/f/$k")"
assert_eq "the inventory of objects is empty" "0" \
    "$(grep -c . "$out/objects" || true)"
out=$(scan files "$FM" sha256)
dst=$(mktemp -d "$TMPDIR/dst.XXXXXX")
git init -q --object-format=sha256 "$dst"
git -C "$dst" fetch -q --no-tags "$out/bundle" 'refs/v/*:refs/r/*'
assert_eq "a sha256 bundle goes into a sha256 repository" "1" \
    "$(git -C "$dst" for-each-ref refs/r/0/files | grep -c . || true)"
out=$(scan files "$FM" "")
assert_eq "files mode needs the object format" "rc=3" "$(cat "$out/.rc")"
mkfifo "$FM/fifo"
out=$(scan files "$FM" sha1)
assert_eq "a special file fails the scan" "rc=3" "$(cat "$out/.rc")"
# A read of one of the scan's own lists that fails stops the scan
# (status 3) instead of ending the loop as the end of the list would: a
# find or a cat first on PATH leaves a directory where the file list,
# or the list of files to keep, was (EISDIR).
RBD="$TMPDIR/rb-remnant"
mkdir -p "$RBD/objects"
echo one > "$RBD/a"
echo two > "$RBD/objects/b"
_rb="$TMPDIR/rb-bin"
mkdir -p "$_rb"
cat > "$_rb/find" <<'EOF'
#!/bin/bash
PATH="$RB_PATH" find "$@"
rc=$?
if [ -n "${RB_FIND:-}" ] && [ -f "$RB_FIND" ]; then
    rm -f "$RB_FIND" && mkdir "$RB_FIND"
fi
exit "$rc"
EOF
cat > "$_rb/cat" <<'EOF'
#!/bin/bash
if [ -n "${RB_CAT_SRC:-}" ] && [ "${1:-}" = "$RB_CAT_SRC" ]; then
    PATH="$RB_PATH" cat "$1" || exit
    rm -f "$RB_CAT" && mkdir "$RB_CAT"
    exit 0
fi
PATH="$RB_PATH" exec cat "$@"
EOF
chmod +x "$_rb/find" "$_rb/cat"
# Scan $RBD in files mode with the read of list WHICH (find, cat or
# none) failing; print the status.
rb_scan() {
    local rc=0 out
    out=$(mktemp -d "$TMPDIR/rb.XXXXXX")
    case "$1" in
        none) set -- ;;
        find) set -- RB_FIND="$out/.flist0" ;;
        cat) set -- RB_CAT_SRC="$out/.fnl" RB_CAT="$out/.fkeep" ;;
    esac
    env RB_PATH="$PATH" PATH="$_rb:$PATH" "$@" \
        bash "$SCAN" files "$RBD" sha1 "$out" > "$TMPDIR/rb.log" 2>&1 \
        || rc=$?
    printf '%s' "$rc"
}
assert_eq "with its lists read in full, the scan works" "0" \
    "$(rb_scan none)"
assert_eq "a read of the file list that fails stops the scan" "3" \
    "$(rb_scan find)"
assert_eq "saying so" "1" \
    "$(grep -c 'cannot read a list' "$TMPDIR/rb.log" || true)"
assert_eq "so does one of the list of files to keep" "3" \
    "$(rb_scan cat)"
assert_eq "saying so" "1" \
    "$(grep -c 'cannot read a list' "$TMPDIR/rb.log" || true)"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
