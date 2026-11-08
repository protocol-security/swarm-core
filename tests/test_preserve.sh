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
# Git follows an include wherever it points (a FIFO there would hang
# the host), and agents can write the bare repo's config: the check
# stops before git reads it.
git -C "$BARE" config include.path inc
rc=0
swarm_preservation_check "$BARE" "$WORK" >/dev/null 2>"$TMPDIR/inc.err" \
    || rc=$?
assert_eq "a config include: status 2" "2" "$rc"
assert_eq "and says so" "1" \
    "$(grep -c 'includes other files' "$TMPDIR/inc.err" || true)"
git -C "$BARE" config --unset include.path

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

# An ignore pattern that names .claude/ makes Git show that directory as
# one ignored entry when nothing in it is tracked.  Holding only the
# engine's .claude/settings.local.json, it is not work; holding anything
# else (as the file system lists it: Git skips a .GIT when it ignores
# case), or in a container's layer, it is reported whole, as one entry;
# another ignored directory stays one entry.
cp "$W/.git/info/exclude" "$TMPDIR/exclude.saved"
printf '.claude/\nbig/\n' >> "$W/.git/info/exclude"
mkdir -p "$W/.claude" "$W/big/deep"
echo '{}' > "$W/.claude/settings.local.json"
echo x > "$W/big/deep/f1"
echo y > "$W/big/f2"
# Print "<rc file or none> <count of exact LINE in the report>".
claude_entry() {
    local out
    out=$(scan worktree "$W" "${1:-full}")
    printf '%s %s' "$(cat "$out/.rc" 2>/dev/null || echo none)" \
        "$(grep -cxF 'uncommitted ignored .: .claude/' "$out/report" || true)"
}
assert_eq "an ignored .claude/ with only the engine's settings is not work" \
    "none 0" "$(claude_entry)"
out=$(scan worktree "$W" full)
assert_eq "another ignored directory is one entry" "1" \
    "$(has_line "$out" 'uncommitted ignored .: big/')"
assert_eq "none of its files listed" "0" \
    "$(grep -c 'big/.' "$out/report" || true)"
assert_eq "in a layer, the ignored .claude/ is reported" "none 1" \
    "$(claude_entry layer)"
# Git ignoring case, as it does on macOS, skips .GIT as it would .git.
_cl_ic=$(git -C "$W" config --get core.ignoreCase || true)
git -C "$W" config core.ignoreCase true
for _cl_case in "notes.txt:a file of the agent's" "sub/x:a nested one" \
        ".GIT/notes.txt:one under a .GIT, which Git may skip" \
        ".hidden:a hidden one"; do
    mkdir -p "$(dirname "$W/.claude/${_cl_case%%:*}")"
    echo w > "$W/.claude/${_cl_case%%:*}"
    assert_eq "with ${_cl_case#*:} next to the settings: reported whole" \
        "none 1" "$(claude_entry)"
    rm -rf "$W/.claude/${_cl_case%%:*}"
    [ "${_cl_case%%/*}" = "${_cl_case%%:*}" ] \
        || rm -rf "$W/.claude/${_cl_case%%/*}"
done
if [ -n "$_cl_ic" ]; then
    git -C "$W" config core.ignoreCase "$_cl_ic"
else
    git -C "$W" config --unset core.ignoreCase
fi
mv "$W/.claude/settings.local.json" "$TMPDIR/settings.saved"
ln -s "$TMPDIR/settings.saved" "$W/.claude/settings.local.json"
assert_eq "settings that are a symlink: reported whole" "none 1" \
    "$(claude_entry)"
rm -f "$W/.claude/settings.local.json"
mkdir "$W/.claude/settings.local.json"
assert_eq "settings that are a directory: reported whole" "none 1" \
    "$(claude_entry)"
rmdir "$W/.claude/settings.local.json"
cp "$TMPDIR/exclude.saved" "$W/.git/info/exclude"
rm -rf "$W/.claude" "$W/big"

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
# repositories.
GL="$TMPDIR/glob*root"
git init -q "$GL"
g -C "$GL" commit -q --allow-empty -m g
mkdir -p "$GL/agent_logs"
git init -q "$GL/agent_logs/root"
assert_eq "a nested repo under a root with * in its path is found" "1" \
    "$(grep -cE '^gitdir [0-9]+ agent_logs/root/[.]git$' \
        "$(scan worktree "$GL" full)/report" || true)"

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
# In a bare repo too, before any git command reads its config.
IB="$TMPDIR/inc-bare.git"
git init -q --bare "$IB"
printf '[core]\n' > "$IB/inc.cfg"
git -C "$IB" config includeIf.onbranch:x.path inc.cfg
out=$(scan gitdir "$IB" -)
assert_eq "a config include in a bare repo blocks" "1" \
    "$(has_line "$out" 'block config-include ')"
assert_eq "and stops the scan, with no bundle" "false" \
    "$([ -e "$out/bundle" ] && echo true || echo false)"
rm -f "$IB/config.worktree"
mkfifo "$IB/config.worktree"
git -C "$IB" config --unset includeIf.onbranch:x.path
out=$(scan gitdir "$IB" -)
assert_eq "a config file that is no regular file blocks" "1" \
    "$(has_line "$out" 'block special-file ')"
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
assert_eq "an ordinary repository nested in the workspace does not block" \
    "0" "$(has_line "$(scan worktree "$W" full)" 'block embedded inner')"
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
# A submodule directory without its .git is no checkout, and status
# shows nothing below it: every file there is listed.
assert_eq "an empty uninitialized submodule directory is no work" "0" \
    "$(has_line "$out" 'uncommitted dirty .: ?? lib/')"
mkdir "$W/lib/deep"
echo work > "$W/lib/deep/work.txt"
out=$(scan worktree "$W" full)
assert_eq "a file in an uninitialized submodule directory is listed" \
    "1" "$(has_line "$out" 'uncommitted dirty .: ?? lib/deep/work.txt')"
rm -r "$W/lib/deep"
# A repository nested there is a checkout of its own, carried and
# checked on its own: none of its files is listed for the submodule
# directory, while a file beside it still is.
git init -q "$W/lib/inner"
g -C "$W/lib/inner" commit -q --allow-empty -m inner
echo beside > "$W/lib/beside.txt"
out=$(scan worktree "$W" full)
assert_eq "a repository in that directory is carried on its own" "1" \
    "$(grep -cE '^gitdir [0-9]+ lib/inner/\.git$' "$out/report" || true)"
assert_eq "  none of its files listed for the directory" "0" \
    "$(grep -c '^uncommitted dirty \.: ?? lib/inner/' "$out/report" \
        || true)"
assert_eq "  a file beside it still listed" "1" \
    "$(has_line "$out" 'uncommitted dirty .: ?? lib/beside.txt')"
rm -rf "$W/lib/inner" "$W/lib/beside.txt"

# A core.worktree setting cannot point status at another directory.
mkdir -p "$TMPDIR/clean-elsewhere"
echo dirty-again >> "$W/.gitmodules"
git -C "$W" config core.worktree "$TMPDIR/clean-elsewhere"
out=$(scan worktree "$W" full)
assert_eq "a core.worktree outside the volume blocks" "1" \
    "$(has_line "$out" 'block core-worktree .git ')"
# Refused anyway, it stops the scan before git status, which would go
# where core.worktree says (and into the repositories there).
assert_eq "and the scan stops before status" "0" \
    "$(has_line "$out" 'uncommitted dirty')"
git -C "$W" config --unset core.worktree
git -C "$W" checkout -q -- .gitmodules

# A graft that makes an unreached commit look reached does not drop it.
GRAFTED=$(g -C "$W" commit-tree -m grafted "$(git -C "$W" rev-parse 'HEAD^{tree}')")
echo "$(git -C "$W" rev-parse HEAD) $GRAFTED" > "$W/.git/info/grafts"
out=$(scan worktree "$W" full)
assert_eq "a grafted parent is still kept" "commit" \
    "$(git -C "$(imported "$out")" cat-file -t "$GRAFTED" 2>/dev/null)"
rm -f "$W/.git/info/grafts"

# A loose file that is no object, next to a packed copy of the object
# its name gives: Git reads the packed copy, so the loose file's bytes
# are stored as a file.
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
# Which copy Git hands out for these two small blobs: Git 2.56 can give
# the loose file's content (the other blob), and recording the object
# then fails on its hash, so the scan stops (nothing is deleted on its
# word); older Git gives the packed copy, and the scan stores both loose
# files.
if [ "$(git -C "$W" cat-file -p "$_ba" 2>/dev/null)" = "swap b" ]; then
    assert_eq "swapped loose files that Git reads first stop the scan" \
        "rc=3" "$(cat "$out/.rc" 2>/dev/null)"
    assert_eq "on a hash mismatch" "yes" \
        "$(grep -q 'hash mismatch' "$out/.err" 2>/dev/null \
            && echo yes || echo no)"
else
    assert_eq "loose files with swapped contents are both stored" "2" \
        "$(git -C "$(imported "$out")" cat-file -p refs/r/0/files \
            | tr '\0' '\n' \
            | awk -v a="objects/${_ba:0:2}/${_ba:2}" \
                -v b="objects/${_bb:0:2}/${_bb:2}" '$4 == a || $4 == b' \
            | wc -l | tr -d ' ')"
fi
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
        "$(has_line "$out" "rel-out/.git (relative, outside)")"
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

# ============================================================
echo ""
echo "=== 14. Agent-written settings and helper output stay contained ==="

# A clean filter that leaves a marker when Git runs it: what git status
# would run, through a filter an agent configured, inside the scan.
# The control lines show git status alone does run it.  Each change
# keeps the file's size, so that Git must read the content (through
# the filter) to tell.
fl_repo() {
    local d="$1"
    git init -q "$d"
    echo a > "$d/f"
    echo '* filter=x' > "$d/.gitattributes"
    g -C "$d" add f .gitattributes
    g -C "$d" commit -qm one
}
FLM="$TMPDIR/filter-ran"
FW="$TMPDIR/fw"
fl_repo "$FW"
git -C "$FW" config filter.x.clean "touch $FLM; cat"
echo b > "$FW/f"
git -C "$FW" status --porcelain >/dev/null 2>&1 || true
assert_eq "control: git status runs the repository's clean filter" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW" full)
assert_eq "a filter driver in the repository's config blocks" "1" \
    "$(has_line "$out" 'block filter-driver .git filter.x.clean')"
assert_eq "and the scan never runs it" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# The same in config.worktree, read with extensions.worktreeConfig.
FW2="$TMPDIR/fw2"
fl_repo "$FW2"
git -C "$FW2" config extensions.worktreeConfig true
git -C "$FW2" config --worktree filter.x.clean "touch $FLM; cat"
echo b > "$FW2/f"
out=$(scan worktree "$FW2" full)
assert_eq "a filter driver in config.worktree blocks" "1" \
    "$(has_line "$out" 'block filter-driver .git filter.x.clean')"
assert_eq "and is never run" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# Through an include: the include blocks, and status never runs.
FW3="$TMPDIR/fw3"
fl_repo "$FW3"
printf '[filter "x"]\n\tclean = touch %s; cat\n' "$FLM" > "$TMPDIR/inc.cfg"
git -C "$FW3" config include.path "$TMPDIR/inc.cfg"
echo b > "$FW3/f"
git -C "$FW3" status --porcelain >/dev/null 2>&1 || true
assert_eq "control: git status runs an included filter" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW3" full)
assert_eq "an include blocks" "1" "$(has_line "$out" 'block config-include .git')"
assert_eq "and the scan stops before status" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
assert_eq "with no bundle" "false" \
    "$([ -e "$out/bundle" ] && echo true || echo false)"
# In a submodule's git dir: status looks into submodules.
FSUB="$TMPDIR/fsub-src"
fl_repo "$FSUB"
FW4="$TMPDIR/fw4"
git init -q "$FW4"
g -C "$FW4" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW4" commit -qm add-sub
git -C "$FW4/sub" config filter.x.clean "touch $FLM; cat"
echo b > "$FW4/sub/f"
git -C "$FW4" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: git status in the parent runs a submodule's filter" \
    "true" "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW4" full)
assert_eq "a filter driver in a submodule's git dir blocks" "1" \
    "$(has_line "$out" 'block filter-driver .git/modules/sub filter.x.clean')"
assert_eq "and is never run" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# A submodule whose .git names a git dir outside the checkout: the
# embedded check runs before status, which would use that git dir's
# config.
FW5="$TMPDIR/fw5"
git init -q "$FW5"
g -C "$FW5" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW5" commit -qm add-sub
mv "$FW5/.git/modules/sub" "$TMPDIR/ext-sub.git"
printf 'gitdir: %s\n' "$TMPDIR/ext-sub.git" > "$FW5/sub/.git"
git config -f "$TMPDIR/ext-sub.git/config" core.worktree "$FW5/sub"
git config -f "$TMPDIR/ext-sub.git/config" filter.x.clean "touch $FLM; cat"
echo b > "$FW5/sub/f"
git -C "$FW5" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: git status runs the outside git dir's filter" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW5" full)
assert_eq "a submodule with its git dir outside blocks" "1" \
    "$(has_line "$out" 'block embedded sub')"
assert_eq "before status, which never runs its filter" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# A repository below the checkout whose path holds a newline cannot be
# checked; status would look into it (a gitlink with its own .git), so
# the scan stops first.
FW7="$TMPDIR/fw7"
git init -q "$FW7"
g -C "$FW7" commit -q --allow-empty -m one
_nlsub="$FW7/odd"$'\n'"sub"
fl_repo "$_nlsub"
git -C "$_nlsub" config filter.x.clean "touch $FLM; cat"
git -C "$FW7" update-index --add --cacheinfo \
    "160000,$(git -C "$_nlsub" rev-parse HEAD),odd"$'\n'"sub"
g -C "$FW7" commit -qm add-gitlink
echo b > "$_nlsub/f"
git -C "$FW7" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: git status looks into a gitlink at a newline path" \
    "true" "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW7" full)
assert_eq "a repository at a newline path blocks" "1" \
    "$(has_line "$out" 'block newline-path odd')"
assert_eq "and the scan stops before status" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# A submodule whose core.worktree is outside, holding a repository at a
# gitlink there with a filter: the scan stops before status.
FW8="$TMPDIR/fw8"
git init -q "$FW8"
g -C "$FW8" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW8" commit -qm add-sub
EXT="$TMPDIR/ext-wt"
mkdir -p "$EXT"
cp -R "$FW8/sub/." "$EXT/"
rm -f "$EXT/.git"
fl_repo "$EXT/inner"
git -C "$EXT/inner" config filter.x.clean "touch $FLM; cat"
git config -f "$FW8/.git/modules/sub/config" core.worktree "$EXT"
git --git-dir="$FW8/.git/modules/sub" --work-tree="$EXT" update-index --add \
    --cacheinfo "160000,$(git -C "$EXT/inner" rev-parse HEAD),inner"
echo b > "$EXT/inner/f"
git -C "$FW8" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: status follows core.worktree into a repository there" \
    "true" "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW8" full)
assert_eq "a submodule's core.worktree outside blocks" "1" \
    "$(has_line "$out" 'block core-worktree .git/modules/sub')"
assert_eq "and the scan stops before status" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# A submodule whose core.worktree is inside the git dir, where the
# search for repositories below ROOT does not look, with a repository at
# a gitlink there: the scan stops before status.
FW9="$TMPDIR/fw9"
git init -q "$FW9"
g -C "$FW9" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW9" commit -qm add-sub
HID="$FW9/.git/hidden"
mkdir -p "$HID"
cp -R "$FW9/sub/." "$HID/"
rm -f "$HID/.git"
fl_repo "$HID/inner"
git -C "$HID/inner" config filter.x.clean "touch $FLM; cat"
git config -f "$FW9/.git/modules/sub/config" core.worktree "$HID"
git --git-dir="$FW9/.git/modules/sub" --work-tree="$HID" update-index --add \
    --cacheinfo "160000,$(git -C "$HID/inner" rev-parse HEAD),inner"
echo b > "$HID/inner/f"
git -C "$FW9" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: status follows a core.worktree inside the git dir" \
    "true" "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW9" full)
assert_eq "a work tree inside the git dir blocks" "1" \
    "$(has_line "$out" 'block gitdir-worktree .git/modules/sub')"
assert_eq "and the scan stops before status" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# A submodule whose git dir is not one the scan checked (its objects is
# an executable file, which Git takes for a repository and this scan's
# list of git dirs does not): blocked before status.
FW10="$TMPDIR/fw10"
git init -q "$FW10"
g -C "$FW10" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW10" commit -qm add-sub
mv "$FW10/.git/modules/sub/objects" "$FW10/.git/modules/sub/objects.d"
printf '#!/bin/sh\n' > "$FW10/.git/modules/sub/objects"
chmod +x "$FW10/.git/modules/sub/objects"
git config -f "$FW10/.git/modules/sub/config" filter.x.clean "touch $FLM; cat"
echo b > "$FW10/sub/f"
git -C "$FW10" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
if [ -e "$FLM" ]; then
    rm -f "$FLM"
    out=$(scan worktree "$FW10" full)
    assert_eq "a submodule whose git dir the scan did not check blocks" "1" \
        "$(has_line "$out" 'block embedded sub')"
    assert_eq "and its filter never runs" "false" \
        "$([ -e "$FLM" ] && echo true || echo false)"
else
    echo "  SKIP: this Git does not take that git dir for a repository"
fi
# A gitfile with a line break inside: Git keeps it and goes elsewhere;
# the scan blocks instead of checking only its first line.
FW11="$TMPDIR/fw11"
git init -q "$FW11"
g -C "$FW11" -c protocol.file.allow=always submodule add -q "$FSUB" sub \
    >/dev/null 2>&1
g -C "$FW11" commit -qm add-sub
cp -R "$FW11/.git/modules/sub" "$TMPDIR/out11.git"
git config -f "$TMPDIR/out11.git/config" core.worktree "$FW11/sub"
git config -f "$TMPDIR/out11.git/config" filter.x.clean "touch $FLM; cat"
mkdir "$FW11/.git/modules/safe"$'\n'
# Up from .git/modules/safe<LF> to /, counted on the resolved path (on
# macOS /var is a link), then down to the outside repository.
_mods=$(cd -P "$FW11/.git/modules" && pwd -P)
_out=$(cd -P "$TMPDIR/out11.git" && pwd -P)
_up=$(printf '%s' "$_mods" | tr -cd / | sed 's|/|../|g')
printf 'gitdir: %s\n/../%s%s\n' "$_mods/safe" "$_up" "${_out#/}" \
    > "$FW11/sub/.git"
echo b > "$FW11/sub/f"
git -C "$FW11" status --porcelain --ignore-submodules=none >/dev/null 2>&1 \
    || true
assert_eq "control: Git follows the gitfile past its line break" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW11" full)
assert_eq "a gitfile with a line break blocks" "1" \
    "$(has_line "$out" 'block embedded sub (not one gitdir line in .git)')"
assert_eq "and the outside filter never runs" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# An index an agent wrote by hand, with a gitlink inside the git dir
# (.git/hidden), whose .git names an outside repository with a filter:
# the scan's status does not look into submodules, so it never runs.
if command -v perl >/dev/null 2>&1; then
    FW12="$TMPDIR/fw12"
    fl_repo "$FW12"
    fl_repo "$TMPDIR/out12"
    git -C "$TMPDIR/out12" config filter.x.clean "touch $FLM; cat"
    git -C "$FW12" update-index --add --cacheinfo \
        "160000,$(git -C "$TMPDIR/out12" rev-parse HEAD),AAAA/hidden"
    perl -0777 -i -pe 'use Digest::SHA qw(sha1); s/AAAA/.git/g;
        $_ = substr($_, 0, -20); $_ .= sha1($_);' "$FW12/.git/index"
    mkdir -p "$FW12/.git/hidden"
    cp "$TMPDIR/out12/f" "$TMPDIR/out12/.gitattributes" "$FW12/.git/hidden/"
    git config -f "$TMPDIR/out12/.git/config" core.worktree \
        "$FW12/.git/hidden"
    printf 'gitdir: %s\n' "$TMPDIR/out12/.git" > "$FW12/.git/hidden/.git"
    echo b > "$FW12/.git/hidden/f"
    git -C "$FW12" status --porcelain --ignore-submodules=none \
        >/dev/null 2>&1 || true
    if [ -e "$FLM" ]; then
        rm -f "$FLM"
        out=$(scan worktree "$FW12" full)
        assert_eq "an index entry an agent put in the git dir blocks" "1" \
            "$(has_line "$out" 'block index-in-gitdir .: .git/hidden')"
        assert_eq "before status reads it: its filter never runs" \
            "false" "$([ -e "$FLM" ] && echo true || echo false)"
        # The same entry written as ./.git/hidden, and a/../.git/hidden:
        # any path Git would not write blocks.
        for _np in './.git/hidden' 'q/../.git/hidden'; do
            _fw="$TMPDIR/fw12-$(printf '%s' "$_np" | tr -c 'a-z' '_')"
            cp -R "$FW12" "$_fw"
            git -C "$_fw" read-tree --empty
            git -C "$_fw" update-index --add --cacheinfo \
                "160000,$(git -C "$TMPDIR/out12" rev-parse HEAD),$(printf '%s' "$_np" | tr './' 'XY')"
            # Written under a name of the same length, then renamed in
            # the file, its checksum made again.
            _from=$(printf '%s' "$_np" | tr './' 'XY')
            FROM="$_from" TO="$_np" perl -0777 -i -pe '
                use Digest::SHA qw(sha1);
                s/\Q$ENV{FROM}\E/$ENV{TO}/g;
                $_ = substr($_, 0, -20); $_ .= sha1($_);' "$_fw/.git/index"
            out=$(scan worktree "$_fw" full)
            assert_eq "an index entry ${_np} blocks" "1" \
                "$(has_line "$out" "block index-in-gitdir .: ${_np}")"
            assert_eq "and its filter never runs" "false" \
                "$([ -e "$FLM" ] && echo true || echo false)"
        done
    else
        echo "  SKIP: this Git does not follow a gitlink inside the git dir"
    fi
else
    echo "  SKIP: no perl to write an index by hand"
fi
# A commondir read as Git reads it: "shared<CR><LF>" names .git/shared
# (trailing CR and LF dropped), not a listed .git/shared<CR> next to it.
FW13="$TMPDIR/fw13"
fl_repo "$FW13"
mkdir "$FW13/.git/shared"
mv "$FW13/.git/objects" "$FW13/.git/refs" "$FW13/.git/config" \
    "$FW13/.git/shared/"
git config -f "$FW13/.git/shared/config" filter.x.clean "touch $FLM; cat"
git init -q --bare "$FW13/.git/shared"$'\r'
printf 'shared\r\n' > "$FW13/.git/commondir"
echo b > "$FW13/f"
git -C "$FW13" status --porcelain >/dev/null 2>&1 || true
assert_eq "control: Git uses the common dir without the CR" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW13" full)
assert_eq "that common dir, which the scan does not list, blocks" "1" \
    "$(grep -c '^block commondir \.git .*/\.git/shared$' "$out/report" || true)"
assert_eq "and its filter never runs" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
# The global and system config of whoever runs the scan do not apply:
# a filter defined there is not run, and nothing blocks for it.
GH="$TMPDIR/ghome"
mkdir -p "$GH"
printf '[filter "x"]\n\tclean = touch %s; cat\n' "$FLM" > "$GH/.gitconfig"
FW6="$TMPDIR/fw6"
fl_repo "$FW6"
echo b > "$FW6/f"
HOME="$GH" GIT_CONFIG_GLOBAL="$GH/.gitconfig" git -C "$FW6" status \
    --porcelain >/dev/null 2>&1 || true
assert_eq "control: git status runs a global filter" "true" \
    "$([ -e "$FLM" ] && echo true || echo false)"
rm -f "$FLM"
out=$(scan worktree "$FW6" full HOME="$GH" XDG_CONFIG_HOME="$GH/xdg")
assert_eq "the scan reads no global config: the filter does not run" \
    "false" "$([ -e "$FLM" ] && echo true || echo false)"
assert_eq "and the change shows as such" "1" \
    "$(has_line "$out" 'uncommitted dirty .:  M f')"

# A bare repo an agent turned into a partial clone, with a ref whose
# object is missing and a local "promisor" remote whose uploadpack
# command leaves a marker, protocol.file.allow=always included: the
# host's reads never run it (no lazy fetch, no transport), on any Git.
PRM="$TMPDIR/promisor-ran"
pr_bare() {
    local d="$1"
    git clone -q --bare "$WORK" "$d"
    # The preservation check reads the agent refs only.
    git -C "$d" update-ref refs/heads/agent-work HEAD
    git -C "$d" repack -q -a -d
    rm -f "${d:?}"/objects/pack/pack-*
    git -C "$d" config core.repositoryformatversion 1
    git -C "$d" config extensions.partialClone origin
    git -C "$d" config remote.origin.url "$WORK"
    git -C "$d" config remote.origin.promisor true
    git -C "$d" config remote.origin.uploadpack "touch $PRM; git-upload-pack"
    git -C "$d" config protocol.file.allow always
}
pr_bare "$TMPDIR/pr-control.git"
git -C "$TMPDIR/pr-control.git" rev-list --count HEAD >/dev/null 2>&1 || true
assert_eq "control: a plain read fetches and runs the uploadpack command" \
    "true" "$([ -e "$PRM" ] && echo true || echo false)"
rm -f "$PRM"
pr_bare "$TMPDIR/pr-scan.git"
out=$(scan gitdir "$TMPDIR/pr-scan.git" -)
assert_eq "a host scan of it runs nothing" "false" \
    "$([ -e "$PRM" ] && echo true || echo false)"
pr_bare "$TMPDIR/pr-check.git"
pc_rc=0
swarm_preservation_check "$TMPDIR/pr-check.git" "$WORK" >/dev/null 2>&1 \
    || pc_rc=$?
assert_eq "nor does the preservation check" "false" \
    "$([ -e "$PRM" ] && echo true || echo false)"
assert_eq "which cannot tell, and says so" "2" "$pc_rc"
# Both layers are there, whichever one this Git honors: Git from 2.45
# (and patched older releases) stops at GIT_NO_LAZY_FETCH, any Git at
# the empty allow-list.  Every git the wrapper and the scanner run sees
# both.
assert_eq "swarm_no_fetch passes an empty GIT_ALLOW_PROTOCOL" "1" \
    "$(swarm_no_fetch env | grep -c '^GIT_ALLOW_PROTOCOL=$' || true)"
assert_eq "and GIT_NO_LAZY_FETCH=1" "1" \
    "$(swarm_no_fetch env | grep -c '^GIT_NO_LAZY_FETCH=1$' || true)"
GENV="$TMPDIR/git-env"
mkdir -p "$GENV/bin"
_real_git=$(command -v git)
cat > "$GENV/bin/git" <<EOF
#!/bin/bash
{ printf 'allow=%s|' "\${GIT_ALLOW_PROTOCOL-unset}"
  printf 'nolazy=%s\n' "\${GIT_NO_LAZY_FETCH-unset}"; } >> "$GENV/log"
exec "$_real_git" "\$@"
EOF
chmod +x "$GENV/bin/git"
out=$(scan gitdir "$BARE" - PATH="$GENV/bin:$PATH")
assert_eq "every git a host scan runs gets no transport" "true" \
    "$([ -s "$GENV/log" ] && ! grep -qv '^allow=|nolazy=1$' "$GENV/log" \
        && echo true || echo false)"

# Helper output: whatever the docker client writes to a file stops at
# SWARM_HELPER_OUTPUT_LIMIT_MB; a run keeps no container log.
HB="$TMPDIR/helper-bin"
mkdir -p "$HB"
cat > "$HB/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HELPER_LOG"
# Like the docker client, it fails when a write does.
case "${HELPER_FLOOD:-}" in
    out) head -c 3000000 /dev/zero || exit 1 ;;
    err) head -c 3000000 /dev/zero >&2 || exit 1 ;;
esac
exit 0
EOF
chmod +x "$HB/docker"
export HELPER_LOG="$TMPDIR/helper.log"
h_rc=0
PATH="$HB:$PATH" HELPER_FLOOD=out SWARM_HELPER_OUTPUT_LIMIT_MB=1 \
    swarm_docker_own_group run --rm img > "$TMPDIR/h.out" 2>/dev/null \
    || h_rc=$?
assert_eq "a helper flooding its output fails" "true" \
    "$([ "$h_rc" -ne 0 ] && echo true || echo false)"
assert_eq "with the file at the limit" "1048576" \
    "$(wc -c < "$TMPDIR/h.out" | tr -d ' ')"
h_rc=0
PATH="$HB:$PATH" HELPER_FLOOD=err SWARM_HELPER_OUTPUT_LIMIT_MB=1 \
    swarm_docker_own_group run --rm img > /dev/null 2>"$TMPDIR/h.err" \
    || h_rc=$?
assert_eq "so does one flooding its errors" "true" \
    "$([ "$h_rc" -ne 0 ] && echo true || echo false)"
# The calling shell may add a line about the job; nothing more.
assert_eq "with that file at the limit" "true" \
    "$([ "$(wc -c < "$TMPDIR/h.err" | tr -d ' ')" -le $((1048576 + 4096)) ] \
        && echo true || echo false)"
assert_eq "a run keeps no container log" "true" \
    "$(grep -q '^run --log-driver none --rm img$' "$HELPER_LOG" \
        && echo true || echo false)"
for _bad in 0 -1 x 1.5 08; do
    h_rc=0
    PATH="$HB:$PATH" SWARM_HELPER_OUTPUT_LIMIT_MB="$_bad" \
        swarm_docker_own_group run --rm img >/dev/null 2>&1 || h_rc=$?
    assert_eq "SWARM_HELPER_OUTPUT_LIMIT_MB '${_bad}' refuses" "1" "$h_rc"
done

# Scan archives: only report, bundle and objects, once each, as plain
# files, under the limit.
AX="$TMPDIR/ax"
mkdir -p "$AX"
# Make archive NAME from the files listed after it, in directory $AX/src.
ax_tar() {
    local name="$1"
    shift
    (cd "$AX/src" && tar -cf "$AX/$name" "$@")
}
# Extract archive NAME into the new directory $TMPDIR/axo-NAME; print
# the status.
ax_extract() {
    local d="$TMPDIR/axo-$1" rc=0
    mkdir "$d"
    cp "$AX/$1" "$d/scan.tar"
    swarm_scan_extract "$d/scan.tar" "$d" 2>/dev/null || rc=$?
    printf '%s' "$rc"
}
rm -rf "$AX/src"
mkdir -p "$AX/src"
echo r > "$AX/src/report"
echo b > "$AX/src/bundle"
echo o > "$AX/src/objects"
echo e > "$AX/src/extra"
echo x > "$AX/src/external-worktrees"
ax_tar ext.tar report external-worktrees
assert_eq "a scan archive with external-worktrees extracts" "0" \
    "$(ax_extract ext.tar)"
ax_tar extdup.tar report external-worktrees external-worktrees
assert_eq "external-worktrees twice is refused" "1" "$(ax_extract extdup.tar)"
head -c 65536 /dev/zero > "$AX/src/external-worktrees"
ax_tar ext64.tar report external-worktrees
assert_eq "an external-worktrees of 64 KiB extracts" "0" \
    "$(ax_extract ext64.tar)"
head -c 65537 /dev/zero > "$AX/src/external-worktrees"
ax_tar ext65.tar report external-worktrees
assert_eq "one a byte larger is refused" "1" "$(ax_extract ext65.tar)"
echo x > "$AX/src/external-worktrees"
ax_tar extwc.tar report external-worktrees
wc() { return 1; }
assert_eq "a size that cannot be read is refused" "1" "$(ax_extract extwc.tar)"
unset -f wc
rm "$AX/src/external-worktrees"
ln -s report "$AX/src/external-worktrees"
ax_tar extlink.tar report external-worktrees
assert_eq "an external-worktrees that is a link is refused" "1" \
    "$(ax_extract extlink.tar)"
rm "$AX/src/external-worktrees"
ln "$AX/src/report" "$AX/src/external-worktrees"
ax_tar exthard.tar report external-worktrees
assert_eq "and one that is a hard link" "1" "$(ax_extract exthard.tar)"
rm "$AX/src/external-worktrees"
ax_tar ok.tar report bundle objects
assert_eq "a scan archive of report, bundle and objects extracts" "0" \
    "$(ax_extract ok.tar)"
assert_eq "with each member in place" "r b o" \
    "$(cat "$TMPDIR/axo-ok.tar/report" "$TMPDIR/axo-ok.tar/bundle" \
        "$TMPDIR/axo-ok.tar/objects" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "and the archive gone" "false" \
    "$([ -e "$TMPDIR/axo-ok.tar/scan.tar" ] && echo true || echo false)"
ax_tar report-only.tar report
assert_eq "a report alone is fine" "0" "$(ax_extract report-only.tar)"
ax_tar extra.tar report extra
assert_eq "an extra member refuses" "1" "$(ax_extract extra.tar)"
ax_tar noreport.tar bundle objects
assert_eq "no report refuses" "1" "$(ax_extract noreport.tar)"
ax_tar twice.tar report report
assert_eq "a member twice refuses" "1" "$(ax_extract twice.tar)"
rm -f "$AX/src/report"
ln -s /etc/hosts "$AX/src/report"
ax_tar link.tar report
assert_eq "a symlink member refuses" "1" "$(ax_extract link.tar)"
rm -f "$AX/src/report" "$AX/src/bundle"
echo r > "$AX/src/report"
ln "$AX/src/report" "$AX/src/bundle"
ax_tar hard.tar report bundle
assert_eq "a hard-linked member refuses" "1" "$(ax_extract hard.tar)"
rm -f "$AX/src/bundle"
echo b > "$AX/src/bundle"
mkdir -p "$AX/src/sub"
echo x > "$AX/src/sub/x"
if tar --version 2>/dev/null | grep -q bsdtar; then
    (cd "$AX/src/sub" && tar -cf "$AX/dotdot.tar" -s ',^x$,../x,' x)
else
    (cd "$AX/src/sub" && tar -cf "$AX/dotdot.tar" --transform 's,^x$,../x,' x)
fi
assert_eq "a member named ../x refuses" "1" "$(ax_extract dotdot.tar)"
assert_eq "and nothing lands next to the output" "false" \
    "$([ -e "$TMPDIR/x" ] && echo true || echo false)"
_long="$AX/src/$(printf 'a%.0s' $(seq 1 120))/$(printf 'b%.0s' $(seq 1 120))"
mkdir -p "$_long"
echo r > "$_long/report"
(cd "$AX/src" && tar -cf "$AX/long.tar" "${_long#"$AX/src/"}/report")
assert_eq "a member name longer than the listing allows refuses" "1" \
    "$(ax_extract long.tar)"
for _i in $(seq 1 30); do echo "$_i" > "$AX/src/r$_i"; done
(cd "$AX/src" && tar -cf "$AX/many.tar" r*)
assert_eq "many members refuse" "1" "$(ax_extract many.tar)"
head -c 3000000 /dev/zero > "$AX/src/report"
ax_tar big.tar report
gzip -c "$AX/big.tar" > "$AX/big.tar.gz"
_saved="${SWARM_HELPER_OUTPUT_LIMIT_MB:-}"
export SWARM_HELPER_OUTPUT_LIMIT_MB=1
assert_eq "a member past the limit refuses" "1" "$(ax_extract big.tar)"
assert_eq "with what was written kept to the limit" "true" \
    "$([ "$(wc -c < "$TMPDIR/axo-big.tar/report" 2>/dev/null || echo 0)" \
        -le 1048576 ] && echo true || echo false)"
assert_eq "so does a compressed one" "1" "$(ax_extract big.tar.gz)"
if [ -n "$_saved" ]; then
    SWARM_HELPER_OUTPUT_LIMIT_MB="$_saved"
else
    unset SWARM_HELPER_OUTPUT_LIMIT_MB
fi

# ============================================================
echo ""
echo "=== 15. A workspace scan stops instead of hanging ==="

# A special file among a git dir's own files (HEAD, config, index,
# pointers, alternates) stops the scan before any of them is read: a
# FIFO would hang it.  No git command reads a checkout's config, includes
# and all, before the config checks have passed, and none looks for the
# repository around the current directory (the helper runs the scan from
# inside the workspace).  perl's alarm ends a hang.
# A committed workspace named NAME; print its path.
sf_ws() {
    local w="$TMPDIR/sf-$1"
    git init -q "$w"
    echo top > "$w/top.txt"
    g -C "$w" add top.txt
    g -C "$w" commit -q -m top
    printf '%s' "$w"
}
# Scan workspace DIR, from inside it, under a 30-second alarm; print the
# output directory (its .rc holds a failure).
sf_timed_scan() {
    local o
    o=$(mktemp -d "$TMPDIR/scan.XXXXXX")
    (cd "$1" && perl -e 'alarm 30; exec @ARGV' bash "$SCAN" worktree \
        "$1" full "$o") >/dev/null 2>&1 || echo "rc=$?" > "$o/.rc"
    printf '%s' "$o"
}
SF=$(sf_ws config)
rm "$SF/.git/config"
mkfifo "$SF/.git/config"
out=$(sf_timed_scan "$SF")
assert_eq "a FIFO for the workspace's config: the scan ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on it" "1" \
    "$(has_line "$out" 'block special-file .git/config')"
SF=$(sf_ws index)
rm "$SF/.git/index"
mkfifo "$SF/.git/index"
out=$(sf_timed_scan "$SF")
assert_eq "a FIFO for the workspace's index: the scan ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on it too" "1" \
    "$(has_line "$out" 'block special-file .git/index')"
# Any other file Git opens in a git dir, or a symlink to a FIFO there,
# and the files Git opens in a work tree.
SF=$(sf_ws others)
rm -f "$SF/.git/info/exclude"
mkfifo "$SF/.git/packed-refs" "$SF/.git/info/exclude" "$TMPDIR/sf-fifo"
ln -s "$TMPDIR/sf-fifo" "$SF/.git/info/attributes"
mkdir "$SF/sub"
mkfifo "$SF/sub/.gitignore"
out=$(sf_timed_scan "$SF")
assert_eq "FIFOs elsewhere in the git dir and work tree: the scan ends" \
    "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on packed-refs" "1" \
    "$(has_line "$out" 'block special-file .git/packed-refs')"
assert_eq "on info/exclude" "1" \
    "$(has_line "$out" 'block special-file .git/info/exclude')"
assert_eq "on a symlink to a FIFO" "1" \
    "$(has_line "$out" 'block special-file .git/info/attributes')"
assert_eq "and on a .gitignore in the work tree" "1" \
    "$(has_line "$out" 'block special-file sub/.gitignore')"
rm "$SF/.git/packed-refs" "$SF/.git/info/exclude" "$SF/sub/.gitignore"
rm "$SF/.git/info/attributes"
ln -s ../HEAD "$SF/.git/info/attributes"
assert_eq "a symlink to a regular file in the git dir is fine" "0" \
    "$(has_line "$(sf_timed_scan "$SF")" 'block special-file')"
SF=$(sf_ws include)
mkfifo "$TMPDIR/sf-include-fifo"
git -C "$SF" config include.path "$TMPDIR/sf-include-fifo"
out=$(sf_timed_scan "$SF")
assert_eq "the workspace's config including a FIFO: the scan ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on the include" "1" \
    "$(has_line "$out" 'block config-include .git')"
# In gitdir mode (a repository the engine made), Git would follow an
# include wherever it points: the engine writes none, so one blocks,
# also one that sets lfs.storage.
LB="$TMPDIR/sf-lfs-bare.git"
git init -q --bare "$LB"
printf '[lfs]\n\tstorage = /elsewhere\n' > "$TMPDIR/sf-lfs-inc"
git --git-dir="$LB" config include.path "$TMPDIR/sf-lfs-inc"
assert_eq "gitdir mode: lfs.storage set through an include blocks" "1" \
    "$(grep -c '^block config-include ' \
        "$(scan gitdir "$LB" -)/report" || true)"
LB2="$TMPDIR/sf-lfs-bare2.git"
git init -q --bare "$LB2"
mkdir -p "$TMPDIR/sf-lfs-home"
printf '[lfs]\n\tstorage = /elsewhere2\n' > "$TMPDIR/sf-lfs-home/storage.conf"
# shellcheck disable=SC2088  # the config holds the ~ itself, for Git
git --git-dir="$LB2" config include.path '~/storage.conf'
assert_eq "also an include under ~, the host's own home" "1" \
    "$(grep -c '^block config-include ' \
        "$(scan gitdir "$LB2" - HOME="$TMPDIR/sf-lfs-home")/report" || true)"
# userconfig mode (retire's check of the container user's git config):
# a FIFO where Git reads the global file, a global file that includes
# one, and a system file that keeps git var from answering (a git built
# with another prefix, here a shim) all end the check instead of hanging
# it.
uc_scan() {
    local o
    o=$(mktemp -d "$TMPDIR/scan.XXXXXX")
    env -i PATH="$1" HOME="$2" SWARM_SCAN_GIT_TIMEOUT=2 \
        perl -e 'alarm 60; exec @ARGV' bash "$SCAN" userconfig - - "$o" \
        >/dev/null 2>&1 || echo "rc=$?" > "$o/.rc"
    printf '%s' "$o"
}
UH="$TMPDIR/sf-uc-fifo"
mkdir -p "$UH"
mkfifo "$UH/.gitconfig"
out=$(uc_scan "$PATH" "$UH")
assert_eq "userconfig, a FIFO for the global file: the check ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "refusing it" "1" \
    "$(has_line "$out" "block config-unreadable $UH/.gitconfig")"
UH="$TMPDIR/sf-uc-inc"
mkdir -p "$UH"
mkfifo "$TMPDIR/sf-uc-inc-fifo"
printf '[include]\n\tpath = %s\n' "$TMPDIR/sf-uc-inc-fifo" > "$UH/.gitconfig"
out=$(uc_scan "$PATH" "$UH")
assert_eq "userconfig, a global file including a FIFO: the check ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "refusing the include" "1" \
    "$(has_line "$out" 'include.path')"
# An empty HOME is a home to Git (it reads /.gitconfig): that path is
# checked too (here against a mount there).
_o=$(mktemp -d "$TMPDIR/scan.XXXXXX")
env -i PATH="$PATH" HOME= SWARM_SCAN_MOUNTS=/.gitconfig \
    bash "$SCAN" userconfig - - "$_o" >/dev/null 2>&1 || echo "rc=$?" > "$_o/.rc"
assert_eq "userconfig with an empty HOME checks /.gitconfig" "1" \
    "$(has_line "$_o" 'block config-on-mount /.gitconfig')"
mkdir -p "$TMPDIR/sf-uc-shim" "$TMPDIR/sf-uc-home"
mkfifo "$TMPDIR/sf-uc-sys-fifo"
cat > "$TMPDIR/sf-uc-shim/git" <<EOF_SHIM
#!/bin/bash
GIT_CONFIG_SYSTEM='$TMPDIR/sf-uc-sys-fifo' exec '$(command -v git)' "\$@"
EOF_SHIM
chmod +x "$TMPDIR/sf-uc-shim/git"
out=$(uc_scan "$TMPDIR/sf-uc-shim:$PATH" "$TMPDIR/sf-uc-home")
assert_eq "userconfig, a system file that hangs git var: the check ends" \
    "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "refusing, out of time" "1" \
    "$(has_line "$out" 'block config-paths-unknown (git var did not answer in time)')"

# Git before 2.32 ignores GIT_CONFIG_GLOBAL, so the scan gives git no
# home either: a git that drops the variable (a shim) still reads no
# global file (here one naming a template directory, which git init
# would copy into the scan's scratch repository).
mkdir -p "$TMPDIR/sf-old-shim" "$TMPDIR/sf-old-home" "$TMPDIR/sf-tmpl"
echo marker > "$TMPDIR/sf-tmpl/sf-marker"
printf '[init]\n\ttemplateDir = %s\n' "$TMPDIR/sf-tmpl" \
    > "$TMPDIR/sf-old-home/.gitconfig"
cat > "$TMPDIR/sf-old-shim/git" <<EOF_OLD
#!/bin/bash
unset GIT_CONFIG_GLOBAL
exec '$(command -v git)' "\$@"
EOF_OLD
chmod +x "$TMPDIR/sf-old-shim/git"
SF=$(sf_ws oldgit)
_o=$(mktemp -d "$TMPDIR/scan.XXXXXX")
env PATH="$TMPDIR/sf-old-shim:$PATH" HOME="$TMPDIR/sf-old-home" \
    bash "$SCAN" worktree "$SF" full "$_o" >/dev/null 2>&1 \
    || echo "rc=$?" > "$_o/.rc"
assert_eq "a git that ignores GIT_CONFIG_GLOBAL: the scan completes" "" \
    "$(cat "$_o/.rc" 2>/dev/null)"
assert_eq "reading no global file (no template copied)" "false" \
    "$([ -e "$_o/scratch.git/sf-marker" ] && echo true || echo false)"

# A write that fails ends the scan with status 3, also where the caller
# tests the result (errexit does not apply there): the checkout queue
# and the report, here directories that cannot be appended to.
_qc=$(mktemp -d "$TMPDIR/qc.XXXXXX")
mkdir "$_qc/.checkouts" "$_qc/report"
cat > "$_qc/t.sh" <<'EOF_QC'
eval "$(awk '/^fail\(\) \{/,/^\}/' "$1")"
eval "$(awk '/^oneline\(\) \{/,/^\}/' "$1")"
eval "$(awk '/^report\(\) \{/,/^\}/' "$1")"
eval "$(awk '/^queue_checkout\(\) \{/,/^\}/' "$1")"
if [ "$2" = queue ]; then
    if queue_checkout a b c; then exit 0; fi
elif report "block x"; then
    exit 0
fi
exit 1
EOF_QC
for _qw in queue report; do
    _qrc=0
    OUT="$_qc" REPORT="$_qc/report" bash "$_qc/t.sh" "$SCAN" "$_qw" \
        >/dev/null 2>&1 || _qrc=$?
    assert_eq "a failed write to the ${_qw} ends the scan, tested or not" \
        "3" "$_qrc"
done

# ============================================================
echo ""
echo "=== 16. Repositories nested in a workspace ==="

# An ordinary repository cloned or initialized inside a workspace is a
# repository location of its own: its git dir is checked like the
# workspace's, everything Git keeps there goes into the bundle (its
# objects under refs/v/<n>, its files under refs/v/<n>/files, its path
# as refs/v/<n>/path), its work tree is checked for content outside
# Git's history, and the parent's one untracked or ignored entry for its
# directory is not reported as the parent's.
# A committed workspace named NAME; print its path.
nr_ws() {
    local w="$TMPDIR/nr-$1"
    git init -q "$w"
    echo top > "$w/top.txt"
    g -C "$w" add top.txt
    g -C "$w" commit -q -m top
    printf '%s' "$w"
}
# A repository at PATH with one commit of file F.
nr_repo() {
    git init -q "$1"
    echo "$2" > "$1/$2"
    g -C "$1" add "$2"
    g -C "$1" commit -q -m "$2"
}
# The number of the git dir at PATH (relative to the root) in scan OUT.
nr_n() {
    awk -v p="$2" '$1 == "gitdir" && $3 == p { print $2 }' "$1/report"
}
# The findings of scan OUT to keep or discard, or why it failed.
nr_clean() {
    if [ -e "$1/.rc" ]; then
        echo "failed: $(cat "$1/.rc")"
        return
    fi
    grep -cE '^(block|uncommitted) ' "$1/report" || true
}

NR=$(nr_ws unborn)
git init -q "$NR/inner"
out=$(scan worktree "$NR" full)
assert_eq "an unborn repository nested in a workspace: the scan completes" \
    "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "nothing blocks, nothing is left to discard" "0" "$(nr_clean "$out")"
n=$(nr_n "$out" inner/.git)
assert_eq "its git dir is in the inventory" "true" \
    "$([ -n "$n" ] && echo true || echo false)"
dst=$(imported "$out")
assert_eq "under a path the import keeps" "inner/.git" \
    "$(git -C "$dst" cat-file blob "refs/r/$n/path" 2>/dev/null)"
assert_eq "with its git dir's files (HEAD among them)" "1" \
    "$(git -C "$dst" cat-file blob "refs/r/$n/files" 2>/dev/null \
        | tr '\0' '\n' | grep -c ' HEAD$' || true)"
assert_eq "the workspace's own git dir has its path too" ".git" \
    "$(git -C "$dst" cat-file blob "refs/r/$(nr_n "$out" .git)/path" \
        2>/dev/null)"

# A clone with a commit and a git-dir file of its own.
NR=$(nr_ws clone)
nr_repo "$TMPDIR/nr-src" s
git clone -q --no-local "$TMPDIR/nr-src" "$NR/engagement_target"
echo mine > "$NR/engagement_target/poc.txt"
g -C "$NR/engagement_target" add poc.txt
g -C "$NR/engagement_target" commit -q -m poc
NPOC=$(git -C "$NR/engagement_target" rev-parse HEAD)
echo note > "$NR/engagement_target/.git/info/notes.txt"
out=$(scan worktree "$NR" full)
assert_eq "a clone in the workspace, committed: nothing to discard" "0" \
    "$(nr_clean "$out")"
dst=$(imported "$out")
assert_eq "the clone's own commit is carried" "commit" \
    "$(git -C "$dst" cat-file -t "$NPOC" 2>/dev/null)"
n=$(nr_n "$out" engagement_target/.git)
k=$(git -C "$dst" cat-file blob "refs/r/$n/files" 2>/dev/null | tr '\0' '\n' \
    | awk '$4 == "info/notes.txt" { print $1 }')
assert_eq "and a file of its git dir, under its number" "note" \
    "$(git -C "$dst" cat-file blob "refs/r/$n/f/$k" 2>/dev/null)"
assert_eq "a layer checkout holding the same is carried too" "0" \
    "$(nr_clean "$(scan worktree "$NR" layer)")"

# Siblings, a prefix of a name, and a repository nested in a nested one.
NR=$(nr_ws depth)
for r in a ab a/b; do
    nr_repo "$NR/$r" "f-${r%%/*}"
done
out=$(scan worktree "$NR" full)
assert_eq "siblings and a repository in a nested one: nothing to discard" \
    "0" "$(nr_clean "$out")"
assert_eq "each one is in the inventory once" "1 1 1" \
    "$(for r in a ab a/b; do
           awk -v p="$r/.git" '$1 == "gitdir" && $3 == p' "$out/report" \
               | grep -c .
       done | tr '\n' ' ' | sed 's/ $//')"

# What the parent shows beside a nested repository is still its own.
NR=$(nr_ws boundary)
git init -q "$NR/inner"
echo stray > "$NR/stray.txt"
mkdir -p "$NR/dir"
echo x > "$NR/dir/x"
out=$(scan worktree "$NR" full)
assert_eq "beside a nested repository, an untracked file is reported" "1" \
    "$(has_line "$out" 'uncommitted dirty .: ?? stray.txt')"
assert_eq "so is one in a plain directory" "1" \
    "$(has_line "$out" 'uncommitted dirty .: ?? dir/x')"
assert_eq "but not the nested repository's directory" "0" \
    "$(has_line "$out" 'uncommitted dirty .: ?? inner/')"

# Ignored: the repository's own directory, and a directory around one.
NR=$(nr_ws ignored)
printf 'engagement_target/\ntargets/\n' > "$NR/.gitignore"
g -C "$NR" add .gitignore
g -C "$NR" commit -q -m ignore
git init -q "$NR/engagement_target"
mkdir -p "$NR/targets"
git init -q "$NR/targets/a"
out=$(scan worktree "$NR" full)
assert_eq "an ignored nested repository's directory is not reported" "0" \
    "$(has_line "$out" 'uncommitted ignored .: engagement_target/')"
assert_eq "an ignored directory around one is reported whole" "1" \
    "$(has_line "$out" 'uncommitted ignored .: targets/')"
assert_eq "and the repository in it is carried all the same" "true" \
    "$([ -n "$(nr_n "$out" targets/a/.git)" ] && echo true || echo false)"

# Work in a nested repository is reported with its path, engine paths
# included (only the workspace's own checkout has those).
NR=$(nr_ws dirty)
git init -q "$NR/inner"
echo tracked > "$NR/inner/t"
echo gone > "$NR/inner/d"
echo '*.log' > "$NR/inner/.gitignore"
g -C "$NR/inner" add t d .gitignore
g -C "$NR/inner" commit -q -m inner
echo changed > "$NR/inner/t"
rm "$NR/inner/d"
echo new > "$NR/inner/new.txt"
echo staged > "$NR/inner/staged.txt"
g -C "$NR/inner" add staged.txt
echo log > "$NR/inner/run.log"
mkdir -p "$NR/inner/agent_logs"
echo x > "$NR/inner/agent_logs/x"
out=$(scan worktree "$NR" full)
for want in 'uncommitted dirty inner:  M t' 'uncommitted dirty inner:  D d' \
        'uncommitted dirty inner: ?? new.txt' \
        'uncommitted dirty inner: A  staged.txt' \
        'uncommitted ignored inner: run.log' \
        'uncommitted dirty inner: ?? agent_logs/x'; do
    assert_eq "nested work reported: ${want#uncommitted }" "1" \
        "$(has_line "$out" "$want")"
done
NR=$(nr_ws hidden)
nr_repo "$NR/inner" h
git -C "$NR/inner" update-index --skip-worktree h
assert_eq "a hidden index entry in a nested repository is reported" "1" \
    "$(has_line "$(scan worktree "$NR" full)" 'uncommitted hidden inner: S h')"
NR=$(nr_ws op)
nr_repo "$NR/inner" i
git -C "$NR/inner" rev-parse HEAD > "$NR/inner/.git/MERGE_HEAD"
assert_eq "an unfinished operation in a nested repository is reported" "1" \
    "$(has_line "$(scan worktree "$NR" full)" \
        'uncommitted operation inner/.git/MERGE_HEAD')"

# A file the workspace tracks inside what became a nested repository's
# directory is still the workspace's.
NR=$(nr_ws overlap)
mkdir -p "$NR/sub"
echo p > "$NR/sub/p"
g -C "$NR" add sub/p
g -C "$NR" commit -q -m p
git init -q "$NR/sub"
echo q > "$NR/sub/p"
assert_eq "a tracked file inside a nested repository's directory" "1" \
    "$(has_line "$(scan worktree "$NR" full)" 'uncommitted dirty .:  M sub/p')"

# A nested repository's submodule: its module repo is inventoried and
# its checkout checked.
NR=$(nr_ws module)
nr_repo "$TMPDIR/nr-msrc" m
nr_repo "$NR/inner" i
g -C "$NR/inner" -c protocol.file.allow=always submodule add -q \
    "$TMPDIR/nr-msrc" sub >/dev/null 2>&1
g -C "$NR/inner" commit -q -m sub
echo dirty > "$NR/inner/sub/m"
out=$(scan worktree "$NR" full)
assert_eq "a nested repository's module repo is in the inventory" "true" \
    "$([ -n "$(nr_n "$out" inner/.git/modules/sub)" ] && echo true || echo false)"
assert_eq "and its checkout is checked, with its path" "1" \
    "$(has_line "$out" 'uncommitted dirty inner/sub:  M m')"

# What is not an ordinary repository still blocks: a bare repository at
# a .git, a .git directory without one, a .git symlink.
NR=$(nr_ws invalid)
mkdir -p "$NR/b" "$NR/e/.git" "$NR/l"
git init -q --bare "$NR/b/.git"
git init -q "$TMPDIR/nr-real"
ln -s "$TMPDIR/nr-real/.git" "$NR/l/.git"
out=$(scan worktree "$NR" full)
assert_eq "a bare repository at a checkout's .git blocks" "1" \
    "$(has_line "$out" 'block embedded b')"
assert_eq "so does a .git directory that holds no repository" "1" \
    "$(has_line "$out" 'block embedded e')"
assert_eq "and a .git that is a symlink" "1" \
    "$(has_line "$out" 'block embedded l')"
NR=$(nr_ws headonly)
mkdir -p "$NR/h/.git"
echo 'ref: refs/heads/main' > "$NR/h/.git/HEAD"
assert_eq "a .git with a HEAD but no objects/ blocks too" "1" \
    "$(has_line "$(scan worktree "$NR" full)" 'block embedded h')"

# A nested repository's config is checked like the workspace's.
NR=$(nr_ws config)
for c in include filter hooks wt-in wt-out; do
    git init -q "$NR/$c"
done
printf '[core]\n\tabbrev = 12\n' > "$TMPDIR/nr-included"
git -C "$NR/include" config include.path "$TMPDIR/nr-included"
git -C "$NR/filter" config filter.x.clean cat
git -C "$NR/hooks" config core.hooksPath "$TMPDIR"
git -C "$NR/wt-in" config core.worktree "$NR/.git"
git -C "$NR/wt-out" config core.worktree "$TMPDIR"
out=$(scan worktree "$NR" full)
assert_eq "a nested repository's include blocks" "1" \
    "$(has_line "$out" 'block config-include include/.git')"
assert_eq "so does its filter driver" "1" \
    "$(has_line "$out" 'block filter-driver filter/.git')"
assert_eq "its hooksPath" "1" \
    "$(has_line "$out" 'block core-hookspath hooks/.git')"
assert_eq "a work tree inside another git dir" "1" \
    "$(has_line "$out" 'block gitdir-worktree wt-in/.git')"
assert_eq "and one outside the volume" "1" \
    "$(has_line "$out" 'block core-worktree wt-out/.git')"
NR=$(nr_ws wt-nested)
nr_repo "$NR/a" fa
nr_repo "$NR/b" fb
git -C "$NR/b" config core.worktree "$NR/a/.git/info"
assert_eq "a work tree inside a nested repository's git dir blocks" "1" \
    "$(has_line "$(scan worktree "$NR" full)" 'block gitdir-worktree b/.git')"

# Linked worktrees of a nested repository: inside the volume they are
# checked, outside it they block.
NR=$(nr_ws linked)
nr_repo "$NR/inner" i
git -C "$NR/inner" worktree add -q "$NR/inner-wt" 2>/dev/null
echo wip > "$NR/inner-wt/i"
assert_eq "a nested repository's linked worktree in the volume is checked" \
    "1" "$(has_line "$(scan worktree "$NR" full)" 'uncommitted dirty inner-wt:  M i')"
NR=$(nr_ws linked-in-gitdir)
nr_repo "$NR/a" fa
nr_repo "$NR/b" fb
git -C "$NR/b" worktree add -q "$NR/a/.git/wt" 2>/dev/null
assert_eq "a linked worktree inside a nested repository's git dir blocks" \
    "1" "$(has_line "$(scan worktree "$NR" full)" 'block gitdir-worktree a/.git/wt')"
NR=$(nr_ws linked-out)
nr_repo "$NR/inner" i
git -C "$NR/inner" worktree add -q "$TMPDIR/nr-outside-wt" 2>/dev/null
assert_eq "one outside the volume blocks" "1" \
    "$(has_line "$(scan worktree "$NR" full)" 'block external')"

# The size limits count across every git dir tree of the scan: with the
# total just below what the workspace's and the nested repository's
# files hold together, some of the nested ones are reported.
NR=$(nr_ws limits)
nr_repo "$NR/inner" i
head -c 2000 /dev/zero > "$NR/inner/.git/info/filler"
_nr_sum() {
    find "$1" -type f -print0 | xargs -0 cat | wc -c | tr -d ' '
}
_nr_total=$(( $(_nr_sum "$NR/.git") + $(_nr_sum "$NR/inner/.git") - 1 ))
out=$(scan worktree "$NR" full SWARM_SCAN_TOTAL_LIMIT="$_nr_total")
assert_eq "the total counts across the workspace and nested git dirs" \
    "true" "$(grep -qE '^uncommitted large-file inner/[.]git/' "$out/report" \
        && echo true || echo false)"
out=$(scan worktree "$NR" full SWARM_SCAN_FILE_LIMIT=1500)
assert_eq "a nested git-dir file over the file limit is reported" "1" \
    "$(has_line "$out" 'uncommitted large-file inner/.git/info/filler 2000')"

# A nested repository's filter driver blocks, and never runs: neither
# in the repository itself nor in its module.
NR=$(nr_ws filter-run)
fl_repo "$NR/inner"
git -C "$NR/inner" config filter.x.clean "touch $FLM; cat"
echo b > "$NR/inner/f"
rm -f "$FLM"
out=$(scan worktree "$NR" full)
assert_eq "a nested repository's filter driver blocks" "1" \
    "$(has_line "$out" 'block filter-driver inner/.git filter.x.clean')"
assert_eq "and the scan never runs it" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"
assert_eq "nor makes a bundle" "false" \
    "$([ -e "$out/bundle" ] && echo true || echo false)"
NR=$(nr_ws filter-module)
fl_repo "$TMPDIR/nr-fsrc"
nr_repo "$NR/inner" i
g -C "$NR/inner" -c protocol.file.allow=always submodule add -q \
    "$TMPDIR/nr-fsrc" sub >/dev/null 2>&1
g -C "$NR/inner" commit -q -m sub
git -C "$NR/inner/sub" config filter.x.clean "touch $FLM; cat"
echo b > "$NR/inner/sub/f"
rm -f "$FLM"
out=$(scan worktree "$NR" full)
assert_eq "a filter driver in a nested repository's module blocks" "1" \
    "$(has_line "$out" 'block filter-driver inner/.git/modules/sub filter.x.clean')"
assert_eq "and never runs either" "false" \
    "$([ -e "$FLM" ] && echo true || echo false)"

# The hangs of section 15, with nested repositories: a FIFO index in
# one, a nested config that includes a FIFO, and the workspace's own
# FIFO config with a nested repository to look at (its core.bare is read
# before the special-file check).
NR=$(nr_ws fifo-index)
nr_repo "$NR/inner" i
rm "$NR/inner/.git/index"
mkfifo "$NR/inner/.git/index"
out=$(sf_timed_scan "$NR")
assert_eq "a FIFO for a nested repository's index: the scan ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on it" "1" \
    "$(has_line "$out" 'block special-file inner/.git/index')"
NR=$(nr_ws fifo-include)
nr_repo "$NR/inner" i
mkfifo "$TMPDIR/nr-include-fifo"
git -C "$NR/inner" config include.path "$TMPDIR/nr-include-fifo"
out=$(sf_timed_scan "$NR")
assert_eq "a nested repository including a FIFO: the scan ends" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on the include" "1" \
    "$(has_line "$out" 'block config-include inner/.git')"
NR=$(nr_ws fifo-cwd)
git init -q "$NR/inner"
rm "$NR/.git/config"
mkfifo "$NR/.git/config"
out=$(sf_timed_scan "$NR")
assert_eq "the workspace's FIFO config beside a nested repository: it ends" \
    "" "$(cat "$out/.rc" 2>/dev/null)"
assert_eq "blocking on that config" "1" \
    "$(has_line "$out" 'block special-file .git/config')"

# One object format per scan.
if git init -q --object-format=sha256 "$TMPDIR/nr-sha256-probe" 2>/dev/null
then
    NR=$(nr_ws format)
    git init -q --object-format=sha256 "$NR/inner"
    assert_eq "a nested repository with another object format fails the scan" \
        "rc=3" "$(cat "$(scan worktree "$NR" full)/.rc" 2>/dev/null)"
fi

# ============================================================
echo ""
echo "=== 17. Partial clones refuse ==="

# A partial clone's history is not all in its git dir (the rest is its
# promisor remote's), and the scan never fetches: a partial-clone
# setting, a promisor remote or a promisor pack refuses, before status
# runs, in the workspace's repository and in one nested in it.
PC=$(sf_ws partial)
git -C "$PC" config core.repositoryformatversion 1
git -C "$PC" config extensions.partialClone origin
out=$(scan worktree "$PC" full)
assert_eq "extensions.partialClone refuses" "1" \
    "$(has_line "$out" 'block promisor .git extensions.partialClone')"
assert_eq "the scan stops before status, completing its report" "" \
    "$(cat "$out/.rc" 2>/dev/null)"
PC=$(sf_ws promisor-remote)
git -C "$PC" config remote.origin.url /nowhere
git -C "$PC" config remote.origin.promisor true
assert_eq "a promisor remote refuses" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor .git remote.origin.promisor')"
PC=$(sf_ws promisor-pack)
mkdir -p "$PC/.git/objects/pack"
: > "$PC/.git/objects/pack/pack-$(printf '%040d' 1).promisor"
assert_eq "a promisor pack refuses" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor .git/objects pack-')"
PC=$(sf_ws promisor-worktree-config)
git -C "$PC" config core.repositoryformatversion 1
git -C "$PC" config extensions.worktreeConfig true
printf '[remote "origin"]\n\tpromisor = true\n' > "$PC/.git/config.worktree"
assert_eq "a promisor remote in config.worktree refuses" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor .git remote.origin.promisor')"
PC=$(sf_ws partial-filter)
git -C "$PC" config remote.origin.url /nowhere
git -C "$PC" config remote.origin.partialCloneFilter blob:none
assert_eq "a remote's partialCloneFilter alone refuses" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor .git remote.origin.partialclonefilter')"
PC=$(sf_ws promisor-alternate)
mkdir -p "$PC/.git/pool/pack"
: > "$PC/.git/pool/pack/.hidden.promisor"
echo ../pool > "$PC/.git/objects/info/alternates"
assert_eq "a promisor pack, dot-named, in an alternate store refuses" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor .git/pool .hidden.promisor')"
PC=$(sf_ws partial-nested)
git init -q "$PC/inner"
git -C "$PC/inner" config core.repositoryformatversion 1
git -C "$PC/inner" config extensions.partialClone origin
assert_eq "so does a nested repository that is a partial clone" "1" \
    "$(has_line "$(scan worktree "$PC" full)" 'block promisor inner/.git extensions.partialClone')"

# ============================================================
echo ""
echo "=== 18. Linked worktrees outside the scanned tree ==="

# A workspace whose repository registers linked worktrees outside it, and
# a directory that stands for the container's own layer.  Paths are
# resolved (on macOS /var is a link), as Git records them.
XT=$(cd -P "$TMPDIR" && pwd -P)
XW="$XT/xws"
XL="$XT/xlayer"
mkdir -p "$XL"
git init -q "$XW"
echo a > "$XW/a"
g -C "$XW" add a
g -C "$XW" commit -q -m one
XBASE=$(git -C "$XW" rev-parse HEAD)
echo b > "$XW/a"
g -C "$XW" commit -q -am two
# Scan XW as ORIGIN, with more environment if given.
xscan() {
    local o="$1"
    shift
    scan worktree "$XW" full SWARM_SCAN_ORIGIN="$o" "$@"
}
# Add linked worktree NAME of XW in XL, detached at the first commit;
# drop it, registration and all.
xadd() {
    git -C "$XW" worktree add -q --detach "$XL/$1" "$XBASE" 2>/dev/null
}
xdrop() {
    rm -rf "${XL:?}/$1" "$XW/.git/worktrees/$1"
}
# The list scan OUT published, one path per line, or "none".
xlist() {
    if [ -f "$1/external-worktrees" ]; then
        tr '\0' '\n' < "$1/external-worktrees"
    else
        echo none
    fi
}
xblocks() {
    grep -c '^block ' "$1/report" || true
}

xadd wt
o=$(xscan retire-volume)
assert_eq "retire-volume: a clean linked worktree in the layer is let through" \
    "1" "$(has_line "$o" "external-worktree $XL/wt")"
assert_eq "  with nothing to refuse or discard" "0" \
    "$(grep -cE '^(block|uncommitted|layer-uncommitted) ' "$o/report" || true)"
assert_eq "  and listed at the scan's end" "$XL/wt" "$(xlist "$o")"
dst=$(imported "$o")
_xk=$(git -C "$dst" cat-file -p refs/r/0/files | tr '\0' '\n' \
    | awk '$4 == "worktrees/wt/HEAD" { print $1 }')
assert_eq "  its admin dir's HEAD is kept with the repository's files" \
    "$XBASE" \
    "$(git -C "$dst" cat-file -p "refs/r/0/f/$_xk" 2>/dev/null | tr -d '\n')"
echo u > "$XL/wt/untracked.txt"
echo m >> "$XL/wt/a"
echo s > "$XL/wt/staged.txt"
git -C "$XL/wt" add staged.txt
_xs=$(git -C "$XL/wt" rev-parse :staged.txt)
rm "$XL/wt/staged.txt"
echo 'x.log' >> "$XW/.git/info/exclude"
echo l > "$XL/wt/x.log"
o=$(xscan retire-volume)
assert_eq "  an untracked file there is layer-uncommitted" "1" \
    "$(has_line "$o" "layer-uncommitted dirty $XL/wt: ?? untracked.txt")"
assert_eq "  so is a changed tracked file" "1" \
    "$(has_line "$o" "layer-uncommitted dirty $XL/wt:  M a")"
assert_eq "  and a staged file deleted since" "1" \
    "$(has_line "$o" "layer-uncommitted dirty $XL/wt: AD staged.txt")"
assert_eq "  and an ignored file" "1" \
    "$(has_line "$o" "layer-uncommitted ignored $XL/wt: x.log")"
assert_eq "  never plain uncommitted" "0" \
    "$(grep -c "^uncommitted .*$XL/wt" "$o/report" || true)"
assert_eq "  still let through and listed" "$XL/wt" "$(xlist "$o")"
assert_eq "  the staged-only blob is in the bundle" "blob" \
    "$(git -C "$(imported "$o")" cat-file -t "$_xs" 2>/dev/null)"
git -C "$XL/wt" update-index --assume-unchanged a
o=$(xscan retire-volume)
assert_eq "  a hidden index entry is layer-uncommitted" "1" \
    "$(has_line "$o" "layer-uncommitted hidden $XL/wt: h a")"
sed -i.bak '/^x\.log$/d' "$XW/.git/info/exclude"
rm -f "$XW/.git/info/exclude.bak"
xdrop wt
git -C "$XW" worktree prune
# A submodule not initialized in such a worktree: Git shows nothing
# below its directory, and every file the scan lists there is
# layer-uncommitted too, never plain uncommitted.
git -C "$XW" update-index --add --cacheinfo "160000,$XBASE,sub"
g -C "$XW" commit -q -m gitlink
git -C "$XW" worktree add -q --detach "$XL/wtg" HEAD 2>/dev/null
mkdir -p "$XL/wtg/sub"
echo w > "$XL/wtg/sub/x.txt"
o=$(xscan retire-volume)
assert_eq "  a file under its uninitialized submodule is layer-uncommitted" \
    "1" "$(has_line "$o" "layer-uncommitted dirty $XL/wtg: ?? sub/x.txt")"
assert_eq "  never plain uncommitted" "0" \
    "$(grep -c "^uncommitted .*$XL/wtg" "$o/report" || true)"
xdrop wtg
git -C "$XW" worktree prune
git -C "$XW" reset -q --hard HEAD~1

xadd wo
o=$(xscan cleanup)
assert_eq "cleanup: one present where cleanup scans blocks" "1" \
    "$(has_line "$o" "block external $XL/wo (present where cleanup scans)")"
for _xo in retire-layer other; do
    o=$(xscan "$_xo")
    assert_eq "$_xo: one present outside blocks" "1" \
        "$(has_line "$o" "block external $XL/wo")"
done
rm -rf "$XL/wo"
for _xo in retire-volume retire-layer other; do
    o=$(xscan "$_xo")
    assert_eq "$_xo: a registration whose directory is gone is a note" \
        "1 0" "$(has_line "$o" "gone-worktree $XL/wo") $(xblocks "$o")"
done
o=$(xscan cleanup)
assert_eq "cleanup: it is left to retire" "1 0" \
    "$(has_line "$o" "deferred-worktree $XL/wo") $(xblocks "$o")"
xdrop wo

# Its path, written by hand (Git records resolved paths).
xadd wl
ln -s "$XL" "$XT/xlink"
printf '%s\n' "$XT/xlink/wl/.git" > "$XW/.git/worktrees/wl/gitdir"
o=$(xscan retire-volume)
assert_eq "a registered path through a link blocks" "1" \
    "$(has_line "$o" "block worktree-path $XT/xlink/wl (a link on the way: $XT/xlink)")"
rm "$XT/xlink"
printf '%s\n' "$XL/wl/.git" > "$XW/.git/worktrees/wl/gitdir"
o=$(xscan retire-volume SWARM_SCAN_MOUNTS="$XL")
assert_eq "one at or below a mount of the container blocks" "1" \
    "$(has_line "$o" "block worktree-path $XL/wl (under a mount)")"
o=$(xscan retire-volume SWARM_SCAN_MOUNTS="$XL/wl/sub")
assert_eq "so does one with a mount inside it" "1" \
    "$(has_line "$o" "block external $XL/wl (a mount inside it)")"
ln -s "$XL" "$XT/xalias"
o=$(xscan retire-volume SWARM_SCAN_MOUNTS="$XT/xalias")
assert_eq "and one under a mount given through a link" "1" \
    "$(has_line "$o" "block worktree-path $XL/wl (under a mount)")"
rm -rf "$XL/wl"
o=$(xscan retire-volume SWARM_SCAN_MOUNTS="$XT/xalias")
assert_eq "a gone one under a mount is not gone, it blocks" "1" \
    "$(has_line "$o" "block worktree-path $XL/wl (under a mount)")"
rm "$XT/xalias"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$XT/xlocked/in"
    printf '%s\n' "$XT/xlocked/in/wl/.git" > "$XW/.git/worktrees/wl/gitdir"
    chmod 000 "$XT/xlocked"
    o=$(xscan retire-volume)
    chmod 755 "$XT/xlocked"
    assert_eq "a path this scan cannot inspect blocks" "1" \
        "$(has_line "$o" "block worktree-path $XT/xlocked/in/wl (cannot inspect $XT/xlocked)")"
    rm -rf "$XT/xlocked"
else
    echo "  SKIP: as root every directory can be searched"
fi
for _xp in "$XL/wl" "$XL/x/../wl/.git" "$XL/w"$'\t'"l/.git"; do
    printf '%s\n' "$_xp" > "$XW/.git/worktrees/wl/gitdir"
    o=$(xscan retire-volume)
    assert_eq "a malformed back-pointer blocks: $(printf '%q' "$_xp")" "1" \
        "$(grep -c '^block worktree-pointer ' "$o/report" || true)"
done
printf 'a\nb\n' > "$XW/.git/worktrees/wl/gitdir"
o=$(xscan retire-volume)
assert_eq "so does one of two lines" "1" \
    "$(has_line "$o" "block worktree-pointer .git/worktrees/wl (not one short line)")"
head -c 5000 /dev/zero | tr '\0' a > "$XW/.git/worktrees/wl/gitdir"
o=$(xscan retire-volume)
assert_eq "and an oversized one" "1" \
    "$(has_line "$o" "block worktree-pointer .git/worktrees/wl (not one short line)")"
xdrop wl

xadd w2
o=$(xscan retire-volume)
assert_eq "a fresh worktree is let through" "1" \
    "$(has_line "$o" "external-worktree $XL/w2")"
for _xf in pipe .gitignore .gitattributes; do
    mkfifo "$XL/w2/$_xf"
    o=$(xscan retire-volume)
    assert_eq "a FIFO named $_xf in it blocks, before Git reads it" "1" \
        "$(has_line "$o" "block external $XL/w2 (a special file: $XL/w2/$_xf)")"
    assert_eq "  and no list is published" "none" "$(xlist "$o")"
    rm "$XL/w2/$_xf"
done
git init -q "$XL/w2/inner"
o=$(xscan retire-volume)
assert_eq "a repository inside it blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (a repository inside: $XL/w2/inner/.git)")"
rm -rf "$XL/w2/inner"
git init -q --bare "$XL/w2/b.git"
o=$(xscan retire-volume)
assert_eq "so does a bare one" "1" \
    "$(has_line "$o" "block external $XL/w2 (a repository inside: $XL/w2/b.git)")"
rm -rf "$XL/w2/b.git"
mkdir -p "$XL/w2/sub"
printf 'gitdir: %s\n' "$XT/elsewhere" > "$XL/w2/sub/.git"
o=$(xscan retire-volume)
assert_eq "and a .git file below it" "1" \
    "$(has_line "$o" "block external $XL/w2 (a repository inside: $XL/w2/sub/.git)")"
rm -rf "$XL/w2/sub"
cp "$XL/w2/.git" "$XT/xgitfile"
rm "$XL/w2/.git"
ln -s "$XT/xgitfile" "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "a .git that is a link blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git is not a file)")"
rm "$XL/w2/.git"
printf 'gitdir: %s\n' "$XW/.git/worktrees/other" > "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "so does one naming another git dir" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git names another git dir)")"
printf 'gitdir: ../x\n' > "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "or a relative one" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git names a relative git dir)")"
cp "$XT/xgitfile" "$XL/w2/.git"
ln -s a "$XL/w2/rel-link"
ln -s "$XL/w2/a" "$XL/w2/abs-link"
ln -s nowhere "$XL/w2/dangling"
o=$(xscan retire-volume)
assert_eq "links inside it (relative, absolute, dangling) are fine" "1 0" \
    "$(has_line "$o" "external-worktree $XL/w2") $(xblocks "$o")"
mkdir -p "$XT/xout"
echo z > "$XT/xout/z"
ln -s "$XT/xout/z" "$XL/w2/out-link"
o=$(xscan retire-volume)
assert_eq "a link out of it blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (a link out: $XL/w2/out-link)")"
rm "$XL/w2/out-link"
ln -s "$XL/w2" "$XT/xjump"
ln -s "$XT/xjump/a" "$XL/w2/reentry"
o=$(xscan retire-volume)
assert_eq "so does one that leaves it and comes back" "1" \
    "$(has_line "$o" "block external $XL/w2 (a link out: $XL/w2/reentry)")"
rm "$XL/w2/reentry" "$XT/xjump"
ln -s "$XT/xout/../xlayer/w2/a" "$XL/w2/dotdot"
o=$(xscan retire-volume)
assert_eq "and one whose path passes an outside directory on the way" "1" \
    "$(has_line "$o" "block external $XL/w2 (a link out: $XL/w2/dotdot)")"
rm "$XL/w2/dotdot"
ln -s l2 "$XL/w2/l1"
ln -s l1 "$XL/w2/l2"
o=$(xscan retire-volume)
assert_eq "and a loop" "1" \
    "$(grep -cE "^block external $XL/w2 \(a link out: $XL/w2/l[12]\)$" \
        "$o/report" || true)"
rm "$XL/w2/l1" "$XL/w2/l2"
printf '%s\n' '../../../../xlayer/w2/.git' > "$XW/.git/worktrees/w2/gitdir"
o=$(xscan retire-volume)
assert_eq "a relative back-pointer leading outside blocks" "1" \
    "$(has_line "$o" "block worktree-pointer ../../../../xlayer/w2/.git (relative, outside)")"
printf '%s\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"

# Its .git, one line exactly; an empty directory; a socket; the hop bound.
printf 'gitdir: %s\n\n' "$XW/.git/worktrees/w2" > "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "a .git of two lines blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git cannot be read as a gitfile)")"
head -c 5000 /dev/zero | tr '\0' a > "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "so does an oversized one" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git cannot be read as a gitfile)")"
rm "$XL/w2/.git"
o=$(xscan retire-volume)
assert_eq "and a directory there without its .git" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git is not a file)")"
cp "$XT/xgitfile" "$XL/w2/.git"
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$XL/w2/sock"
    o=$(xscan retire-volume)
    assert_eq "a socket in it blocks" "1" \
        "$(has_line "$o" "block external $XL/w2 (a special file: $XL/w2/sock)")"
    rm -f "$XL/w2/sock"
else
    echo "  SKIP: no python3 to make a socket"
fi
_xi=0
_xprev=a
while [ "$_xi" -lt 40 ]; do
    ln -s "$_xprev" "$XL/w2/c$_xi"
    _xprev="c$_xi"
    _xi=$((_xi + 1))
done
o=$(xscan retire-volume)
assert_eq "a chain of 40 links inside it is fine" "1 0" \
    "$(has_line "$o" "external-worktree $XL/w2") $(xblocks "$o")"
ln -s c39 "$XL/w2/c40"
o=$(xscan retire-volume)
assert_eq "one of 41 is past the bound and blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (a link out: $XL/w2/c40)")"
rm -f "$XL"/w2/c[0-9]*
# Two admin dirs registering one directory: its .git names one of them.
cp -R "$XW/.git/worktrees/w2" "$XW/.git/worktrees/w2b"
o=$(xscan retire-volume)
assert_eq "a second registration of the same directory blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (its .git names another git dir)")"
rm -rf "$XW/.git/worktrees/w2b"
# What the admin dir records (an operation under way) lives in the
# volume: plain uncommitted.
mkdir "$XW/.git/worktrees/w2/rebase-merge"
o=$(xscan retire-volume)
assert_eq "an operation in its admin dir is plain uncommitted" "1 0" \
    "$(has_line "$o" "uncommitted operation .git/worktrees/w2/rebase-merge") $(grep -c '^layer-uncommitted operation' "$o/report" || true)"
rmdir "$XW/.git/worktrees/w2/rebase-merge"
# A listing that fails is not absence (search allowed, reading not).
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$XT/xnoread"
    printf '%s\n' "$XT/xnoread/gone/.git" > "$XW/.git/worktrees/w2/gitdir"
    chmod 100 "$XT/xnoread"
    o=$(xscan retire-volume)
    chmod 755 "$XT/xnoread"
    assert_eq "a missing entry in a directory that cannot be listed blocks" \
        "1" "$(has_line "$o" "block worktree-path $XT/xnoread/gone (cannot inspect $XT/xnoread)")"
    rm -rf "$XT/xnoread"
    printf '%s\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
else
    echo "  SKIP: as root every directory can be listed"
fi
# Nor is one in a directory that cannot be searched, even where it can
# be listed (GNU find lists it; macOS find does not).
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$XT/xnosearch"
    printf '%s\n' "$XT/xnosearch/gone/.git" > "$XW/.git/worktrees/w2/gitdir"
    chmod 400 "$XT/xnosearch"
    o=$(xscan retire-volume)
    chmod 755 "$XT/xnosearch"
    assert_eq "a missing entry in a directory that cannot be searched blocks" \
        "1" "$(has_line "$o" "block worktree-path $XT/xnosearch/gone (cannot inspect $XT/xnosearch)")"
    rm -rf "$XT/xnosearch"
    printf '%s\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
else
    echo "  SKIP: as root every directory can be searched"
fi
printf '%s\n\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
o=$(xscan retire-volume)
assert_eq "a back-pointer with a second line blocks" "1" \
    "$(has_line "$o" "block worktree-pointer .git/worktrees/w2 (not one short line)")"
printf '%s\r\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
o=$(xscan retire-volume)
assert_eq "so does one ending in CR LF" "1" \
    "$(has_line "$o" "block worktree-pointer .git/worktrees/w2 (not one short line)")"
printf '%s\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
# cleanup: a directory of its image at that path is the worktree only
# when its .git names the admin dir back.
o=$(xscan cleanup)
assert_eq "cleanup: the worktree itself there blocks" "1" \
    "$(has_line "$o" "block external $XL/w2 (present where cleanup scans)")"
mkdir -p "$XT/ximg"
printf '%s\n' "$XT/ximg/.git" > "$XW/.git/worktrees/w2/gitdir"
o=$(xscan cleanup)
assert_eq "cleanup: another directory there is left to retire" "1 0" \
    "$(has_line "$o" "deferred-worktree $XT/ximg") $(xblocks "$o")"
printf '%s\n' "$XL/w2/.git" > "$XW/.git/worktrees/w2/gitdir"
rm -rf "$XT/ximg"
# retire-layer: a registration into the volume (listed) blocks.
git clone -q "$XW" "$XT/xlc" 2>/dev/null
git -C "$XT/xlc" worktree add -q --detach "$XT/xlc-v" HEAD 2>/dev/null
mv "$XT/xlc/.git/worktrees/xlc-v" "$XT/xlc/.git/worktrees/v"
rm -rf "$XT/xlc-v"
printf '%s\n' "$XW/v/.git" > "$XT/xlc/.git/worktrees/v/gitdir"
o=$(scan worktree "$XT/xlc" layer SWARM_SCAN_ORIGIN=retire-layer \
    SWARM_SCAN_MOUNTS="$XW")
assert_eq "retire-layer: a registration into the volume blocks" "1" \
    "$(has_line "$o" "block worktree-path $XW/v (under a mount)")"
rm -rf "$XT/xlc"
# A path with a space and glob characters.
git -C "$XW" worktree add -q --detach "$XL/w t*?[x]" "$XBASE" 2>/dev/null
o=$(xscan retire-volume)
assert_eq "a path with a space and glob characters is let through" \
    "1 $XL/w t*?[x]" \
    "$(has_line "$o" "external-worktree $XL/w t*?[x]") $(xlist "$o" | grep -F "w t*?[x]")"
# Gone, beside a directory its name matches as a pattern: the listing
# looks for that very name.
rm -rf "$XL/w t*?[x]"
mkdir "$XL/w tzzx"
o=$(xscan retire-volume)
assert_eq "a gone one with glob characters beside a match is a note" "1 0" \
    "$(has_line "$o" "gone-worktree $XL/w t*?[x]") $(xblocks "$o")"
rmdir "$XL/w tzzx"
xdrop "w t*?[x]"
# The final check reads the report; a read that fails publishes nothing.
cat > "$XT/xgrep-env" <<'EOF'
grep() {
    if [ "$#" = 3 ] && [ "$1" = -q ] && [ "$2" = '^block ' ]; then
        return 2
    fi
    command grep "$@"
}
EOF
o=$(xscan retire-volume BASH_ENV="$XT/xgrep-env")
assert_eq "a report the last check cannot read: failure, no list" \
    "yes none" "$([ -e "$o/.rc" ] && echo yes || echo no) $(xlist "$o")"

# Published only at the scan's normal end, with no block anywhere.
xadd w3
mkfifo "$XL/w3/pipe"
o=$(xscan retire-volume)
assert_eq "one let through next to a block: no list" "1 none" \
    "$(has_line "$o" "external-worktree $XL/w2") $(xlist "$o")"
rm "$XL/w3/pipe"
mkdir -p "$XT/xfakebin"
cat > "$XT/xfakebin/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" != bundle ] || exit 1; done
exec "$(command -v git)" "\$@"
EOF
chmod +x "$XT/xfakebin/git"
o=$(xscan retire-volume PATH="$XT/xfakebin:$PATH")
assert_eq "a scan that fails after the checkout checks publishes no list" \
    "yes none" \
    "$([ -e "$o/.rc" ] && echo yes || echo no) $(xlist "$o")"
xdrop w2
xdrop w3
git -C "$XW" worktree prune

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
