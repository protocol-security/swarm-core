#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/target-checkout.sh (swarm-target-checkout, in the
# image): a checkout of the engagement's target from its snapshot, run
# here against snapshots made by lib/target.sh's resolver (no Docker).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
TMPDIR=$(cd -P "$TMPDIR" && pwd -P)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/lib/target-checkout.sh"
REAL_GIT=$(command -v git)
cleanup() {
    chmod -R u+rwx "$TMPDIR" 2>/dev/null || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT
umask 022

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"
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

g() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        -c tag.gpgsign=false "$@"
}

# Resolve TARGET_* (given as VAR=VALUE arguments) with lib/target.sh in
# its own Bash, for a checkout of format FORMAT (default sha1), and move
# the snapshot to $TMPDIR/snap-NAME.  Prints the snapshot's path.
SNAPRT="$TMPDIR/snaprt"
mkdir -p "$SNAPRT"
snapshot() {
    local name="$1" format="$2" prep
    shift 2
    prep=$(env "$@" "$BASH" -c '
        set -euo pipefail
        source "$1/lib/project.sh"
        source "$1/lib/target.sh"
        swarm_target_inputs_check
        swarm_target_resolve "$2" "$3"
        printf "%s\n" "$SWARM_TARGET_PREP"' _ "$REPO_ROOT" "$SNAPRT" \
        "$format")
    mv "$prep" "$TMPDIR/snap-$name"
    printf '%s' "$TMPDIR/snap-$name"
}

# The target: main (two commits) and base (the first); two files under
# filter attributes, an LFS pointer, and a submodule.
SRC="$TMPDIR/src"
SUB="$TMPDIR/sub"
git init -q -b main "$SUB"
echo sub > "$SUB/s"
g -C "$SUB" add s
g -C "$SUB" commit -q -m sub
git init -q -b main "$SRC"
echo one > "$SRC/f"
echo g > "$SRC/g"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 4\n' \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    > "$SRC/p.bin"
printf '%s\n' 'f filter=evil' 'g filter=proc' \
    'p.bin filter=lfs diff=lfs merge=lfs -text' > "$SRC/.gitattributes"
g -C "$SRC" add f g p.bin .gitattributes
g -C "$SRC" -c protocol.file.allow=always submodule add -q "$SUB" sub \
    > /dev/null 2>&1
g -C "$SRC" commit -q -m one
BASEC=$(git -C "$SRC" rev-parse HEAD)
g -C "$SRC" branch base
echo two > "$SRC/f"
g -C "$SRC" commit -q -am two
MAIN=$(git -C "$SRC" rev-parse HEAD)
S1=$(snapshot base sha1 TARGET_REPO="$SRC" TARGET_REV=main \
    TARGET_REV_BASE=base)
S1N=$(snapshot nobase sha1 TARGET_REPO="$SRC" TARGET_REV=main)
SRC256="$TMPDIR/src256"
git init -q -b main --object-format=sha256 "$SRC256"
echo x > "$SRC256/f"
g -C "$SRC256" add f
g -C "$SRC256" commit -q -m x
MAIN256=$(git -C "$SRC256" rev-parse HEAD)
S256=$(snapshot s256 sha256 TARGET_REPO="$SRC256" TARGET_REV=main)

# The directory the helper runs in, and its own TMPDIR.
WORK="$TMPDIR/work"
HTMP="$TMPDIR/htmp"
mkdir -p "$WORK" "$HTMP"

# Run the helper from $WORK on mirror M with TARGET_REV REV and
# TARGET_REV_BASE BASE for DIR, the rest of the arguments env's (its
# options first, then assignments); print its status; its output in
# $TMPDIR/out and $TMPDIR/err.
co() {
    local m="$1" rev="$2" base="$3" dir="$4" rc=0
    shift 4
    (cd "$WORK" && env "$@" TMPDIR="$HTMP" SWARM_TARGET_MIRROR="$m" \
        TARGET_REV="$rev" TARGET_REV_BASE="$base" \
        "$BASH" "$HELPER" "$dir") > "$TMPDIR/out" 2> "$TMPDIR/err" || rc=$?
    printf '%s' "$rc"
}
err() { cat "$TMPDIR/err"; }
# What is in $WORK (hidden names too), one name per line, sorted.
work_names() {
    (cd "$WORK" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' \
        | LC_ALL=C sort)
}
# Nothing of the helper's own is left: no build directory beside any
# destination the tests use, an empty TMPDIR.
leftovers() {
    (find "$WORK" "$TMPDIR/real" -name '.swarm-target-checkout.*' \
        2>/dev/null; ls -A "$HTMP") | tr '\n' ' '
}
refs_of() {
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' \
        | tr '\n' ';'
}

echo "=== 1. Checkouts ==="
assert_eq "a checkout with a base" 0 "$(co "$S1" "$MAIN" "$BASEC" co1)"
assert_eq "  HEAD at TARGET_REV" "$MAIN" "$(git -C "$WORK/co1" rev-parse HEAD)"
assert_eq "  detached" "" \
    "$(git -C "$WORK/co1" symbolic-ref -q HEAD || true)"
assert_eq "  the pins as fetched" \
    "refs/swarm/target ${MAIN};refs/swarm/target-base ${BASEC};" \
    "$(refs_of "$WORK/co1")"
assert_eq "  the target's files" two "$(cat "$WORK/co1/f")"
assert_eq "  nothing changed in the work tree" "" \
    "$(git -C "$WORK/co1" status --porcelain --ignore-submodules=none)"
assert_contains "  it says so" "Checked out ${MAIN} at ${WORK}/co1." \
    "$(cat "$TMPDIR/out")"
assert_contains "  and names the base" "Its base is ${BASEC}" \
    "$(cat "$TMPDIR/out")"
INIT_KEYS='core\.(repositoryformatversion|filemode|bare|logallrefupdates'
INIT_KEYS="${INIT_KEYS}|ignorecase|precomposeunicode|symlinks)"
assert_eq "  its config holds what git init writes, no more" "" \
    "$(git -C "$WORK/co1" config --local --name-only --list \
        | grep -vxE "$INIT_KEYS" || true)"
assert_eq "  the submodule is not fetched" "" "$(ls -A "$WORK/co1/sub")"
assert_contains "  the LFS pointer stays a pointer" \
    "version https://git-lfs.github.com/spec/v1" "$(cat "$WORK/co1/p.bin")"
assert_eq "  the mode follows the umask" 755 \
    "$(stat -c %a "$WORK/co1" 2>/dev/null || stat -f %Lp "$WORK/co1")"
assert_eq "  nothing of the helper's left" "" "$(leftovers)"
assert_eq "a second run refuses" 1 "$(co "$S1" "$MAIN" "$BASEC" co1)"
assert_contains "  saying so" "${WORK}/co1 is not empty." "$(err)"
assert_eq "without a base" 0 "$(co "$S1N" "$MAIN" "" co2)"
assert_eq "  only the target's pin" "refs/swarm/target ${MAIN};" \
    "$(refs_of "$WORK/co2")"
assert_eq "SHA-256" 0 "$(co "$S256" "$MAIN256" "" co3)"
assert_eq "  HEAD at TARGET_REV" "$MAIN256" \
    "$(git -C "$WORK/co3" rev-parse HEAD)"
assert_eq "  a SHA-256 repository" sha256 \
    "$(git -C "$WORK/co3" rev-parse --show-object-format)"
mkdir "$WORK/empty"
assert_eq "into an empty directory" 0 "$(co "$S1" "$MAIN" "" empty)"
assert_eq "  checked out" "$MAIN" "$(git -C "$WORK/empty" rev-parse HEAD)"
assert_eq "an absolute DIR" 0 "$(co "$S1" "$MAIN" "" "$WORK/abs")"
assert_eq "  checked out" "$MAIN" "$(git -C "$WORK/abs" rev-parse HEAD)"
(umask 027 && co "$S1" "$MAIN" "" co027 > /dev/null)
assert_eq "a umask of 027 gives 750" 750 \
    "$(stat -c %a "$WORK/co027" 2>/dev/null || stat -f %Lp "$WORK/co027")"
# Names a shell or cd could read as something else.
for n in -x "a b" "q'q" --init; do
    before=$(work_names)
    assert_eq "a name such as $(printf '%q' "$n")" 0 \
        "$(co "$S1" "$MAIN" "" "$n")"
    assert_eq "  checked out there" "$MAIN" \
        "$(git -C "$WORK/$n" rev-parse HEAD)"
    assert_eq "  nothing else in the directory changed" \
        "$(printf '%s\n%s' "$before" "$n" | LC_ALL=C sort)" "$(work_names)"
done
mkdir "$WORK/-" "$WORK/--bare"
mkdir "$TMPDIR/oldpwd"
assert_eq "a parent named -" 0 \
    "$(co "$S1" "$MAIN" "" -/checkout OLDPWD="$TMPDIR/oldpwd")"
assert_eq "  checked out under it" "$MAIN" \
    "$(git -C "$WORK/-/checkout" rev-parse HEAD)"
assert_eq "  not where OLDPWD points" "" "$(ls -A "$TMPDIR/oldpwd")"
assert_eq "a parent named --bare" 0 "$(co "$S1" "$MAIN" "" --bare/checkout)"
assert_eq "  checked out under it" "$MAIN" \
    "$(git -C "$WORK/--bare/checkout" rev-parse HEAD)"
mkdir "$TMPDIR/real"
ln -s "$TMPDIR/real" "$WORK/lnk"
assert_eq "below a link to a directory (links above DIR are followed)" 0 \
    "$(co "$S1" "$MAIN" "" lnk/co)"
assert_eq "  checked out where it leads" "$MAIN" \
    "$(git -C "$TMPDIR/real/co" rev-parse HEAD)"
assert_eq "  nothing of the helper's left" "" "$(leftovers)"

echo ""
echo "=== 2. Destinations refused ==="
# Each leaves the destination as it was and nothing of the helper's.
dest_refused() {   # LABEL NEEDLE DIR [BEFORE]
    local label="$1" needle="$2" dir="$3" before
    before=$(work_names)
    assert_eq "$label refuses" 1 "$(co "$S1" "$MAIN" "" "$dir")"
    assert_contains "  saying so" "$needle" "$(err)"
    assert_eq "  the directory unchanged" "$before" "$(work_names)"
    assert_eq "  nothing of the helper's left" "" "$(leftovers)"
}
echo x > "$WORK/afile"
dest_refused "a file" "${WORK}/afile is there and is not a directory" afile
mkdir "$WORK/full"
echo x > "$WORK/full/x"
dest_refused "a directory that is not empty" "${WORK}/full is not empty" full
mkdir "$WORK/hidden"
echo x > "$WORK/hidden/.x"
dest_refused "a directory holding a hidden file" "is not empty" hidden
# One its owner cannot list (not as root, who can).
if [ "$(id -u)" != 0 ]; then
    mkdir "$WORK/unlisted"
    echo x > "$WORK/unlisted/x"
    chmod 300 "$WORK/unlisted"
    dest_refused "a directory it cannot list" "cannot list ${WORK}/unlisted" \
        unlisted
    chmod 755 "$WORK/unlisted"
fi
mkdir "$TMPDIR/target-of-link"
ln -s "$TMPDIR/target-of-link" "$WORK/elink"
dest_refused "a link to an empty directory" "${WORK}/elink is a link" elink
dest_refused "  spelled with a slash" "${WORK}/elink is a link" elink/
dest_refused "  spelled with /." "DIR must end in a name" elink/.
assert_eq "  nothing was written where it leads" "" \
    "$(ls -A "$TMPDIR/target-of-link")"
ln -s "$TMPDIR/nowhere" "$WORK/dangling"
dest_refused "a dangling link" "${WORK}/dangling is a link" dangling
dest_refused "a missing parent" "the directory DIR is in does not exist" \
    missing/co
dest_refused "the name ." "DIR must end in a name" .
dest_refused "the name .." "DIR must end in a name" ..
dest_refused "a path ending in .." "DIR must end in a name" full/..
assert_eq "/ refuses" 1 "$(co "$S1" "$MAIN" "" /)"
assert_contains "  saying so" "DIR must end in a name" "$(err)"
assert_eq "no DIR refuses" 1 "$(co "$S1" "$MAIN" "" "")"
assert_contains "  saying so" "usage: swarm-target-checkout DIR" "$(err)"

echo ""
echo "=== 3. Inputs refused ==="
in_refused() {   # LABEL NEEDLE MIRROR REV BASE [VAR=VALUE...]
    local label="$1" needle="$2"
    shift 2
    assert_eq "$label refuses" 1 "$(co "$@" bad)"
    assert_contains "  saying so" "$needle" "$(err)"
    assert_eq "  no checkout" no \
        "$([ -e "$WORK/bad" ] && echo yes || echo no)"
}
in_refused "an empty SWARM_TARGET_MIRROR" "this engagement has no target" \
    "" "$MAIN" ""
assert_eq "an unset SWARM_TARGET_MIRROR refuses" 1 \
    "$( (cd "$WORK" && env -u SWARM_TARGET_MIRROR TMPDIR="$HTMP" \
        TARGET_REV="$MAIN" "$BASH" "$HELPER" bad) > /dev/null 2>&1; echo $?)"
in_refused "a relative SWARM_TARGET_MIRROR" "is not an absolute path" \
    snap-base "$MAIN" ""
mkdir "$TMPDIR/sp ace"
in_refused "a SWARM_TARGET_MIRROR with a space" \
    "holds a character other than" "$TMPDIR/sp ace" "$MAIN" ""
in_refused "an empty TARGET_REV" "TARGET_REV is not a full commit id" \
    "$S1" "" ""
in_refused "an abbreviated TARGET_REV" "TARGET_REV is not a full commit id" \
    "$S1" "${MAIN:0:12}" ""
UPPER=$(printf '%s' "$MAIN" | tr 'abcdef' 'ABCDEF')
in_refused "an uppercase TARGET_REV" "TARGET_REV is not a full commit id" \
    "$S1" "$UPPER" ""
in_refused "a TARGET_REV of the other format's length" \
    "the snapshot's ids are sha1 (40 digits)" "$S1" "${MAIN}${MAIN:0:24}" ""
in_refused "a bad TARGET_REV_BASE" "TARGET_REV_BASE is not a full commit id" \
    "$S1" "$MAIN" "nope"
in_refused "TARGET_REV_BASE with no base pin" \
    "cannot fetch the target's pins" "$S1N" "$MAIN" "$BASEC"
in_refused "a base pin at another commit" \
    "refs/swarm/target-base is ${BASEC} in the snapshot, not ${MAIN}" \
    "$S1" "$MAIN" "$MAIN"
in_refused "a target pin at another commit" \
    "refs/swarm/target is ${MAIN} in the snapshot, not ${BASEC}" \
    "$S1" "$BASEC" ""
assert_eq "  nothing of the helper's left" "" "$(leftovers)"
# Pins that are annotated tags of the commit, in copies of the snapshot.
tagged_copy() {   # NAME REF COMMIT: prints the tag object's id.
    local c="$TMPDIR/snap-$1" t
    cp -Rp "$S1" "$c"
    chmod -R u+w "$c"
    t=$(g --git-dir="$c" tag -a -m tag "tag-$1" "$3" \
        && git --git-dir="$c" rev-parse "refs/tags/tag-$1")
    git --git-dir="$c" update-ref "$2" "$t"
    git --git-dir="$c" update-ref -d "refs/tags/tag-$1"
    printf '%s' "$t"
}
TT=$(tagged_copy ttag refs/swarm/target "$MAIN")
in_refused "a target pin that is a tag of TARGET_REV" \
    "refs/swarm/target is ${TT} in the snapshot, not ${MAIN}" \
    "$TMPDIR/snap-ttag" "$MAIN" ""
in_refused "  and with TARGET_REV the tag's own id" \
    "refs/swarm/target does not point to a commit" \
    "$TMPDIR/snap-ttag" "$TT" ""
BT=$(tagged_copy btag refs/swarm/target-base "$BASEC")
in_refused "a base pin that is a tag of TARGET_REV_BASE" \
    "refs/swarm/target-base is ${BT} in the snapshot, not ${BASEC}" \
    "$TMPDIR/snap-btag" "$MAIN" "$BASEC"
in_refused "  and with TARGET_REV_BASE the tag's own id" \
    "refs/swarm/target-base does not point to a commit" \
    "$TMPDIR/snap-btag" "$MAIN" "$BT"

echo ""
echo "=== 4. Failures, and DIR changed meanwhile ==="
# A git first on PATH that fails the command named by FAIL_ON, or, on
# the checkout, puts something at SUBST_D (SUBST: link or full).
mkdir -p "$TMPDIR/fbin"
cat > "$TMPDIR/fbin/git" <<EOF
#!/bin/bash
case " \$* " in
    *" \${FAIL_ON:-NONE} "*) exit 1 ;;
esac
case "\${SUBST:-}:\$*" in
    link:*" checkout "*) ln -s "$TMPDIR/subst-target" "\$SUBST_D" ;;
    full:*" checkout "*) mkdir "\$SUBST_D" && echo x > "\$SUBST_D/x" ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPDIR/fbin/git"
mkdir "$TMPDIR/subst-target"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
for step in "init -q" fetch --verify cat-file checkout; do
    assert_eq "a failing ${step%% *}: the helper fails" 1 \
        "$(co "$S1" "$MAIN" "" failed PATH="$TMPDIR/fbin:$PATH" \
            FAIL_ON="$step")"
    assert_eq "  no success line" "" "$(cat "$TMPDIR/out")"
    assert_eq "  no checkout" no \
        "$([ -e "$WORK/failed" ] && echo yes || echo no)"
    assert_eq "  nothing of the helper's left" "" "$(leftovers)"
    # The same into an empty directory of the caller's, mode 750.
    mkdir -m 750 "$WORK/kept"
    assert_eq "  into an empty directory, it fails too" 1 \
        "$(co "$S1" "$MAIN" "" kept PATH="$TMPDIR/fbin:$PATH" \
            FAIL_ON="$step")"
    assert_eq "  that directory stays, empty, mode 750" "yes  750" \
        "$([ -d "$WORK/kept" ] && echo yes || echo no) $(ls -A "$WORK/kept") $(
            mode_of "$WORK/kept")"
    rmdir "$WORK/kept"
done
assert_eq "DIR made a link meanwhile: refused" 1 \
    "$(co "$S1" "$MAIN" "" subst1 PATH="$TMPDIR/fbin:$PATH" SUBST=link \
        SUBST_D="$WORK/subst1")"
assert_contains "  saying so" "cannot put the checkout at ${WORK}/subst1" \
    "$(err)"
assert_eq "  nothing written where the link leads" "" \
    "$(ls -A "$TMPDIR/subst-target")"
assert_eq "  nothing of the helper's left" "" "$(leftovers)"
assert_eq "DIR made a full directory meanwhile: refused" 1 \
    "$(co "$S1" "$MAIN" "" subst2 PATH="$TMPDIR/fbin:$PATH" SUBST=full \
        SUBST_D="$WORK/subst2")"
assert_eq "  that directory as it was made" x "$(ls -A "$WORK/subst2")"
assert_eq "  nothing of the helper's left" "" "$(leftovers)"
# A run cut short by an unset variable right before the rename (Bash
# 3.2 would end it with status 0 but for the helper's guard).
GUARDED="$TMPDIR/guarded.sh"
assert_eq "(the helper has one publish mark)" 1 \
    "$(grep -cx '# publish' "$HELPER")"
sed 's/^# publish$/: "$swarm_checkout_never_set"/' "$HELPER" > "$GUARDED"
assert_eq "a run stopped by set -u fails" 1 \
    "$( (cd "$WORK" && env -u swarm_checkout_never_set TMPDIR="$HTMP" \
        SWARM_TARGET_MIRROR="$S1" TARGET_REV="$MAIN" TARGET_REV_BASE= \
        "$BASH" "$GUARDED" stopped) > "$TMPDIR/out" 2> "$TMPDIR/err"; \
        echo $?)"
assert_eq "  no success line" "" "$(cat "$TMPDIR/out")"
assert_eq "  no checkout" no \
    "$([ -e "$WORK/stopped" ] && echo yes || echo no)"
assert_eq "  nothing of the helper's left" "" "$(leftovers)"

echo ""
echo "=== 5. The caller's Git settings stay out ==="
MARK="$TMPDIR/marks"
mkdir -p "$MARK" "$TMPDIR/hooks"
printf '#!/bin/sh\necho hook >> "%s/hook"\n' "$MARK" \
    > "$TMPDIR/hooks/post-checkout"
chmod +x "$TMPDIR/hooks/post-checkout"
# A hook, a smudge filter, a rewrite of the snapshot's path and the
# file protocol forbidden; a process filter in a file of its own (it
# fails, and a failed filter would stop a checkout before its hook).
# Values with ";" are quoted: a config file reads ";" as a comment.
cat > "$TMPDIR/evil.gitconfig" <<EOF
[core]
    hooksPath = $TMPDIR/hooks
[filter "evil"]
    smudge = "sh -c 'echo smudge >> $MARK/smudge; cat'"
[url "$TMPDIR/elsewhere"]
    insteadOf = $S1
[protocol "file"]
    allow = never
EOF
cat > "$TMPDIR/evilproc.gitconfig" <<EOF
[filter "proc"]
    process = "sh -c 'echo process >> $MARK/process; exit 1'"
EOF
marks() {
    (cd "$MARK" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' \
        | LC_ALL=C sort | tr '\n' ' ')
}
clear_marks() { find "$MARK" -mindepth 1 -delete; }
# Plain git with those settings (env's options, then assignments),
# cloning the target from its source: its checkout runs the hook and a
# filter.
plain_checkout() {
    local d="$TMPDIR/plain-$1"
    shift
    rm -rf "$d"
    env "$@" git -c protocol.file.allow=always clone -q "$SRC" "$d" \
        > /dev/null 2>&1 || true
}
# Through HOME and XDG_CONFIG_HOME, on every Git (the runner's
# GIT_CONFIG_GLOBAL=/dev/null unset, or it would hide both).
mkdir -p "$TMPDIR/evilhome/git" "$TMPDIR/evilxdg/git"
cp "$TMPDIR/evil.gitconfig" "$TMPDIR/evilhome/.gitconfig"
cp "$TMPDIR/evilproc.gitconfig" "$TMPDIR/evilxdg/git/config"
clear_marks
plain_checkout home -u GIT_CONFIG_GLOBAL HOME="$TMPDIR/evilhome" \
    XDG_CONFIG_HOME="$TMPDIR/nowhere"
assert_eq "(plain git reads a hostile ~/.gitconfig: hook and smudge run)" \
    "hook smudge " "$(marks)"
clear_marks
plain_checkout xdg -u GIT_CONFIG_GLOBAL HOME="$TMPDIR/nowhere" \
    XDG_CONFIG_HOME="$TMPDIR/evilxdg"
assert_eq "(and a hostile XDG config: the process filter runs)" \
    "process " "$(marks)"
cp "$TMPDIR/evilproc.gitconfig" "$TMPDIR/evilhome/git/config"
clear_marks
assert_eq "a hostile HOME: the checkout works" 0 \
    "$(co "$S1" "$MAIN" "" e-home -u GIT_CONFIG_GLOBAL \
        HOME="$TMPDIR/evilhome" XDG_CONFIG_HOME="$TMPDIR/evilhome")"
assert_eq "  no hook, filter or process ran" "" "$(marks)"
assert_eq "  at TARGET_REV" "$MAIN" "$(git -C "$WORK/e-home" rev-parse HEAD)"
# Through GIT_CONFIG_GLOBAL, where Git has it (2.32 and later).
if [ "$(GIT_CONFIG_GLOBAL="$TMPDIR/evil.gitconfig" git config --global \
        --get core.hooksPath 2>/dev/null || true)" = "$TMPDIR/hooks" ]; then
    clear_marks
    plain_checkout global GIT_CONFIG_GLOBAL="$TMPDIR/evil.gitconfig"
    assert_eq "(plain git reads GIT_CONFIG_GLOBAL: hook and smudge run)" \
        "hook smudge " "$(marks)"
    clear_marks
    assert_eq "a hostile GIT_CONFIG_GLOBAL: the checkout works" 0 \
        "$(co "$S1" "$MAIN" "" e-global \
            GIT_CONFIG_GLOBAL="$TMPDIR/evil.gitconfig")"
    assert_eq "  no hook, filter or process ran" "" "$(marks)"
fi
# Through GIT_CONFIG_PARAMETERS, and GIT_CONFIG_COUNT where Git has it
# (2.31 and later): a hook and a smudge filter (the helper sets the
# hooks path itself, never a filter, so the filter shows a leak).
printf '#!/bin/sh\necho smudge >> "%s/smudge"\ncat\n' "$MARK" \
    > "$TMPDIR/smudge.sh"
chmod +x "$TMPDIR/smudge.sh"
PARAMS="'core.hookspath=$TMPDIR/hooks' 'filter.evil.smudge=$TMPDIR/smudge.sh'"
clear_marks
plain_checkout params GIT_CONFIG_PARAMETERS="$PARAMS"
assert_eq "(plain git reads GIT_CONFIG_PARAMETERS: hook and smudge run)" \
    "hook smudge " "$(marks)"
clear_marks
assert_eq "GIT_CONFIG_PARAMETERS: the checkout works" 0 \
    "$(co "$S1" "$MAIN" "" e-params GIT_CONFIG_PARAMETERS="$PARAMS")"
assert_eq "  no hook or filter ran" "" "$(marks)"
if [ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=z \
        git config --get x.y 2>/dev/null || true)" = z ]; then
    clear_marks
    plain_checkout count GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0="$TMPDIR/hooks" \
        GIT_CONFIG_KEY_1=filter.evil.smudge \
        GIT_CONFIG_VALUE_1="$TMPDIR/smudge.sh"
    assert_eq "(plain git reads GIT_CONFIG_COUNT: hook and smudge run)" \
        "hook smudge " "$(marks)"
    clear_marks
    assert_eq "GIT_CONFIG_COUNT: the checkout works" 0 \
        "$(co "$S1" "$MAIN" "" e-count GIT_CONFIG_COUNT=2 \
            GIT_CONFIG_KEY_0=core.hooksPath \
            GIT_CONFIG_VALUE_0="$TMPDIR/hooks" \
            GIT_CONFIG_KEY_1=filter.evil.smudge \
            GIT_CONFIG_VALUE_1="$TMPDIR/smudge.sh")"
    assert_eq "  no hook or filter ran" "" "$(marks)"
fi
# GIT_EXEC_PATH: Git puts it first on PATH for the command line
# --upload-pack names, so a git there would run in place of Git's.
mkdir -p "$TMPDIR/execpath"
printf '#!/bin/sh\necho git >> "%s/execpath"\nexec "%s" "$@"\n' "$MARK" \
    "$REAL_GIT" > "$TMPDIR/execpath/git"
chmod +x "$TMPDIR/execpath/git"
clear_marks
rm -rf "$TMPDIR/plain-exec"
git init -q "$TMPDIR/plain-exec"
GIT_EXEC_PATH="$TMPDIR/execpath" git -C "$TMPDIR/plain-exec" fetch -q \
    --upload-pack="git -c safe.directory=$S1 upload-pack" -- "$S1" \
    refs/swarm/target:refs/swarm/target > /dev/null 2>&1 || true
assert_contains "(plain git runs the git GIT_EXEC_PATH holds)" execpath \
    "$(marks)"
clear_marks
assert_eq "GIT_EXEC_PATH: the checkout works" 0 \
    "$(co "$S1" "$MAIN" "" e-exec GIT_EXEC_PATH="$TMPDIR/execpath")"
assert_eq "  that git never ran" "" "$(marks)"
# Repository selectors and the rest: the checkout is made where the
# helper says, and none of the caller's GIT_* reach Git.
git init -q "$TMPDIR/other-repo"
cat > "$TMPDIR/fbin-env" <<EOF
#!/bin/bash
env | grep '^GIT_' | LC_ALL=C sort >> "$MARK/env"
exec "$REAL_GIT" "\$@"
EOF
mkdir -p "$TMPDIR/envbin"
mv "$TMPDIR/fbin-env" "$TMPDIR/envbin/git"
chmod +x "$TMPDIR/envbin/git"
clear_marks
assert_eq "GIT_DIR, GIT_WORK_TREE and others: the checkout works" 0 \
    "$(co "$S1" "$MAIN" "" e-env PATH="$TMPDIR/envbin:$PATH" \
        GIT_DIR="$TMPDIR/other-repo/.git" \
        GIT_WORK_TREE="$TMPDIR/other-repo" \
        GIT_INDEX_FILE="$TMPDIR/other-index" \
        GIT_OBJECT_DIRECTORY="$TMPDIR/odb" GIT_GRAFT_FILE="$TMPDIR/grafts" \
        GIT_NAMESPACE=ns GIT_FOO=bar)"
assert_eq "  checked out where it was asked" "$MAIN" \
    "$(git -C "$WORK/e-env" rev-parse HEAD)"
assert_eq "  the other repository untouched" "" \
    "$(git -C "$TMPDIR/other-repo" for-each-ref)"
OWN="GIT_ALLOW_PROTOCOL GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM"
OWN="$OWN GIT_GRAFT_FILE GIT_NO_REPLACE_OBJECTS GIT_TERMINAL_PROMPT "
assert_eq "  Git saw only the helper's GIT_* variables" "$OWN" \
    "$(sed 's/=.*//' "$MARK/env" | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "  its graft file is not the caller's" "" \
    "$(grep -F "GIT_GRAFT_FILE=$TMPDIR/grafts" "$MARK/env" || true)"
# Fsmonitor: Git 2.30 reads core.fsmonitor as a hook to run, so a
# value of false would run a program called false.
mkdir -p "$TMPDIR/falsebin"
printf '#!/bin/sh\necho false >> "%s/false"\nexit 1\n' "$MARK" \
    > "$TMPDIR/falsebin/false"
chmod +x "$TMPDIR/falsebin/false"
clear_marks
assert_eq "a program called false first on PATH: the checkout works" 0 \
    "$(co "$S1" "$MAIN" "" e-false PATH="$TMPDIR/falsebin:$PATH")"
assert_eq "  it never ran" "" "$(marks)"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
