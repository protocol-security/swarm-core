#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/target.sh: the TARGET_* checks and the resolution
# of a target into a snapshot.  Local repositories, and a fake ssh for
# the network cases (no Docker, no network).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
TMPDIR=$(cd -P "$TMPDIR" && pwd -P)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDS="$TMPDIR/pids"
: > "$PIDS"

# Stop what the timeout cases leave running (a helper outlives the Git
# process its alarm ends), then remove the files.
cleanup() {
    local helper sleeper
    while read -r helper sleeper; do
        kill "$helper" "$sleeper" 2>/dev/null || true
    done < "$PIDS"
    chmod -R u+w "$TMPDIR" 2>/dev/null || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

unset GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_EXEC_PATH

# shellcheck source=../lib/target.sh
source "$REPO_ROOT/lib/target.sh"

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
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual:              ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

assert_lacks() {
    local label="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  FAIL: ${label}"
        echo "        expected not to contain: ${needle}"
        echo "        actual:                  ${haystack}"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    fi
}

g() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        -c tag.gpgsign=false -c advice.nestedTag=false "$@"
}

# Print the status of a command, its output dropped.
status() {
    local rc=0
    "$@" > /dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# Print "<status>|<stderr>" of a command, its stdout dropped.
st_err() {
    local rc=0 e
    # shellcheck disable=SC2069  # stderr to the capture, stdout dropped
    e=$("$@" 2>&1 >/dev/null) || rc=$?
    printf '%s|%s' "$rc" "$e"
}

# Print the stderr of a command that is expected to fail.
errof() {
    # shellcheck disable=SC2069  # stderr to the caller, stdout dropped
    "$@" 2>&1 >/dev/null || true
}

# Print the names in directory $1, hidden ones too, sorted, on one line.
names_in() {
    local e out=""
    for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        out="${out}${e##*/}"$'\n'
    done
    printf '%s' "$out" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# A Git that logs each call (whether descriptor 8 is open, and
# SWARM_LOCK_FD) to $TMPDIR/git.log, then runs the real one.
REAL_GIT=$(command -v git)
mkdir -p "$TMPDIR/gitshim"
cat > "$TMPDIR/gitshim/git" <<EOF
#!/bin/bash
if { true >&8; } 2>/dev/null; then fd8=open; else fd8=closed; fi
echo "git fd8=\${fd8} lock=\${SWARM_LOCK_FD-unset} \$*" >> "$TMPDIR/git.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPDIR/gitshim/git"

# The source repository: main (three commits), feature, a light tag, an
# annotated tag, a tag of that tag, a tag of a tree, and a name that is
# both a branch and a tag.
SRC="$TMPDIR/src"
git init -q -b main "$SRC"
echo one > "$SRC/file"
g -C "$SRC" add file
g -C "$SRC" commit -q -m one
ONE=$(git -C "$SRC" rev-parse HEAD)
echo two > "$SRC/file"
g -C "$SRC" commit -q -am two
TWO=$(git -C "$SRC" rev-parse HEAD)
echo three > "$SRC/file"
g -C "$SRC" commit -q -am three
MAIN=$(git -C "$SRC" rev-parse HEAD)
g -C "$SRC" branch feature "$ONE"
g -C "$SRC" tag light "$ONE"
g -C "$SRC" tag -a annotated -m annotated "$TWO"
g -C "$SRC" tag -a nested -m nested annotated
g -C "$SRC" tag treetag "$TWO^{tree}"
g -C "$SRC" branch dup "$ONE"
g -C "$SRC" tag dup "$TWO"
# TWO is reachable from main, but no ref points at it directly.

# An unrelated repository for a base from elsewhere.
OTHER_SRC="$TMPDIR/other"
git init -q -b main "$OTHER_SRC"
g -C "$OTHER_SRC" commit -q --allow-empty -m other
OTHER=$(git -C "$OTHER_SRC" rev-parse HEAD)

RT="$TMPDIR/runtime"
mkdir -p "$RT"

# The resolution runs in its own Bash, with set -euo pipefail as in
# launch.sh: the checks, then swarm_target_resolve RUNTIME FORMAT.  It
# prints "<commit>|<base commit>" and writes the snapshot's path and the
# physical paths, one per line, to the file named by its third argument.
DRIVER="$TMPDIR/resolve.sh"
cat > "$DRIVER" <<EOF
#!/bin/bash
set -euo pipefail
source "$REPO_ROOT/lib/target.sh"
swarm_target_inputs_check
swarm_target_resolve "\$1" "\$2"
printf '%s\n' "\$SWARM_TARGET_PREP" "\$SWARM_TARGET_REPO_PHYSICAL" \
    "\$SWARM_TARGET_BASE_REPO_PHYSICAL" > "\$3"
printf '%s|%s\n' "\$SWARM_TARGET_COMMIT" "\$SWARM_TARGET_BASE_COMMIT"
EOF

# Resolve the TARGET_* variables of the environment into $RT, for a
# checkout of format FORMAT (default sha1), the driver's command line
# prefixed with ARGS; print "<status>|<commit>|<base commit>".  Its
# stderr goes to $TMPDIR/err.
resolve_with() {
    local rc=0 out=""
    : > "$TMPDIR/vars"
    out=$("$@" "$BASH" "$DRIVER" "$RT" "${FORMAT:-sha1}" "$TMPDIR/vars" \
        2> "$TMPDIR/err") || rc=$?
    printf '%s|%s' "$rc" "$out"
}

resolve() {
    resolve_with
}

prep() { sed -n 1p "$TMPDIR/vars"; }
err() { cat "$TMPDIR/err"; }

# What the resolution left in $RT, scratch suffixes replaced by '*'.
left() {
    names_in "$RT" | sed 's/\.target-\([a-z]*\)\.[^ ]*/.target-\1.*/g'
}

# The refs of the last snapshot: "<ref> <id>" per line, joined by ";".
snapshot_refs() {
    git --git-dir="$(prep)" for-each-ref \
        --format='%(refname) %(objectname)' | tr '\n' ';' | sed 's/;$//'
}

drop_prep() {
    local p
    p=$(prep)
    [ -z "$p" ] || rm -rf "$p"
}

echo "=== 1. Input checks ==="
for v in /abs/repo ssh://host/repo ssh://git@host:2222/repo \
        git@host:org/repo.git host:repo https://example.com/org/repo.git \
        'ssh://[::1]/repo' '[::1]:repo'; do
    assert_eq "repository ${v} is accepted" 0 \
        "$(status swarm_target_repo_check TARGET_REPO "$v")"
done
check_repo_refused() {
    local out
    out=$(st_err swarm_target_repo_check TARGET_REPO "$1")
    assert_eq "repository $(printf '%q' "$1") is refused" 1 "${out%%|*}"
    assert_contains "  saying so" "$2" "${out#*|}"
}
check_repo_refused '' "TARGET_REPO is set but empty"
check_repo_refused repo "relative path"
check_repo_refused ./repo "relative path"
check_repo_refused -oProxyCommand=x "starts with a dash"
check_repo_refused 'ext::sh -c x' "transport helper"
check_repo_refused 'fd::0' "transport helper"
check_repo_refused file:///abs/repo "file:// URL"
check_repo_refused http://example.com/repo "plain http://"
check_repo_refused https://user@example.com/repo "user name or a credential"
check_repo_refused https://user:pw@example.com/repo "user name or a credential"
check_repo_refused 'https://example.com/repo?x=1' "query or a fragment"
check_repo_refused 'https://example.com/repo#x' "query or a fragment"
check_repo_refused git://example.com/repo "scheme other than"
check_repo_refused HTTPS://example.com/repo "scheme other than"
check_repo_refused $'/abs/re\npo' "control character"
check_repo_refused $'/abs/re\tpo' "control character"

HEX40=0123456789abcdef0123456789abcdef01234567
HEX64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
for v in main feature/x v1.0 refs/heads/main refs/tags/v1 "$HEX40" \
        "$HEX64" abc1234 0123456789ABCDEF0123456789ABCDEF01234567; do
    assert_eq "revision ${v} passes the check" 0 \
        "$(status swarm_target_rev_check TARGET_REV "$v")"
done
check_rev_refused() {
    local out
    out=$(st_err swarm_target_rev_check TARGET_REV "$1")
    assert_eq "revision $(printf '%q' "$1") is refused" 1 "${out%%|*}"
    assert_contains "  saying so" "$2" "${out#*|}"
}
check_rev_refused '' "TARGET_REV is set but empty"
check_rev_refused -x "starts with a dash"
check_rev_refused 'main^' "no full commit id, full ref, branch or tag name"
check_rev_refused 'main~1' "no full commit id, full ref, branch or tag name"
check_rev_refused 'HEAD@{1}' "no full commit id, full ref, branch or tag name"
check_rev_refused 'a..b' "no full commit id, full ref, branch or tag name"
check_rev_refused 'a b' "no full commit id, full ref, branch or tag name"
check_rev_refused 'x:y' "no full commit id, full ref, branch or tag name"
check_rev_refused refs/remotes/origin/main "outside refs/heads/ and refs/tags/"
check_rev_refused refs/heads/a..b "not a valid ref"
check_rev_refused $'ma\nin' "control character"

# The ref name rules, checked without Git, agree with Git's.
for r in refs/heads/main refs/heads refs/heads/x/y refs/heads/-x \
        refs/heads/a@b refs/heads/@ 'refs/heads/{x}' 'refs/heads/a!b' \
        'refs/heads/a#b' refs/heads/a.b refs/heads/é refs @ \
        refs/heads/a..b refs/heads/a.lock refs/heads/a.lock/b \
        refs/heads/.a refs/heads/a/.b refs/heads/a. refs/heads/a/ \
        /refs/heads/a refs/heads//a 'refs/heads/a@{b' 'refs/heads/a b' \
        'refs/heads/a~b' 'refs/heads/a^b' refs/heads/a:b 'refs/heads/a?b' \
        'refs/heads/a*b' 'refs/heads/a[b' 'refs/heads/a\b' \
        $'refs/heads/a\tb' $'refs/heads/a\177b'; do
    want=bad
    git check-ref-format "$r" 2>/dev/null && want=ok
    got=bad
    _swarm_target_refname_ok "$r" && got=ok
    assert_eq "ref name $(printf '%q' "$r") as Git judges it" "$want" "$got"
done

assert_eq "a 40-digit id is a full id" 0 \
    "$(status swarm_target_full_id "$HEX40")"
assert_eq "a 64-digit id is a full id" 0 \
    "$(status swarm_target_full_id "$HEX64")"
assert_eq "39 digits are not" 1 "$(status swarm_target_full_id "${HEX40%?}")"
assert_eq "41 digits are not" 1 "$(status swarm_target_full_id "${HEX40}0")"
assert_eq "upper case is not" 1 \
    "$(status swarm_target_full_id 0123456789ABCDEF0123456789ABCDEF01234567)"
assert_eq "a non-hex digit is not" 1 \
    "$(status swarm_target_full_id 0123456789abcdef0123456789abcdef0123456g)"
assert_eq "nothing is not" 1 "$(status swarm_target_full_id '')"

assert_eq "1 second" 1 "$(swarm_target_seconds T 1)"
assert_eq "86400 seconds" 86400 "$(swarm_target_seconds T 86400)"
assert_eq "leading zeros are decimal" 7 "$(swarm_target_seconds T 007)"
for v in 0 86401 '' 1e3 -1 999999 ' 5'; do
    assert_eq "timeout $(printf '%q' "$v") is refused" 1 \
        "$(status swarm_target_seconds T "$v")"
done

assert_eq "no input variable: no target" 1 "$(status swarm_target_requested)"
assert_eq "an empty one asks for a target" 0 \
    "$(TARGET_REV_BASE='' status swarm_target_requested)"
inputs() {
    local rc=0
    swarm_target_inputs_check 2> "$TMPDIR/ierr" || rc=$?
    printf '%s|%s' "$rc" "$SWARM_TARGET_BASE_REPO_EFFECTIVE"
}
assert_eq "nothing set refuses" "1|" "$(inputs)"
assert_eq "TARGET_REPO alone refuses" "1|" "$(TARGET_REPO=/r inputs)"
assert_eq "TARGET_REV alone refuses" "1|" "$(TARGET_REV=main inputs)"
assert_contains "and says both are needed" \
    "needs both TARGET_REPO and TARGET_REV" \
    "$(cat "$TMPDIR/ierr")"
assert_eq "a target without a base" "0|" \
    "$(TARGET_REPO=/r TARGET_REV=main inputs)"
assert_eq "a base from the target's repository" "0|/r" \
    "$(TARGET_REPO=/r TARGET_REV=main TARGET_REV_BASE=b inputs)"
assert_eq "a base from another repository" "0|/o" \
    "$(TARGET_REPO=/r TARGET_REV=main TARGET_REV_BASE=b \
        TARGET_REV_BASE_REPO=/o inputs)"
assert_eq "TARGET_REV_BASE_REPO without TARGET_REV_BASE refuses" "1|" \
    "$(TARGET_REPO=/r TARGET_REV=main TARGET_REV_BASE_REPO=/o inputs)"
assert_eq "an empty TARGET_REV_BASE refuses" "1|" \
    "$(TARGET_REPO=/r TARGET_REV=main TARGET_REV_BASE='' inputs)"
assert_eq "a bad TARGET_REV_BASE_REPO refuses" "1|" \
    "$(TARGET_REPO=/r TARGET_REV=main TARGET_REV_BASE=b \
        TARGET_REV_BASE_REPO=rel inputs)"
: > "$TMPDIR/git.log"
assert_eq "the input checks" "0|/r" \
    "$(PATH="$TMPDIR/gitshim:$PATH" TARGET_REPO=/r TARGET_REV=main \
        TARGET_REV_BASE=refs/tags/v1 inputs)"
assert_eq "  run no Git" "" "$(cat "$TMPDIR/git.log")"

echo ""
echo "=== 2. Resolution from a local repository ==="
for case in "main:$MAIN" "refs/heads/main:$MAIN" "light:$ONE" \
        "annotated:$TWO" "nested:$TWO" "refs/tags/annotated:$TWO" \
        "${TWO}:$TWO" "feature:$ONE"; do
    rev="${case%%:*}"
    want="${case#*:}"
    assert_eq "${rev} resolves to its commit" "0|${want}|" \
        "$(TARGET_REPO="$SRC" TARGET_REV="$rev" resolve)"
    assert_eq "  the snapshot holds only the pin" \
        "refs/swarm/target ${want}" "$(snapshot_refs)"
    assert_eq "  a direct pin to a commit" commit \
        "$(git --git-dir="$(prep)" cat-file -t refs/swarm/target)"
    assert_eq "  only the snapshot is left" ".target-prep.*" "$(left)"
    drop_prep
done

TARGET_REPO="$SRC" TARGET_REV=annotated resolve > /dev/null
P=$(prep)
assert_eq "no fetch traces in the snapshot" "HEAD config objects refs" \
    "$(names_in "$P")"
assert_eq "it passes git fsck" 0 "$(status git --git-dir="$P" fsck --full)"
assert_eq "every file is readable by others" "" \
    "$(find "$P" ! -perm -004 -print)"
assert_eq "every directory can be entered by others" "" \
    "$(find "$P" -type d ! -perm -005 -print)"
assert_eq "its history is complete" "$TWO $ONE" \
    "$(git --git-dir="$P" rev-list refs/swarm/target | tr '\n' ' ' \
        | sed 's/ $//')"
drop_prep

assert_eq "a base from the same repository" "0|${MAIN}|${ONE}" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=feature resolve)"
assert_eq "  two pins" \
    "refs/swarm/target ${MAIN};refs/swarm/target-base ${ONE}" \
    "$(snapshot_refs)"
drop_prep
assert_eq "a base equal to the target" "0|${MAIN}|${MAIN}" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=main resolve)"
assert_eq "  two pins to the same commit" \
    "refs/swarm/target ${MAIN};refs/swarm/target-base ${MAIN}" \
    "$(snapshot_refs)"
drop_prep
assert_eq "a base from another repository" "0|${MAIN}|${OTHER}" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=main \
        TARGET_REV_BASE_REPO="$OTHER_SRC" resolve)"
assert_eq "  that snapshot passes git fsck" 0 \
    "$(status git --git-dir="$(prep)" fsck --full)"
drop_prep

g -C "$SRC" branch v9 "$ONE"
g -C "$SRC" branch x/refs/tags/v9 "$TWO"
assert_eq "a branch whose name ends like a tag's is no tag" "0|${ONE}|" \
    "$(TARGET_REPO="$SRC" TARGET_REV=v9 resolve)"
drop_prep

ln -s "$SRC" "$TMPDIR/src-link"
assert_eq "a repository through a symlink" "0|${MAIN}|" \
    "$(TARGET_REPO="$TMPDIR/src-link" TARGET_REV=main resolve)"
assert_eq "  its physical path is recorded" "$SRC" \
    "$(sed -n 2p "$TMPDIR/vars")"
drop_prep

# Resolve with the variable assignments ARGS (FORMAT, when the caller
# sets it, picks the checkout's format) and check that it refuses with
# MSG and leaves nothing.
refused() {
    local label="$1" msg="$2" out
    shift 2
    out=$(resolve_with env "$@")
    assert_eq "${label} refuses" 1 "${out%%|*}"
    assert_contains "  saying so" "$msg" "$(err)"
    assert_eq "  and leaves nothing" "" "$(left)"
}
refused "a branch and a tag of one name" \
    "TARGET_REV names both a branch and a tag (dup)" \
    TARGET_REPO="$SRC" TARGET_REV=dup
refused "a name that is no branch or tag" \
    "TARGET_REV (nope) is no branch or tag of its repository" \
    TARGET_REPO="$SRC" TARGET_REV=nope
refused "an abbreviated id" "is no branch or tag of its repository" \
    TARGET_REPO="$SRC" TARGET_REV="${MAIN:0:7}"
refused "a tag of a tree" \
    "TARGET_REV (treetag) is not a commit, nor a tag of one" \
    TARGET_REPO="$SRC" TARGET_REV=treetag
refused "a full ref that does not exist" \
    "TARGET_REV (refs/heads/nope) is no ref of its repository" \
    TARGET_REPO="$SRC" TARGET_REV=refs/heads/nope
# Git's fetch would take refs/heads/refs/heads/ghost for a missing
# refs/heads/ghost (its rules for abbreviated names).
g -C "$SRC" update-ref refs/heads/refs/heads/ghost "$TWO"
git init -q --bare "$TMPDIR/probe.git"
git --git-dir="$TMPDIR/probe.git" fetch -q "$SRC" refs/heads/ghost:refs/x
assert_eq "(plain fetch takes another ref for a missing full ref)" "$TWO" \
    "$(git --git-dir="$TMPDIR/probe.git" rev-parse refs/x)"
refused "a full ref the repository lacks, with one Git would take for it" \
    "TARGET_REV (refs/heads/ghost) is no ref of its repository" \
    TARGET_REPO="$SRC" TARGET_REV=refs/heads/ghost
refused "the same as the base" \
    "TARGET_REV_BASE (refs/heads/ghost) is no ref of its repository" \
    TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=refs/heads/ghost
refused "the same as a name" \
    "TARGET_REV (ghost) is no branch or tag of its repository" \
    TARGET_REPO="$SRC" TARGET_REV=ghost
g -C "$SRC" update-ref -d refs/heads/refs/heads/ghost
HINT="a server may refuse to serve a commit by id: give a branch or a tag"
refused "an id the repository does not have" "(${HINT} that reaches it)" \
    TARGET_REPO="$SRC" TARGET_REV="$HEX40"
refused "a missing base" "TARGET_REV_BASE (nope) is no branch or tag" \
    TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=nope
refused "a missing directory" "no directory at $TMPDIR/missing" \
    TARGET_REPO="$TMPDIR/missing" TARGET_REV=main
git clone -q --depth 1 "file://$SRC" "$TMPDIR/shallow"
refused "a shallow repository" \
    "fetching TARGET_REV (refs/heads/main at ${MAIN}) did not bring it" \
    TARGET_REPO="$TMPDIR/shallow" TARGET_REV=main
mkdir -p "$TMPDIR/initshim"
cat > "$TMPDIR/initshim/git" <<EOF
#!/bin/bash
case " \$* " in
    *" init -h "*)
        [ -z "\${INIT_EXIT:-}" ] || exit "\$INIT_EXIT"
        kill -ALRM \$\$ ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPDIR/initshim/git"
refused "a git init -h past its bound" \
    "asking git init for its options took longer than 600 seconds" \
    PATH="$TMPDIR/initshim:$PATH" TARGET_REPO="$SRC" TARGET_REV=main
refused "a git init -h that fails" \
    "asking git init for its options failed (status 127)" \
    PATH="$TMPDIR/initshim:$PATH" INIT_EXIT=127 TARGET_REPO="$SRC" \
    TARGET_REV=main
FORMAT=md5 refused "an unknown object format" "unknown object format: md5" \
    TARGET_REPO="$SRC" TARGET_REV=main

SRC256="$TMPDIR/src256"
git init -q -b main --object-format=sha256 "$SRC256"
g -C "$SRC256" commit -q --allow-empty -m one
MAIN256=$(git -C "$SRC256" rev-parse HEAD)
assert_eq "a SHA-256 target for a SHA-256 checkout" "0|${MAIN256}|" \
    "$(FORMAT=sha256 TARGET_REPO="$SRC256" TARGET_REV=main resolve)"
assert_eq "  a SHA-256 snapshot" sha256 \
    "$(git --git-dir="$(prep)" rev-parse --show-object-format)"
drop_prep
refused "a SHA-256 target for a SHA-1 checkout" \
    "TARGET_REV's repository lists no sha1 id for refs/heads/main" \
    TARGET_REPO="$SRC256" TARGET_REV=main
FORMAT=sha256 refused "a SHA-1 target for a SHA-256 checkout" \
    "TARGET_REV's repository lists no sha256 id for refs/heads/main" \
    TARGET_REPO="$SRC" TARGET_REV=main
FORMAT=sha256 refused "a SHA-1 commit id for a SHA-256 checkout" \
    "TARGET_REV is a 40-digit commit id" TARGET_REPO="$SRC" TARGET_REV="$MAIN"
refused "a SHA-256 id from a SHA-256 repository for a SHA-1 checkout" \
    "TARGET_REV is a 64-digit commit id" \
    TARGET_REPO="$SRC256" TARGET_REV="$MAIN256"

# A full id of the other format is no id to Git but a ref name: a
# branch of that name must not stand in for it.
OTHER_FORMAT="commit id, but this checkout's objects are"
g -C "$SRC" update-ref "refs/heads/$HEX64" "$ONE"
assert_contains "(Git takes it for that branch)" "$ONE" \
    "$(git ls-remote "$SRC" "refs/heads/$HEX64")"
refused "a 64-digit id for a SHA-1 checkout, with a branch of that name" \
    "TARGET_REV is a 64-digit ${OTHER_FORMAT} sha1" \
    TARGET_REPO="$SRC" TARGET_REV="$HEX64"
refused "the same as the base" \
    "TARGET_REV_BASE is a 64-digit commit id" \
    TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE="$HEX64"
g -C "$SRC" update-ref -d "refs/heads/$HEX64"
g -C "$SRC256" update-ref "refs/heads/$HEX40" "$MAIN256"
FORMAT=sha256 refused \
    "a 40-digit id for a SHA-256 checkout, with a branch of that name" \
    "TARGET_REV is a 40-digit ${OTHER_FORMAT} sha256" \
    TARGET_REPO="$SRC256" TARGET_REV="$HEX40"
g -C "$SRC256" update-ref -d "refs/heads/$HEX40"

assert_contains "a relative runtime directory refuses" \
    "the runtime directory must be absolute" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main errof "$BASH" "$DRIVER" rel sha1 \
        "$TMPDIR/vars")"
assert_contains "a missing runtime directory refuses" \
    "cannot make a scratch directory in $TMPDIR/no-runtime" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main errof "$BASH" "$DRIVER" \
        "$TMPDIR/no-runtime" sha1 "$TMPDIR/vars")"
assert_contains "a bad SWARM_TARGET_TIMEOUT refuses" \
    "SWARM_TARGET_TIMEOUT must be a whole number" \
    "$(SWARM_TARGET_TIMEOUT=0 TARGET_REPO="$SRC" TARGET_REV=main errof \
        "$BASH" "$DRIVER" "$RT" sha1 "$TMPDIR/vars")"
assert_contains "a bad SWARM_TARGET_VERIFY_TIMEOUT refuses" \
    "SWARM_TARGET_VERIFY_TIMEOUT must be a whole number" \
    "$(SWARM_TARGET_VERIFY_TIMEOUT=x TARGET_REPO="$SRC" TARGET_REV=main \
        errof "$BASH" "$DRIVER" "$RT" sha1 "$TMPDIR/vars")"
assert_eq "  neither leaves anything" "" "$(left)"

echo ""
echo "=== 3. The caller's Git variables stay out ==="
# A user configuration NAME, from stdin: $TMPDIR/home-NAME/.gitconfig.
# Git before 2.32 has no GIT_CONFIG_GLOBAL and reads $HOME/.gitconfig;
# userenv NAME prints the assignments for both.
user_config() {
    mkdir -p "$TMPDIR/home-$1"
    cat > "$TMPDIR/home-$1/.gitconfig"
}
userenv() {
    printf '%s\n' "HOME=$TMPDIR/home-$1" "XDG_CONFIG_HOME=$TMPDIR/home-$1" \
        "GIT_CONFIG_GLOBAL=$TMPDIR/home-$1/.gitconfig"
}

# Without the clearing, the injected rewrite would send the fetch to
# the other repository.  (GIT_CONFIG_COUNT exists from Git 2.31.)
if [ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=z \
        git config --get x.y 2>/dev/null || true)" = z ]; then
    assert_contains "(the injected rewrite works on plain git)" "$OTHER" \
        "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.${OTHER_SRC}.insteadOf" \
            GIT_CONFIG_VALUE_0="$SRC" git ls-remote "$SRC" refs/heads/main)"
fi
assert_eq "settings injected through GIT_CONFIG_COUNT are dropped" \
    "0|${MAIN}|" \
    "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.${OTHER_SRC}.insteadOf" \
        GIT_CONFIG_VALUE_0="$SRC" TARGET_REPO="$SRC" TARGET_REV=main resolve)"
drop_prep
assert_contains "(GIT_CONFIG_PARAMETERS works on plain git)" "$OTHER" \
    "$(GIT_CONFIG_PARAMETERS="'url.${OTHER_SRC}.insteadof=${SRC}'" \
        git ls-remote "$SRC" refs/heads/main)"
assert_eq "so are those through GIT_CONFIG_PARAMETERS" "0|${MAIN}|" \
    "$(GIT_CONFIG_PARAMETERS="'url.${OTHER_SRC}.insteadof=${SRC}'" \
        TARGET_REPO="$SRC" TARGET_REV=main resolve)"
drop_prep
assert_eq "GIT_OBJECT_DIRECTORY does not redirect the objects" "0|${MAIN}|" \
    "$(GIT_OBJECT_DIRECTORY="$TMPDIR/odb" TARGET_REPO="$SRC" \
        TARGET_REV=main resolve)"
assert_eq "  nothing was written there" no \
    "$([ -e "$TMPDIR/odb" ] && echo yes || echo no)"
drop_prep

# A URL rewrite in the user's configuration stays (it is theirs), but
# only file, ssh and https remain allowed after it.
user_config ext <<EOF
[url "ext::sh -c touch% $TMPDIR/pwned% #"]
    insteadOf = https://target.invalid/
[protocol "ext"]
    allow = always
EOF
# shellcheck disable=SC2046  # one assignment per line
env $(userenv ext) git ls-remote https://target.invalid/x \
    > /dev/null 2>&1 || true
assert_eq "(plain git follows that rewrite)" yes \
    "$([ -e "$TMPDIR/pwned" ] && echo yes || echo no)"
rm -f "$TMPDIR/pwned"
# shellcheck disable=SC2046
refused "a rewrite to another transport" \
    "listing the refs of TARGET_REV's repository" \
    $(userenv ext) TARGET_REPO=https://target.invalid/x TARGET_REV=main
assert_eq "  the transport never ran" no \
    "$([ -e "$TMPDIR/pwned" ] && echo yes || echo no)"

# A rewrite can bring a credential the inputs never had: Git's messages
# show it, the resolution's do not.
user_config secret <<EOF
[url "https://127.0.0.1:1/x?token=SECRET123"]
    insteadOf = https://target.invalid/
EOF
# shellcheck disable=SC2046
assert_contains "(plain git shows the token)" "SECRET123" \
    "$(env $(userenv secret) git ls-remote https://target.invalid/r 2>&1 \
        || true)"
# shellcheck disable=SC2046
refused "a rewrite to a URL with a token" "<masked-url>" \
    $(userenv secret) SWARM_TARGET_TIMEOUT=20 \
    TARGET_REPO=https://target.invalid/r TARGET_REV=main
assert_lacks "  without showing it" "SECRET123" "$(err)"
user_config secret2 <<EOF
[url "https://us'er:p@ss@127.0.0.1:1/x?label='build'&token=SECRET456"]
    insteadOf = https://target.invalid/
EOF
# shellcheck disable=SC2046
refused "a token after a quote, a password with an @" "<masked-url>" \
    $(userenv secret2) SWARM_TARGET_TIMEOUT=20 \
    TARGET_REPO=https://target.invalid/r TARGET_REV=main
assert_lacks "  shows neither the token" "SECRET456" "$(err)"
assert_lacks "  nor any of the password" "ss@" "$(err)"
# Git's anonymizing takes a query with an @ but no slash before it for
# user information, and prints the rest as a host.
user_config secret3 <<EOF
[url "https://127.0.0.1:1?token=PREFIX@SECRET789"]
    insteadOf = https://target.invalid/
[url "https://127.0.0.1:1#frag@SECRET790"]
    insteadOf = https://target2.invalid/
EOF
# shellcheck disable=SC2046
refused "a query with an @ and no slash" "<masked-url>" \
    $(userenv secret3) SWARM_TARGET_TIMEOUT=20 \
    TARGET_REPO=https://target.invalid/r TARGET_REV=main
assert_lacks "  without showing it" "SECRET789" "$(err)"
# shellcheck disable=SC2046
refused "a fragment with an @ and no slash" "<masked-url>" \
    $(userenv secret3) SWARM_TARGET_TIMEOUT=20 \
    TARGET_REPO=https://target2.invalid/r TARGET_REV=main
assert_lacks "  without showing it" "SECRET790" "$(err)"
# The masking itself, on lines Git might print.
printf '%s\n' "fatal: 'https://u:p@ss@h/r?a='b'&t=S1 x': failed" \
    "ssh://git@h/r#S2 and https://h/q?S3" \
    "Could not resolve host: ss@127.0.0.1; git@h: denied x@y@z" \
    "fatal: unable to access 'https://SECRET/': Failed to connect" \
    "fatal: '/abs/repo' does not appear to be a git repository" \
    > "$TMPDIR/mask.in"
MASKED="  fatal: '<masked-url> x': failed;  <masked-url> and <masked-url>;"
MASKED="${MASKED}  Could not resolve host: <masked>@127.0.0.1; <masked>@h:"
MASKED="${MASKED} denied <masked>@z;"
MASKED="${MASKED}  fatal: unable to access '<masked-url> Failed to connect;"
MASKED="${MASKED}  fatal: '/abs/repo' does not appear to be a git repository"
assert_eq "masking, on its own" "$MASKED" \
    "$(_swarm_target_show "$TMPDIR/mask.in" 2>&1 | tr '\n' ';' \
        | sed 's/;$//')"

# The local commands read no user configuration: a rewrite of the
# network scratch's path would send the local copy elsewhere.
user_config local <<EOF
[url "$OTHER_SRC"]
    insteadOf = $RT/.target-fetch
EOF
# shellcheck disable=SC2046
assert_contains "(plain git follows that rewrite)" "$OTHER" \
    "$(env $(userenv local) git ls-remote "$RT/.target-fetch" 2>/dev/null)"
# shellcheck disable=SC2046
assert_eq "the user's configuration does not reach the local copy" \
    "0|${MAIN}|" \
    "$(resolve_with env $(userenv local) TARGET_REPO="$SRC" TARGET_REV=main)"
drop_prep

# The user's fetch.writeCommitGraph would start Git's progress
# machinery, which replaces the alarm: the network commands keep the
# user's configuration but never write a commit-graph.
user_config graph <<EOF
[fetch]
    writeCommitGraph = true
EOF
# Print yes when repository $1 has a commit-graph, else no.
has_graph() {
    local f
    for f in "$1"/objects/info/commit-graph*; do
        if [ -e "$f" ]; then
            echo yes
            return 0
        fi
    done
    echo no
}
git init -q --bare "$TMPDIR/plain.git"
# shellcheck disable=SC2046
env $(userenv graph) git --git-dir="$TMPDIR/plain.git" fetch -q "$SRC" \
    +refs/heads/main:refs/x
assert_eq "(a plain fetch with that setting writes a commit-graph)" yes \
    "$(has_graph "$TMPDIR/plain.git")"
git init -q --bare "$TMPDIR/net.git"
(
    SWARM_TARGET_TMP="$TMPDIR"
    # shellcheck disable=SC2046
    export $(userenv graph)
    _swarm_target_git_net 60 "$TMPDIR/net.git" fetch --no-progress \
        --quiet -- "$SRC" +refs/heads/main:refs/x
)
assert_eq "the network wrapper fetched" "$MAIN" \
    "$(git --git-dir="$TMPDIR/net.git" rev-parse refs/x)"
assert_eq "  and wrote no commit-graph" no "$(has_graph "$TMPDIR/net.git")"

echo ""
echo "=== 4. Network commands through a fake ssh ==="
BIN="$TMPDIR/bin"
mkdir -p "$BIN" "$TMPDIR/sshbin"
cat > "$BIN/fake-ssh" <<'EOF'
#!/bin/bash
# Stands in for ssh: logs the call (whether descriptor 8 is open, and
# SWARM_LOCK_FD), runs FAKE_SSH_HOOK before call FAKE_SSH_HOOK_ON, sleeps
# on call FAKE_SSH_SLEEP_ON, then runs the remote command here.
args="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        -o|-p) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
host="$1"
shift
if { true >&8; } 2>/dev/null; then fd8=open; else fd8=closed; fi
echo "call host=${host} fd8=${fd8} lock=${SWARM_LOCK_FD-unset} args=${args}" \
    >> "$FAKE_SSH_LOG"
n=$(grep -c '^call ' "$FAKE_SSH_LOG")
if [ "$n" = "${FAKE_SSH_HOOK_ON:-0}" ]; then
    eval "$FAKE_SSH_HOOK"
fi
if [ "$n" = "${FAKE_SSH_SLEEP_ON:-0}" ]; then
    sleep 8 &
    echo "$$ $!" >> "$FAKE_SSH_PIDS"
    wait "$!" || true
fi
exec /bin/sh -c "$*"
EOF
chmod +x "$BIN/fake-ssh"
ln -s "$BIN/fake-ssh" "$TMPDIR/sshbin/ssh"
export FAKE_SSH_LOG="$TMPDIR/ssh.log" FAKE_SSH_PIDS="$PIDS"
SSHENV=(GIT_SSH_COMMAND="$BIN/fake-ssh" GIT_SSH_VARIANT=ssh)
calls() { grep -c '^call ' "$FAKE_SSH_LOG" || true; }

: > "$FAKE_SSH_LOG"
assert_eq "a branch over ssh (scp-like)" "0|${MAIN}|" \
    "$(resolve_with env "${SSHENV[@]}" TARGET_REPO="fakehost:$SRC" \
        TARGET_REV=main)"
assert_eq "  one ls-remote and one fetch" 2 "$(calls)"
drop_prep
: > "$FAKE_SSH_LOG"
assert_eq "a full ref over ssh://" "0|${MAIN}|" \
    "$(resolve_with env "${SSHENV[@]}" TARGET_REPO="ssh://fakehost$SRC" \
        TARGET_REV=refs/heads/main)"
assert_eq "  is listed, then fetched by its id" 2 "$(calls)"
drop_prep
: > "$FAKE_SSH_LOG"
assert_eq "a base equal to the target over ssh" "0|${MAIN}|${MAIN}" \
    "$(resolve_with env "${SSHENV[@]}" TARGET_REPO="fakehost:$SRC" \
        TARGET_REV=main TARGET_REV_BASE=main)"
assert_eq "  is fetched once" 2 "$(calls)"
drop_prep
: > "$FAKE_SSH_LOG"
g -C "$SRC" branch side "$ONE"
git -C "$SRC" checkout -q side
g -C "$SRC" commit -q --allow-empty -m side
SIDE=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q main
assert_eq "another base from the same repository over ssh" \
    "0|${MAIN}|${SIDE}" \
    "$(resolve_with env "${SSHENV[@]}" TARGET_REPO="fakehost:$SRC" \
        TARGET_REV=main TARGET_REV_BASE=side)"
assert_eq "  is listed and fetched on its own" 4 "$(calls)"
drop_prep

: > "$FAKE_SSH_LOG"
assert_eq "plain ssh from PATH" "0|${MAIN}|" \
    "$(PATH="$TMPDIR/sshbin:$PATH" TARGET_REPO="fakehost:$SRC" \
        TARGET_REV=main resolve)"
assert_contains "  runs in batch mode" "-o BatchMode=yes" \
    "$(cat "$FAKE_SSH_LOG")"
drop_prep
user_config sshcmd <<EOF
[core]
    sshCommand = $BIN/fake-ssh
EOF
: > "$FAKE_SSH_LOG"
# shellcheck disable=SC2046
assert_eq "core.sshCommand from the user's configuration" "0|${MAIN}|" \
    "$(resolve_with env $(userenv sshcmd) GIT_SSH_VARIANT=ssh \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main)"
assert_eq "  is used as it is" 2 "$(calls)"
assert_lacks "  without batch mode added" "BatchMode" "$(cat "$FAKE_SSH_LOG")"
drop_prep
: > "$FAKE_SSH_LOG"
assert_eq "GIT_SSH" "0|${MAIN}|" \
    "$(GIT_SSH="$BIN/fake-ssh" GIT_SSH_VARIANT=ssh \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main resolve)"
assert_lacks "  is used as it is too" "BatchMode" "$(cat "$FAKE_SSH_LOG")"
drop_prep

# An empty GIT_SSH_COMMAND or GIT_SSH counts as unset.
: > "$FAKE_SSH_LOG"
# shellcheck disable=SC2046
assert_eq "an empty GIT_SSH_COMMAND with core.sshCommand" "0|${MAIN}|" \
    "$(resolve_with env $(userenv sshcmd) GIT_SSH_COMMAND= \
        GIT_SSH_VARIANT=ssh TARGET_REPO="fakehost:$SRC" TARGET_REV=main)"
assert_eq "  uses core.sshCommand" 2 "$(calls)"
assert_lacks "  as it is" "BatchMode" "$(cat "$FAKE_SSH_LOG")"
drop_prep
: > "$FAKE_SSH_LOG"
assert_eq "an empty GIT_SSH_COMMAND with GIT_SSH" "0|${MAIN}|" \
    "$(resolve_with env GIT_SSH_COMMAND= GIT_SSH="$BIN/fake-ssh" \
        GIT_SSH_VARIANT=ssh TARGET_REPO="fakehost:$SRC" TARGET_REV=main)"
assert_eq "  uses GIT_SSH" 2 "$(calls)"
drop_prep
: > "$FAKE_SSH_LOG"
assert_eq "an empty GIT_SSH" "0|${MAIN}|" \
    "$(resolve_with env GIT_SSH= PATH="$TMPDIR/sshbin:$PATH" \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main)"
assert_contains "  leaves batch mode" "-o BatchMode=yes" \
    "$(cat "$FAKE_SSH_LOG")"
drop_prep
user_config incl <<EOF
[include]
    path = $TMPDIR/home-sshcmd/.gitconfig
EOF
: > "$FAKE_SSH_LOG"
# shellcheck disable=SC2046
assert_eq "core.sshCommand through an include" "0|${MAIN}|" \
    "$(resolve_with env $(userenv incl) GIT_SSH_VARIANT=ssh \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main)"
assert_eq "  is used" 2 "$(calls)"
assert_lacks "  as it is" "BatchMode" "$(cat "$FAKE_SSH_LOG")"
drop_prep

# The commit is the one ls-remote listed for exactly that name, fetched
# by its id: a branch that moves or goes after ls-remote is pinned where
# it was listed, never replaced by a ref whose name Git would expand to.
# Print the id exactly ref $1 of the source holds, or "none" (rev-parse
# would expand the name as fetch does).
src_ref() {
    git -C "$SRC" show-ref --verify --hash -- "$1" 2>/dev/null || echo none
}
g -C "$SRC" branch moving "$ONE"
: > "$FAKE_SSH_LOG"
assert_eq "a branch that moves after ls-remote" "0|${ONE}|" \
    "$(resolve_with env "${SSHENV[@]}" FAKE_SSH_HOOK_ON=2 \
        FAKE_SSH_HOOK="git -C '$SRC' update-ref refs/heads/moving $MAIN" \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=moving)"
assert_eq "  (it moved)" "$MAIN" "$(src_ref refs/heads/moving)"
drop_prep
g -C "$SRC" branch gone "$ONE"
g -C "$SRC" update-ref refs/heads/refs/heads/gone "$TWO"
: > "$FAKE_SSH_LOG"
assert_eq "a branch deleted after ls-remote, with a ref Git would take" \
    "0|${ONE}|" \
    "$(resolve_with env "${SSHENV[@]}" FAKE_SSH_HOOK_ON=2 \
        FAKE_SSH_HOOK="git -C '$SRC' update-ref -d refs/heads/gone" \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=gone)"
assert_eq "  (it was deleted)" none "$(src_ref refs/heads/gone)"
drop_prep
# A base on a commit of its own: the target's fetch does not bring it,
# so the base's fetch is a call of its own (calls 1 and 2 are the
# target's, 3, the ls-remote, and 4 the base's).
git -C "$SRC" checkout -q -b gone2 "$ONE"
g -C "$SRC" commit -q --allow-empty -m gone2
GONE2=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q main
g -C "$SRC" update-ref refs/heads/refs/heads/gone2 "$TWO"
: > "$FAKE_SSH_LOG"
assert_eq "the same for the base" "0|${MAIN}|${GONE2}" \
    "$(resolve_with env "${SSHENV[@]}" FAKE_SSH_HOOK_ON=4 \
        FAKE_SSH_HOOK="git -C '$SRC' update-ref -d refs/heads/gone2" \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main TARGET_REV_BASE=gone2)"
assert_eq "  (it was deleted)" none "$(src_ref refs/heads/gone2)"
assert_eq "  (four calls)" 4 "$(calls)"
drop_prep
g -C "$SRC" update-ref -d refs/heads/refs/heads/gone
g -C "$SRC" update-ref -d refs/heads/refs/heads/gone2

# The engagement lock's descriptor reaches no Git command (the
# core.sshCommand probe included) and no helper.
: > "$FAKE_SSH_LOG"
: > "$TMPDIR/git.log"
exec 8> "$TMPDIR/lockfile"
# shellcheck disable=SC2046
assert_eq "with the lock on descriptor 8" "0|${MAIN}|${MAIN}" \
    "$(resolve_with env $(userenv sshcmd) GIT_SSH_VARIANT=ssh \
        SWARM_LOCK_FD=8 PATH="$TMPDIR/gitshim:$PATH" \
        TARGET_REPO="fakehost:$SRC" TARGET_REV=main TARGET_REV_BASE=main)"
exec 8>&-
GITLOG=$(cat "$TMPDIR/git.log")
assert_contains "  (the shim saw the network commands)" "ls-remote" "$GITLOG"
assert_contains "  (the core.sshCommand probe)" \
    "config --get core.sshCommand" "$GITLOG"
assert_contains "  (and the local ones)" "fsck" "$GITLOG"
assert_lacks "  no Git command had the descriptor" "fd8=open" "$GITLOG"
assert_lacks "  nor SWARM_LOCK_FD" "lock=8" "$GITLOG"
assert_eq "  (the fake ssh ran)" 2 "$(calls)"
assert_lacks "  no helper had the descriptor" "fd8=open" \
    "$(cat "$FAKE_SSH_LOG")"
assert_lacks "  nor SWARM_LOCK_FD" "lock=8" "$(cat "$FAKE_SSH_LOG")"
drop_prep

# A Git whose rev-parse prints an id of the other format's length.
mkdir -p "$TMPDIR/longshim"
cat > "$TMPDIR/longshim/git" <<EOF
#!/bin/bash
case " \$* " in
    *" rev-parse --verify --quiet "*)
        out=\$("$REAL_GIT" "\$@") || exit \$?
        printf '%s000000000000000000000000\n' "\$out"
        exit 0 ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPDIR/longshim/git"
refused "a commit id of the wrong length" \
    "reading TARGET_REV's commit gave no sha1 id" \
    PATH="$TMPDIR/longshim:$PATH" TARGET_REPO="$SRC" TARGET_REV=main

# Timeouts: the alarm ends the Git process; the fake ssh (or the slow
# upload-pack below), a helper, lives on.  Its pids are the last line of
# $PIDS.
helper_alive() {
    local pid
    pid=$(tail -n 1 "$PIDS" | cut -d' ' -f1)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo yes
    else
        echo no
    fi
}
stop_helper() {
    local helper sleeper
    read -r helper sleeper < <(tail -n 1 "$PIDS")
    kill "$helper" "$sleeper" 2>/dev/null || true
}
timed_out() {
    local label="$1" msg="$2" out start
    shift 2
    : > "$FAKE_SSH_LOG"
    start=$SECONDS
    out=$(resolve_with "$@")
    assert_eq "${label} ends" 1 "${out%%|*}"
    assert_eq "  within the bound" yes \
        "$([ $((SECONDS - start)) -lt 6 ] && echo yes || echo no)"
    assert_contains "  saying so" "$msg" "$(err)"
    assert_eq "  and leaves nothing" "" "$(left)"
    assert_eq "  while the helper lives on" yes "$(helper_alive)"
    stop_helper
}
ignore_alrm() {
    trap '' ALRM
    "$@"
}
block_alrm() {
    perl -MPOSIX -e 'sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGALRM))
        or die "sigprocmask: $!"; exec { $ARGV[0] } @ARGV or die "exec: $!"' \
        "$@"
}
# What a child of the driver's Bash inherits.
SIGPROBE='perl -MPOSIX -e "my \$s = POSIX::SigSet->new;
    sigprocmask(SIG_BLOCK, undef, \$s);
    print((\$SIG{ALRM} // q(default)), q( ),
        (\$s->ismember(SIGALRM) ? q(blocked) : q(free)))"'
assert_eq "(ignore_alrm reaches the driver's children)" "IGNORE free" \
    "$(ignore_alrm "$BASH" -c "$SIGPROBE")"
assert_eq "(block_alrm too)" "default blocked" \
    "$(block_alrm "$BASH" -c "$SIGPROBE")"
assert_eq "(and both)" "IGNORE blocked" \
    "$(ignore_alrm block_alrm "$BASH" -c "$SIGPROBE")"

STALL=(env "${SSHENV[@]}" SWARM_TARGET_TIMEOUT=2 TARGET_REPO="fakehost:$SRC"
    TARGET_REV=main)
LS_MSG="listing the refs of TARGET_REV's repository took longer than 2 seconds"
FETCH_MSG="fetching TARGET_REV (refs/heads/main at ${MAIN})"
FETCH_MSG="${FETCH_MSG} took longer than 2 seconds"
timed_out "a stalled ls-remote" "$LS_MSG" "${STALL[@]}" FAKE_SSH_SLEEP_ON=1
timed_out "a stalled fetch" "$FETCH_MSG" "${STALL[@]}" FAKE_SSH_SLEEP_ON=2
timed_out "with SIGALRM ignored by the caller, a stalled ls-remote" \
    "$LS_MSG" ignore_alrm "${STALL[@]}" FAKE_SSH_SLEEP_ON=1
timed_out "with SIGALRM blocked by the caller, a stalled ls-remote" \
    "$LS_MSG" block_alrm "${STALL[@]}" FAKE_SSH_SLEEP_ON=1
timed_out "with SIGALRM ignored and blocked, a stalled ls-remote" \
    "$LS_MSG" ignore_alrm block_alrm "${STALL[@]}" FAKE_SSH_SLEEP_ON=1
timed_out "with SIGALRM ignored and blocked, a stalled fetch" \
    "$FETCH_MSG" ignore_alrm block_alrm "${STALL[@]}" FAKE_SSH_SLEEP_ON=2
# shellcheck disable=SC2046
timed_out "with fetch.writeCommitGraph in the user's configuration" \
    "$FETCH_MSG" "${STALL[@]}" $(userenv graph) FAKE_SSH_SLEEP_ON=2

# A local copy that stalls: an exec path whose upload-pack serves the
# source at once but stalls on the network scratch.
REAL_EXEC=$(git --exec-path)
SLOW="$TMPDIR/slow-exec"
mkdir -p "$SLOW"
for f in "$REAL_EXEC"/*; do
    ln -s "$f" "$SLOW/${f##*/}"
done
rm "$SLOW/git-upload-pack"
cat > "$SLOW/git-upload-pack" <<EOF
#!/bin/bash
case "\$*" in
    *.target-fetch.*)
        sleep 8 &
        echo "\$\$ \$!" >> "$PIDS"
        wait "\$!" || true ;;
esac
exec "$REAL_EXEC/git-upload-pack" "\$@"
EOF
chmod +x "$SLOW/git-upload-pack"
timed_out "a stalled local copy" \
    "copying the target into its snapshot took longer than 2 seconds" \
    env GIT_EXEC_PATH="$SLOW" SWARM_TARGET_VERIFY_TIMEOUT=2 \
    TARGET_REPO="$SRC" TARGET_REV=main
assert_eq "an immediate retry succeeds" "0|${MAIN}|" \
    "$(TARGET_REPO="$SRC" TARGET_REV=main resolve)"
assert_eq "  in new directories" ".target-prep.*" "$(left)"
drop_prep

echo ""
echo "=== 5. Sealing a snapshot ==="
# What swarm_target_resolve sets before it seals; read by the library.
SWARM_TARGET_TMP="$TMPDIR/seal-tmp"
mkdir -p "$SWARM_TARGET_TMP"
# shellcheck disable=SC2034
SWARM_TARGET_LOCAL_SECS=60
# shellcheck disable=SC2034
SWARM_TARGET_COMMIT="$MAIN"
# shellcheck disable=SC2034
SWARM_TARGET_BASE_COMMIT=""
# A bare repository as a local fetch leaves it, loose objects, with
# refs besides the fetched one.
seal_repo() {
    local d="$TMPDIR/seal-$1"
    git init -q --bare "$d"
    git --git-dir="$d" -c fetch.unpackLimit=1000 fetch -q "$SRC" \
        +refs/heads/main:refs/swarm/fetch/target \
        +refs/heads/feature:refs/heads/feature \
        +refs/tags/annotated:refs/tags/annotated
    printf '%s' "$d"
}
seal() {
    local rc=0
    _swarm_target_seal "$1" 2> "$TMPDIR/seal-err" || rc=$?
    printf '%s' "$rc"
}
seal_refs() {
    git --git-dir="$1" for-each-ref --format='%(refname) %(objectname)' \
        | tr '\n' ';' | sed 's/;$//'
}
D=$(seal_repo clean)
assert_eq "a repository seals" 0 "$(seal "$D")"
assert_eq "  leaving only the pin" "refs/swarm/target ${MAIN}" \
    "$(seal_refs "$D")"
D=$(seal_repo base)
assert_eq "with a base" 0 "$(SWARM_TARGET_BASE_COMMIT="$ONE" seal "$D")"
assert_eq "  both pins stay" \
    "refs/swarm/target ${MAIN};refs/swarm/target-base ${ONE}" \
    "$(seal_refs "$D")"
D=$(seal_repo nobase)
git --git-dir="$D" update-ref refs/swarm/target-base "$ONE"
assert_eq "without a base" 0 "$(seal "$D")"
assert_eq "  a stray base pin goes" "refs/swarm/target ${MAIN}" \
    "$(seal_refs "$D")"
D=$(seal_repo traces)
mkdir -p "$D/logs/refs"
echo x > "$D/FETCH_HEAD"
echo x > "$D/ORIG_HEAD"
assert_eq "fetch traces" 0 "$(seal "$D")"
assert_eq "  are deleted" "no no no" \
    "$(for f in FETCH_HEAD ORIG_HEAD logs; do
        [ -e "$D/$f" ] && printf 'yes ' || printf 'no '; done | sed 's/ $//')"
for f in shallow commondir objects/info/alternates objects/info/http-alternates
do
    D=$(seal_repo "x-${f##*/}")
    echo "$TMPDIR/elsewhere" > "$D/$f"
    assert_eq "${f} refuses" 1 "$(seal "$D")"
    assert_contains "  saying so" "the target's snapshot has ${f}; refused" \
        "$(cat "$TMPDIR/seal-err")"
done
D=$(seal_repo promisor)
: > "$D/objects/pack/.hidden.promisor"
assert_eq "a promisor pack refuses" 1 "$(seal "$D")"
assert_contains "  saying so" "promisor pack" "$(cat "$TMPDIR/seal-err")"
D=$(seal_repo remote)
git --git-dir="$D" config remote.origin.url "$SRC"
assert_eq "a remote refuses" 1 "$(seal "$D")"
assert_contains "  saying so" "a remote or a partial clone setting" \
    "$(cat "$TMPDIR/seal-err")"
D=$(seal_repo partial)
git --git-dir="$D" config extensions.partialClone origin
assert_eq "a partial clone setting refuses" 1 "$(seal "$D")"
D=$(seal_repo broken)
rm -f "$D/objects/${ONE:0:2}/${ONE:2}"
assert_eq "a missing object refuses" 1 "$(seal "$D")"
assert_contains "  through git fsck" \
    "checking the snapshot (git fsck) failed" \
    "$(cat "$TMPDIR/seal-err")"

echo ""
echo "=== 6. Scratch left by earlier runs ==="
SC="$TMPDIR/scratch-rt"
mkdir -p "$SC/.target-fetch.a/objects/pack" "$SC/.target-prep.b/refs" \
    "$SC/upstream.git" "$SC/target.git" "$SC/.target-other" "$TMPDIR/elsewhere"
: > "$SC/.target-fetch.a/objects/pack/tmp_pack_x"
: > "$TMPDIR/elsewhere/keep"
ln -s "$TMPDIR/elsewhere" "$SC/.target-prep.link"
: > "$SC/.target-fetch.file"
out=$(swarm_target_scratch_clean "$SC" 2>&1)
KEPT=".target-fetch.file .target-other .target-prep.link target.git"
assert_eq "scratch directories are deleted" "${KEPT} upstream.git" \
    "$(names_in "$SC")"
assert_contains "a symlink is left alone" \
    "$SC/.target-prep.link is not a directory; left alone" "$out"
assert_eq "  and what it points to stays" yes \
    "$([ -e "$TMPDIR/elsewhere/keep" ] && echo yes || echo no)"
assert_contains "a file is left alone" \
    "$SC/.target-fetch.file is not a directory; left alone" "$out"
assert_eq "everything else stays" yes \
    "$([ -d "$SC/upstream.git" ] && [ -d "$SC/target.git" ] \
        && [ -d "$SC/.target-other" ] && echo yes || echo no)"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$SC/.target-fetch.stuck/objects"
    : > "$SC/.target-fetch.stuck/objects/x"
    chmod 555 "$SC/.target-fetch.stuck/objects"
    out=$(swarm_target_scratch_clean "$SC" 2>&1)
    assert_contains "one that cannot be deleted is named" \
        "cannot delete $SC/.target-fetch.stuck yet" "$out"
    chmod 755 "$SC/.target-fetch.stuck/objects"
    swarm_target_scratch_clean "$SC" 2>/dev/null
    assert_eq "  and a later run deletes it" no \
        "$([ -e "$SC/.target-fetch.stuck" ] && echo yes || echo no)"
fi
mkdir -p "$TMPDIR/empty-rt"
assert_eq "nothing to clean is quiet" "" \
    "$(swarm_target_scratch_clean "$TMPDIR/empty-rt" 2>&1)"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
