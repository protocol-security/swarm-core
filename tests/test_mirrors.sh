#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for lib/mirrors.sh (the host's submodule mirrors and their
# manifest) and lib/submodules.sh (the containers' checkout of them),
# with real repositories and no Docker: a workspace cloned here plays
# the container's, and the mirrors directory its /mirrors.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
TMPDIR=$(cd -P "$TMPDIR" && pwd -P)
export TMPDIR
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cleanup() {
    chmod -R u+rwx "$TMPDIR" 2>/dev/null || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT
umask 022

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"
# shellcheck source=../lib/preserve.sh
source "$REPO_ROOT/lib/preserve.sh"
# shellcheck source=../lib/submodules.sh
source "$REPO_ROOT/lib/submodules.sh"
# shellcheck source=../lib/mirrors.sh
source "$REPO_ROOT/lib/mirrors.sh"

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
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        -c tag.gpgsign=false -c protocol.file.allow=always "$@"
}

present() {
    if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi
}

# Run swarm_mirrors_make ROOT DIR BASE [missing] in a subshell, output
# in $TMPDIR/out, status in RC.
make_mirrors() {
    RC=0
    (swarm_mirrors_make "$@") > "$TMPDIR/out" 2>&1 || RC=$?
}

# The manifest's entries, one line each: id|parent|name|path, name and
# path decoded (a newline shown as \n).
entries() {
    local id parent name path
    jq -r '.mirrors[] | [.id, .parent, .name, .path] | map(tostring)
           | join(" ")' "$1/manifest.json" \
    | while read -r id parent name path; do
        name=$(printf '%s' "$name" | base64 -d; printf x)
        path=$(printf '%s' "$path" | base64 -d; printf x)
        name=${name%x} path=${path%x}
        printf '%s|%s|%s|%s\n' "$id" "$parent" "${name//$'\n'/\\n}" \
            "${path//$'\n'/\\n}"
    done
}

# The paths from the checkout the manifest lists, space-separated.
listed() {
    local -a full=()
    local id parent path
    while read -r id parent path; do
        path=$(printf '%s' "$path" | base64 -d; printf x)
        path=${path%x}
        if [ "$parent" -eq 0 ]; then
            full+=("$path")
        else
            full+=("${full[parent - 1]}/${path}")
        fi
    done < <(jq -r '.mirrors[] | [.id, .parent, .path] | map(tostring)
                    | join(" ")' "$1/manifest.json")
    printf '%s' "${full[*]+${full[*]}}"
}

# What a container does: a clone of the checkout at ROOT into WS (as
# from /upstream), then swarm_submodules_init with the mirrors in DIR.
# Messages in $TMPDIR/init.out.
# SWARM_MIRRORS_BASE and SWARM_MIRRORS_COUNT are what swarm passes:
# EXPECT (or BASE), and COUNT (or how many entries the manifest has).
container_init() {
    local root="$1" dir="$2" ws="$3" count
    rm -rf "$ws"
    g clone -q "$root" "$ws"
    ws=$(cd -P "$ws" && pwd -P)
    _log() { printf '%s\n' "$*"; }
    count=$(jq '.mirrors | length' "${dir}/manifest.json" 2>/dev/null) \
        || count=0
    SWARM_MIRRORS_BASE="${EXPECT-$BASE}" \
        SWARM_MIRRORS_COUNT="${COUNT-$count}" \
        swarm_submodules_init "${dir}/manifest.json" "$ws" _log \
        > "$TMPDIR/init.out" 2>&1
}

URLBASE="https://swarm-core-test.invalid"

# leaf <- mid <- top, and leaf <- other <- top, every URL in a
# .gitmodules one the network does not answer: the host's checkouts are
# made from local paths through submodule.<name>.url, so a container can
# only check them out from the mirrors.
S="$TMPDIR/src"
mkdir -p "$S"
g init -q "$S/leaf"
echo leaf > "$S/leaf/leaf.txt"
g -C "$S/leaf" add leaf.txt
g -C "$S/leaf" commit -q -m leaf
LEAF1=$(git -C "$S/leaf" rev-parse HEAD)

# A submodule at PATH (name NAME) of repository REPO from local SRC,
# its .gitmodules URL then made unreachable.
add_sub() {
    local repo="$1" src="$2" path="$3" name="$4"
    g -C "$repo" submodule add -q --name "$name" "$src" "$path" \
        >/dev/null 2>&1
    g -C "$repo" config -f .gitmodules "submodule.${name}.url" \
        "${URLBASE}/${name// /_}.git"
    g -C "$repo" add .gitmodules
}

g init -q "$S/mid"
echo mid > "$S/mid/mid.txt"
g -C "$S/mid" add mid.txt
add_sub "$S/mid" "$S/leaf" "deep/le af" "deep/le af"
g -C "$S/mid" commit -q -m mid
MID1=$(git -C "$S/mid" rev-parse HEAD)

# A fork of mid: it has MID1, and a history of its own after it.
g clone -q "$S/mid" "$S/mid-fork"
g -C "$S/mid-fork" commit -q --allow-empty -m 'fork only'
FORK_ONLY=$(git -C "$S/mid-fork" rev-parse HEAD)

g init -q "$S/other"
echo other > "$S/other/other.txt"
g -C "$S/other" add other.txt
# The same name as mid's, under another superproject.
add_sub "$S/other" "$S/leaf" x "deep/le af"
g -C "$S/other" commit -q -m other

g init -q "$S/top"
echo top > "$S/top/top.txt"
g -C "$S/top" add top.txt
add_sub "$S/top" "$S/mid" lib/mid lib/mid
add_sub "$S/top" "$S/other" vendor/other vendor/other
add_sub "$S/top" "$S/leaf" unused unused
# A gitlink no .gitmodules entry names.
g -C "$S/top" update-index --add --cacheinfo "160000,${LEAF1},orphan"
g -C "$S/top" commit -q -m top

# The host's checkout: every submodule initialized but unused, at any
# depth, from the local repositories.
H="$TMPDIR/host"
g clone -q "$S/top" "$H"
populate() {   # REPO NAME SRC
    g -C "$1" config "submodule.${2}.url" "$3"
    g -C "$1" submodule update --init -q -- \
        "$(git -C "$1" config -f .gitmodules "submodule.${2}.path")"
}
populate "$H" lib/mid "$S/mid"
populate "$H/lib/mid" "deep/le af" "$S/leaf"
populate "$H" vendor/other "$S/other"
populate "$H/vendor/other" "deep/le af" "$S/leaf"
BASE=$(git -C "$H" rev-parse HEAD)

# ============================================================
# ============================================================
echo ""
echo "=== 1. Every initialized submodule, at any depth, parents first ==="

M="$TMPDIR/rt/mirrors"
mkdir -p "$TMPDIR/rt"
make_mirrors "$H" "$M" "$BASE"
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "the manifest lists each, numbered, with its superproject" \
"1|0|lib/mid|lib/mid
2|1|deep/le af|deep/le af
3|0|vendor/other|vendor/other
4|3|deep/le af|x" "$(entries "$M")"
assert_eq "for this engagement's base" "$BASE" \
    "$(jq -r .base "$M/manifest.json")"
assert_eq "with the commits the base records" \
    "$(git -C "$H" rev-parse HEAD:lib/mid) $(git -C "$S/mid" rev-parse "${MID1}:deep/le af")" \
    "$(jq -r '[.mirrors[0].commit, .mirrors[1].commit] | join(" ")' \
        "$M/manifest.json")"
assert_eq "a valid manifest" yes \
    "$(swarm_mirrors_manifest_ok "$M/manifest.json" "$BASE" \
        && echo yes || echo no)"
assert_eq "each mirror is a bare repository" "true true true true" \
    "$(for n in 1 2 3 4; do git -C "$M/$n.git" rev-parse \
        --is-bare-repository; done | tr '\n' ' ' | sed 's/ $//')"
assert_eq "pinning the commit under refs/swarm/gitlink" \
    "$(git -C "$H" rev-parse HEAD:lib/mid)" \
    "$(git -C "$M/1.git" rev-parse -q --verify refs/swarm/gitlink)"
assert_eq "mirrors/ readable by the containers' user" 755 \
    "$(stat -c '%a' "$M" 2>/dev/null || stat -f '%Lp' "$M")"
assert_eq "and the manifest" 644 \
    "$(stat -c '%a' "$M/manifest.json" 2>/dev/null \
        || stat -f '%Lp' "$M/manifest.json")"
assert_eq "an uninitialized submodule is not mirrored, nor an unnamed gitlink" \
    "lib/mid lib/mid/deep/le af vendor/other vendor/other/x" "$(listed "$M")"
assert_eq "nothing else in mirrors/" "1.git 2.git 3.git 4.git manifest.json" \
    "$(ls "$M" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "ready" manifest "$(swarm_mirrors_ready "$H" "$M" "$BASE")"
assert_eq "the preflight on the checkout's HEAD agrees" 0 \
    "$( (swarm_mirrors_preflight "$H") >/dev/null 2>&1; echo $?)"

# ============================================================
echo ""
echo "=== 2. A container checks each out from its mirror ==="

W="$TMPDIR/ws"
container_init "$H" "$M" "$W"
W=$(cd -P "$W" && pwd -P)
assert_eq "both levels checked out" "leaf leaf" \
    "$(cat "$W/lib/mid/deep/le af/leaf.txt" "$W/vendor/other/x/leaf.txt" \
        | tr '\n' ' ' | sed 's/ $//')"
assert_eq "each from its mirror" "$M/2.git" \
    "$(git -C "$W/lib/mid/deep/le af" remote get-url origin)"
assert_eq "the same name under another superproject, from its own" \
    "$M/4.git" "$(git -C "$W/vendor/other/x" remote get-url origin)"
assert_eq "at the commits the checkout records" \
    "$(git -C "$H/lib/mid" rev-parse "HEAD:deep/le af")" \
    "$(git -C "$W/lib/mid/deep/le af" rev-parse HEAD)"
assert_eq "what the manifest does not list stays uninitialized" no \
    "$(present "$W/unused/.git")"
assert_eq "saying how many" "submodules: 4 of 4 checked out from mirrors" \
    "$(tail -1 "$TMPDIR/init.out")"

# A host checkout like H, at DEST.
host_clone() {
    g clone -q "$S/top" "$1"
    populate "$1" lib/mid "$S/mid"
    populate "$1/lib/mid" "deep/le af" "$S/leaf"
    populate "$1" vendor/other "$S/other"
    populate "$1/vendor/other" "deep/le af" "$S/leaf"
}

# ============================================================
echo ""
echo "=== 3. What the base records, not what the host has checked out ==="

# mid moves on, with one more submodule; the host checks lib/mid out
# there and initializes it, but the base still records MID1.
g -C "$S/mid" submodule add -q --name extra "$S/leaf" extra >/dev/null 2>&1
g -C "$S/mid" commit -q -m extra
H3="$TMPDIR/host3"
host_clone "$H3"
g -C "$H3/lib/mid" fetch -q origin
g -C "$H3/lib/mid" checkout -q "$(git -C "$S/mid" rev-parse HEAD)"
populate "$H3/lib/mid" extra "$S/leaf"
assert_eq "the host has lib/mid/extra initialized" yes \
    "$(present "$H3/lib/mid/extra/.git")"
make_mirrors "$H3" "$TMPDIR/rt3/mirrors" "$(git -C "$H3" rev-parse HEAD)"
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "the submodules of the commit the base records, only" \
    "lib/mid lib/mid/deep/le af vendor/other vendor/other/x" \
    "$(listed "$TMPDIR/rt3/mirrors")"
assert_eq "lib/mid's mirror keeps that commit" "$MID1" \
    "$(git -C "$TMPDIR/rt3/mirrors/1.git" rev-parse -q --verify \
        refs/swarm/gitlink)"

# ============================================================
echo ""
echo "=== 4. A linked worktree's submodules ==="

WT="$TMPDIR/host-wt"
g -C "$H" worktree add -q --detach "$WT" "$BASE" 2>/dev/null
populate "$WT" lib/mid "$S/mid"
populate "$WT/lib/mid" "deep/le af" "$S/leaf"
make_mirrors "$WT" "$TMPDIR/rt4/mirrors" "$BASE"
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "the worktree's own: what it initialized, at any depth" \
    "lib/mid lib/mid/deep/le af" "$(listed "$TMPDIR/rt4/mirrors")"
swarm_mirrors_walk "$WT" "$BASE" "$TMPDIR"
HG=$(cd -P "$H/.git" && pwd -P)
assert_eq "from the worktree's git dirs" \
    "$HG/worktrees/host-wt/modules/lib/mid $HG/worktrees/host-wt/modules/lib/mid/modules/deep/le af" \
    "${SWARM_MP_GITDIR[0]} ${SWARM_MP_GITDIR[1]}"
container_init "$WT" "$TMPDIR/rt4/mirrors" "$TMPDIR/ws4"
assert_eq "a container checks both levels out" leaf \
    "$(cat "$TMPDIR/ws4/lib/mid/deep/le af/leaf.txt" 2>/dev/null)"

# ============================================================
echo ""
echo "=== 5. A module is found by its name, where the host has it ==="

# Moved on the host (not committed), and another module at its old path.
MV="$TMPDIR/moved"
host_clone "$MV"
mkdir -p "$MV/moved"
g -C "$MV" mv lib/mid moved/mid
g -C "$MV" submodule add -q --name intruder "$S/other" lib/mid >/dev/null 2>&1
make_mirrors "$MV" "$TMPDIR/rt5/mirrors" "$BASE"
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "lib/mid comes from its own git dir, not the intruder's" no \
    "$(git -C "$TMPDIR/rt5/mirrors/1.git" cat-file -e \
        "$(git -C "$S/other" rev-parse HEAD)^{commit}" 2>/dev/null \
        && echo yes || echo no)"
assert_eq "and what is under it, from where the host has it" \
    "lib/mid lib/mid/deep/le af vendor/other vendor/other/x" \
    "$(listed "$TMPDIR/rt5/mirrors")"
# Removed from the host's .gitmodules, another repository (its own .git
# directory) at its path, named there: not this module.
RP="$TMPDIR/replaced"
host_clone "$RP"
g -C "$RP" submodule deinit -q -f -- vendor/other >/dev/null 2>&1
g -C "$RP" config -f .gitmodules --rename-section submodule.vendor/other \
    submodule.fork
g -C "$RP" clone -q "$S/other" vendor/other-fork
rmdir "$RP/vendor/other"
mv "$RP/vendor/other-fork" "$RP/vendor/other"
make_mirrors "$RP" "$TMPDIR/rt5b/mirrors" "$BASE"
assert_eq "a replacement the host names otherwise is not taken for it" \
    "0 lib/mid lib/mid/deep/le af" "$RC $(listed "$TMPDIR/rt5b/mirrors")"
# A repository at its path that the host's .gitmodules names for nobody.
g -C "$RP" config -f .gitmodules --remove-section submodule.fork
make_mirrors "$RP" "$TMPDIR/rt5c/mirrors" "$BASE"
assert_eq "one nobody names there: refused" 1 "$RC"
assert_eq "saying so" 1 \
    "$(grep -c 'holds a repository the host.s .gitmodules does not give' \
        "$TMPDIR/out")"
# The host's mapping leads outside the superproject.
ES="$TMPDIR/escape"
host_clone "$ES"
g -C "$ES" config -f .gitmodules submodule.vendor/other.path ../outside
g clone -q "$S/other" "$TMPDIR/outside"
make_mirrors "$ES" "$TMPDIR/rt5d/mirrors" "$BASE"
assert_eq "a host path outside its superproject: refused" 1 "$RC"
assert_eq "saying so" 1 "$(grep -c 'outside its superproject' "$TMPDIR/out")"
# Moved on the host, and its new path also given to another name in the
# host's .gitmodules, before or after its own declaration: refused, in
# both orders, not taken for absent.
for ORDER in other-first own-first; do
    AM="$TMPDIR/moved-ambig-$ORDER"
    host_clone "$AM"
    mkdir -p "$AM/moved"
    g -C "$AM" mv lib/mid moved/mid
    g -C "$AM" config -f .gitmodules --remove-section submodule.lib/mid
    if [ "$ORDER" = other-first ]; then
        g -C "$AM" config -f .gitmodules submodule.other.path moved/mid
        g -C "$AM" config -f .gitmodules submodule.lib/mid.path moved/mid
    else
        g -C "$AM" config -f .gitmodules submodule.lib/mid.path moved/mid
        g -C "$AM" config -f .gitmodules submodule.other.path moved/mid
    fi
    make_mirrors "$AM" "$TMPDIR/rt5f-$ORDER/mirrors" "$BASE"
    assert_eq "moved, its new path named twice on the host ($ORDER): refused" \
        "1 1" "$RC $(grep -c 'gives lib/mid two paths, or its path two names' \
            "$TMPDIR/out")"
done
# The commit's .gitmodules gives one path two names; on the host the
# second name's module moved elsewhere: refused, in both orders.
for ORDER in other-first lib-first; do
    BA="$TMPDIR/base-ambig-$ORDER"
    g init -q "$BA"
    g -C "$BA" clone -q "$S/leaf" ./old
    g -C "$BA" update-index --add --cacheinfo "160000,${LEAF1},old"
    if [ "$ORDER" = other-first ]; then
        g -C "$BA" config -f .gitmodules submodule.other.path old
        g -C "$BA" config -f .gitmodules submodule.lib.path old
    else
        g -C "$BA" config -f .gitmodules submodule.lib.path old
        g -C "$BA" config -f .gitmodules submodule.other.path old
    fi
    g -C "$BA" add .gitmodules
    g -C "$BA" commit -q -m 'old, two names'
    mv "$BA/old" "$BA/new"
    g -C "$BA" config -f .gitmodules --remove-section submodule.other
    g -C "$BA" config -f .gitmodules submodule.lib.path new
    make_mirrors "$BA" "$TMPDIR/rt5g-$ORDER/mirrors" \
        "$(git -C "$BA" rev-parse HEAD)"
    assert_eq "a path two names claim in the commit, one moved ($ORDER): refused" \
        "1 1" "$RC $(grep -c 'gives lib two paths, or its path two names' \
            "$TMPDIR/out")"
done
# deinit: not initialized any more, so not mirrored.
DI="$TMPDIR/deinit"
host_clone "$DI"
g -C "$DI" submodule deinit -q -f -- vendor/other >/dev/null 2>&1
make_mirrors "$DI" "$TMPDIR/rt5e/mirrors" "$BASE"
assert_eq "a deinit'ed module is not mirrored, nor what was under it" \
    "lib/mid lib/mid/deep/le af" "$(listed "$TMPDIR/rt5e/mirrors")"

# ============================================================
echo ""
echo "=== 6. .gitmodules entries Git ignores, repeats, refuses ==="

# A repository whose .gitmodules has each case, each path a gitlink the
# host has initialized (a clone there, its own .git directory).
odd_repo() {   # DIR then pairs NAME PATH
    local dir="$1" p
    shift
    g init -q "$dir"
    while [ "$#" -gt 1 ]; do
        p=$2
        if [ ! -e "$dir/$p" ]; then
            mkdir -p "$(dirname "$dir/$p")"
            g -C "$dir" clone -q "$S/leaf" "./$p"
            g -C "$dir" update-index --add --cacheinfo "160000,${LEAF1},${p}"
        fi
        g -C "$dir" config -f .gitmodules --add "submodule.${1}.path" "$p"
        shift 2
    done
    g -C "$dir" add .gitmodules
    g -C "$dir" commit -q -m odd
}
odd_repo "$TMPDIR/ign" ../x bad minus -dash same same same same
make_mirrors "$TMPDIR/ign" "$TMPDIR/rt6/mirrors" \
    "$(git -C "$TMPDIR/ign" rev-parse HEAD)"
assert_eq "entries Git ignores are not submodules; a repeated one counts once" \
    "0 same" "$RC $(listed "$TMPDIR/rt6/mirrors")"
odd_repo "$TMPDIR/two-names" one shared two shared
make_mirrors "$TMPDIR/two-names" "$TMPDIR/rt6b/mirrors" \
    "$(git -C "$TMPDIR/two-names" rev-parse HEAD)"
assert_eq "a path two names claim, initialized: refused" 1 "$RC"
assert_eq "saying so" 1 \
    "$(grep -c 'gives one two paths, or its path two names' "$TMPDIR/out")"
odd_repo "$TMPDIR/two-paths" twice p1 twice p2
make_mirrors "$TMPDIR/two-paths" "$TMPDIR/rt6c/mirrors" \
    "$(git -C "$TMPDIR/two-paths" rev-parse HEAD)"
assert_eq "a name with two paths, initialized: refused" 1 "$RC"
assert_eq "before anything is written" no \
    "$(present "$TMPDIR/rt6c/mirrors")"
odd_repo "$TMPDIR/nested-names" foo a foo/bar b
make_mirrors "$TMPDIR/nested-names" "$TMPDIR/rt6d/mirrors" \
    "$(git -C "$TMPDIR/nested-names" rev-parse HEAD)"
assert_eq "names foo and foo/bar, both initialized: refused" 1 "$RC"
assert_eq "saying the containers' Git cannot init both" 1 \
    "$(grep -c 'git dirs modules/foo and modules/foo/bar, one inside the other' \
        "$TMPDIR/out")"
odd_repo "$TMPDIR/dot-names" foo a ./foo/bar b
make_mirrors "$TMPDIR/dot-names" "$TMPDIR/rt6g/mirrors" \
    "$(git -C "$TMPDIR/dot-names" rev-parse HEAD)"
assert_eq "names foo and ./foo/bar, the same git dirs: refused" 1 "$RC"
odd_repo "$TMPDIR/dot-name" . a
make_mirrors "$TMPDIR/dot-name" "$TMPDIR/rt6i/mirrors" \
    "$(git -C "$TMPDIR/dot-name" rev-parse HEAD)"
assert_eq "a name . (no git dir of its own): refused" "1 1" \
    "$RC $(grep -c 'gives the containers. Git no directory of its own' \
        "$TMPDIR/out")"
odd_repo "$TMPDIR/dot-name2" foo/. a
make_mirrors "$TMPDIR/dot-name2" "$TMPDIR/rt6j/mirrors" \
    "$(git -C "$TMPDIR/dot-name2" rev-parse HEAD)"
assert_eq "a name foo/.: refused" 1 "$RC"
odd_repo "$TMPDIR/host-ambig" lib sub
g -C "$TMPDIR/host-ambig" config -f .gitmodules submodule.other.path sub
make_mirrors "$TMPDIR/host-ambig" "$TMPDIR/rt6h/mirrors" \
    "$(git -C "$TMPDIR/host-ambig" rev-parse HEAD)"
assert_eq "a path two names claim in the host's own .gitmodules: refused" \
    1 "$RC"
odd_repo "$TMPDIR/bad-update" good good
g -C "$TMPDIR/bad-update" config -f .gitmodules submodule.good.update bogus
g -C "$TMPDIR/bad-update" commit -q -am 'update = bogus'
make_mirrors "$TMPDIR/bad-update" "$TMPDIR/rt6e/mirrors" \
    "$(git -C "$TMPDIR/bad-update" rev-parse HEAD)"
assert_eq "a value Git refuses in .gitmodules: refused" 1 "$RC"
assert_eq "with Git's own message" 1 \
    "$(grep -c "Git cannot read the .gitmodules of the checkout .*invalid value for '\{0,1\}submodule.good.update" \
        "$TMPDIR/out")"
odd_repo "$TMPDIR/no-value" good good
printf '[submodule "bogus"]\n\tpath\n' >> "$TMPDIR/no-value/.gitmodules"
g -C "$TMPDIR/no-value" commit -q -am 'a path without a value'
make_mirrors "$TMPDIR/no-value" "$TMPDIR/rt6f/mirrors" \
    "$(git -C "$TMPDIR/no-value" rev-parse HEAD)"
assert_eq "a key without a value: refused" 1 "$RC"
assert_eq "with Git's own message" 1 \
    "$(grep -c "missing value for 'submodule.bogus.path'" "$TMPDIR/out")"

# ============================================================
echo ""
echo "=== 7. Refused before anything is written ==="

refused() {   # LABEL PATTERN DIR
    assert_eq "$1: refused" 1 "$RC"
    assert_eq "$1: saying so" yes \
        "$(grep -q -- "$2" "$TMPDIR/out" && echo yes || echo no)"
    assert_eq "$1: nothing written" no "$(present "$3")"
}
L="$TMPDIR/linked"
host_clone "$L"
mv "$L/vendor" "$TMPDIR/vendor-elsewhere"
ln -s "$TMPDIR/vendor-elsewhere" "$L/vendor"
make_mirrors "$L" "$TMPDIR/rt7a/mirrors" "$BASE"
refused "a module reached through a link" "through a link" \
    "$TMPDIR/rt7a/mirrors"
rm "$L/vendor"
mv "$TMPDIR/vendor-elsewhere" "$L/vendor"
mv "$L/lib/mid/.git" "$TMPDIR/mid.gitfile"
printf 'gitdir: %s\n' "$TMPDIR/nowhere" > "$L/lib/mid/.git"
make_mirrors "$L" "$TMPDIR/rt7b/mirrors" "$BASE"
refused "a .git that leads nowhere" \
    "cannot find the Git directory of submodule lib/mid" \
    "$TMPDIR/rt7b/mirrors"
mv "$TMPDIR/mid.gitfile" "$L/lib/mid/.git"
K="$TMPDIR/lacks"
host_clone "$K"
FAKE=$(printf 'nothing' | git hash-object --stdin)
g -C "$K/lib/mid" update-index --cacheinfo "160000,${FAKE},deep/le af"
g -C "$K/lib/mid" commit -q -m 'a gitlink nobody has'
g -C "$K" add lib/mid
g -C "$K" commit -q -m 'lib/mid moves on'
make_mirrors "$K" "$TMPDIR/rt7c/mirrors" "$(git -C "$K" rev-parse HEAD)"
refused "a commit the git dir lacks, nested" \
    "lib/mid/deep/le af: .* has no commit ${FAKE}" "$TMPDIR/rt7c/mirrors"
assert_eq "the preflight refuses it too" 1 \
    "$( (swarm_mirrors_preflight "$K") >/dev/null 2>&1; echo $?)"
SH="$TMPDIR/shallow"
host_clone "$SH"
SHG=$(cd -P "$SH/vendor/other/x" && git rev-parse --absolute-git-dir)
echo "$LEAF1" > "$SHG/shallow"
make_mirrors "$SH" "$TMPDIR/rt7d/mirrors" "$BASE"
refused "a shallow clone" "vendor/other/x is a shallow clone" \
    "$TMPDIR/rt7d/mirrors"
rm "$SHG/shallow"
g -C "$SH/vendor/other/x" config remote.origin.promisor true
make_mirrors "$SH" "$TMPDIR/rt7e/mirrors" "$BASE"
refused "a partial clone" "vendor/other/x is a partial clone" \
    "$TMPDIR/rt7e/mirrors"
# A .gitmodules or a tree whose object is gone: refused, not taken for
# "no submodules".
UB="$TMPDIR/unreadable"
host_clone "$UB"
GMB=$(git -C "$UB" rev-parse 'HEAD:.gitmodules')
mv "$UB/.git/objects/${GMB:0:2}/${GMB:2}" "$TMPDIR/gm.object"
make_mirrors "$UB" "$TMPDIR/rt7g/mirrors" "$BASE"
refused "a .gitmodules whose blob is gone" "cannot read the .gitmodules" \
    "$TMPDIR/rt7g/mirrors"
RC=0
(swarm_mirrors_ready "$UB" "$TMPDIR/nothing-here" "$BASE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "and readiness does not call that nothing to mirror" "1 1" \
    "$RC $(grep -c "cannot read the engagement's base" "$TMPDIR/out")"
mv "$TMPDIR/gm.object" "$UB/.git/objects/${GMB:0:2}/${GMB:2}"
# A .gitmodules entry whose object is a tree: no blob to read.
UT0=$(git -C "$UB" rev-parse 'HEAD^{tree}')
BT=$( { printf '100644 .gitmodules\000'
        printf "$(printf '%s' "$UT0" | sed 's/../\\x&/g')"; } \
    | git -C "$UB" hash-object -t tree -w --stdin --literally)
BC=$(g -C "$UB" commit-tree -m 'a .gitmodules that is a tree' "$BT")
make_mirrors "$UB" "$TMPDIR/rt7i/mirrors" "$BC"
refused "a .gitmodules that is a tree" "cannot read the .gitmodules" \
    "$TMPDIR/rt7i/mirrors"
RC=0
(swarm_mirrors_ready "$UB" "$TMPDIR/nothing-here" "$BC") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "and readiness refuses it too" 1 "$RC"
UT=$(git -C "$UB" rev-parse 'HEAD^{tree}')
mv "$UB/.git/objects/${UT:0:2}/${UT:2}" "$TMPDIR/tree.object"
make_mirrors "$UB" "$TMPDIR/rt7h/mirrors" "$BASE"
refused "a tree that is gone" "cannot read the tree of the checkout" \
    "$TMPDIR/rt7h/mirrors"
mv "$TMPDIR/tree.object" "$UB/.git/objects/${UT:0:2}/${UT:2}"
# A .gitmodules Git cannot parse in the commit (the host's own copy
# fixed since), at its start or at its end: refused, not taken for "no
# submodules".
for WHERE in start end; do
    BS="$TMPDIR/bad-syntax-$WHERE"
    g init -q "$BS"
    g -C "$BS" clone -q "$S/leaf" ./sub
    g -C "$BS" update-index --add --cacheinfo "160000,${LEAF1},sub"
    if [ "$WHERE" = start ]; then
        printf '[broken\n[submodule "sub"]\n\tpath = sub\n' \
            > "$BS/.gitmodules"
    else
        printf '[submodule "sub"]\n\tpath = sub\n[broken\n' \
            > "$BS/.gitmodules"
    fi
    g -C "$BS" add .gitmodules
    g -C "$BS" commit -q -m 'a .gitmodules Git cannot parse'
    BSC=$(git -C "$BS" rev-parse HEAD)
    printf '[submodule "sub"]\n\tpath = sub\n' > "$BS/.gitmodules"
    make_mirrors "$BS" "$TMPDIR/rt7s-$WHERE/mirrors" "$BSC"
    refused "a .gitmodules Git cannot parse ($WHERE)" \
        "cannot read the .gitmodules" "$TMPDIR/rt7s-$WHERE/mirrors"
    RC=0
    (swarm_mirrors_ready "$BS" "$TMPDIR/nothing-here" "$BSC") \
        > "$TMPDIR/out" 2>&1 || RC=$?
    assert_eq "and readiness refuses it ($WHERE)" 1 "$RC"
done
# A gitlink that names an annotated tag, not a commit: the containers
# would check out the commit it peels to, never the gitlink.
AT="$TMPDIR/tag-gitlink"
g init -q "$AT"
g -C "$AT" clone -q "$S/leaf" ./sub
g -C "$AT/sub" tag -a v1 -m v1
TAGOID=$(git -C "$AT/sub" rev-parse refs/tags/v1)
g -C "$AT" update-index --add --cacheinfo "160000,${TAGOID},sub"
g -C "$AT" config -f .gitmodules submodule.sub.path sub
g -C "$AT" add .gitmodules
g -C "$AT" commit -q -m 'a gitlink naming a tag'
make_mirrors "$AT" "$TMPDIR/rt7t/mirrors" "$(git -C "$AT" rev-parse HEAD)"
refused "a gitlink that names an annotated tag" \
    "sub: .* has no commit ${TAGOID}" "$TMPDIR/rt7t/mirrors"
NLR="$TMPDIR/newline"
g init -q "$NLR"
g -C "$NLR" submodule add -q --name nl "$S/leaf" $'new\nline' >/dev/null 2>&1
g -C "$NLR" commit -q -m newline
make_mirrors "$NLR" "$TMPDIR/rt7f/mirrors" "$(git -C "$NLR" rev-parse HEAD)"
refused "a newline in a path" "a tab or a newline in its name or path" \
    "$TMPDIR/rt7f/mirrors"

# ============================================================
echo ""
echo "=== 8. Any other name and path ==="

QP='sp ace/"q'\''uote'
N="$TMPDIR/names"
g init -q "$N"
g -C "$N" submodule add -q --name 'q"uo te' "$S/leaf" "$QP" >/dev/null 2>&1
BYTE=no
if mkdir "$TMPDIR/b"$'\xff' 2>/dev/null; then
    rmdir "$TMPDIR/b"$'\xff'
    BYTE=yes
    g -C "$N" submodule add -q --name $'by\xfete' "$S/leaf" $'by\xfete' \
        >/dev/null 2>&1
fi
g -C "$N" commit -q -m names
# Under a UTF-8 locale this system has, where git config --get-regexp
# passes over a name that is not UTF-8 and tr refuses one.
UTF8=""
for LOC in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if [ "$(LC_ALL=$LOC locale charmap 2>/dev/null)" = UTF-8 ]; then
        UTF8=$LOC
        break
    fi
done
[ -n "$UTF8" ] \
    || echo "  (no UTF-8 locale here: these cases run in the C locale only)"
LC_ALL=${UTF8:-C} make_mirrors "$N" "$TMPDIR/rt8/mirrors" \
    "$(git -C "$N" rev-parse HEAD)"
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "a path with spaces and quotes round-trips" "$QP" \
    "$(jq -r '.mirrors[0].path' "$TMPDIR/rt8/mirrors/manifest.json" \
        | base64 -d)"
assert_eq "and its name" 'q"uo te' \
    "$(jq -r '.mirrors[0].name' "$TMPDIR/rt8/mirrors/manifest.json" \
        | base64 -d)"
EXPECT=$(git -C "$N" rev-parse HEAD) LC_ALL=${UTF8:-C} \
    container_init "$N" "$TMPDIR/rt8/mirrors" "$TMPDIR/ws8"
assert_eq "a container checks it out" leaf \
    "$(cat "$TMPDIR/ws8/$QP/leaf.txt" 2>/dev/null)"
if [ "$BYTE" = yes ]; then
    assert_eq "a byte that is not UTF-8 round-trips" $'by\xfete' \
        "$(jq -r '.mirrors[1].path' "$TMPDIR/rt8/mirrors/manifest.json" \
            | base64 -d)"
    assert_eq "and is checked out" leaf \
        "$(cat "$TMPDIR/ws8/"$'by\xfete'"/leaf.txt" 2>/dev/null)"
else
    echo "  (this file system takes no file name that is not UTF-8)"
fi
# A name that is not UTF-8 on an ASCII path, its repository embedded
# (no git dir under modules/ by that name): any file system has it.
NB="$TMPDIR/name-byte"
g init -q "$NB"
g -C "$NB" clone -q "$S/leaf" ./sub
g -C "$NB" update-index --add --cacheinfo "160000,${LEAF1},sub"
g -C "$NB" config -f .gitmodules "submodule.by"$'\xfe'"te.path" sub
g -C "$NB" add .gitmodules
g -C "$NB" commit -q -m 'a name that is not UTF-8'
LC_ALL=${UTF8:-C} make_mirrors "$NB" "$TMPDIR/rt8n/mirrors" \
    "$(git -C "$NB" rev-parse HEAD)"
assert_eq "a name that is not UTF-8 is mirrored, under ${UTF8:-C}" \
    "0 by"$'\xfe'"te" "$RC $(jq -r '.mirrors[0].name' \
        "$TMPDIR/rt8n/mirrors/manifest.json" 2>/dev/null | base64 -d)"
assert_eq "and its manifest is valid there" yes \
    "$(LC_ALL=${UTF8:-C} swarm_mirrors_manifest_ok \
        "$TMPDIR/rt8n/mirrors/manifest.json" "$(git -C "$NB" rev-parse HEAD)" \
        && echo yes || echo no)"
NG="$TMPDIR/globs"
g init -q "$NG"
g -C "$NG" submodule add -q --name 'g[a]' "$S/leaf" 'g[a]' >/dev/null 2>&1
g -C "$NG" submodule add -q --name ga "$S/leaf" ga >/dev/null 2>&1
for nm in 'g[a]' ga; do
    g -C "$NG" config -f .gitmodules "submodule.${nm}.url" "${URLBASE}/x.git"
done
g -C "$NG" add .gitmodules
g -C "$NG" commit -q -m globs
# ga is not initialized on the host.
g -C "$NG" submodule deinit -q -f -- ga >/dev/null 2>&1
make_mirrors "$NG" "$TMPDIR/rt8b/mirrors" "$(git -C "$NG" rev-parse HEAD)"
assert_eq "only g[a] is mirrored" "g[a]" "$(listed "$TMPDIR/rt8b/mirrors")"
EXPECT=$(git -C "$NG" rev-parse HEAD) \
    container_init "$NG" "$TMPDIR/rt8b/mirrors" "$TMPDIR/ws8b"
assert_eq "a glob character in a path is a character" yes \
    "$(present "$TMPDIR/ws8b/g[a]/leaf.txt")"
assert_eq "so ga, which matches it as a pattern, stays uninitialized" no \
    "$(present "$TMPDIR/ws8b/ga/.git")"

# ============================================================
echo ""
echo "=== 9. What a container skips, and what stops it ==="

# A copy of M with lib/mid's mirror gone: the container stops.
F9="$TMPDIR/rt9/mirrors"
mkdir -p "$F9"
cp -R "$M/." "$F9/"
mv "$F9/1.git" "$TMPDIR/one.git"
RC=0
container_init "$H" "$F9" "$TMPDIR/ws9" || RC=$?
assert_eq "a listed mirror missing stops the container's startup" 1 "$RC"
assert_eq "saying which" 1 \
    "$(grep -c '^submodules: lib/mid: no mirror 1.git$' "$TMPDIR/init.out")"
mv "$TMPDIR/one.git" "$F9/1.git"
RC=0
EXPECT="$(printf '%040d' 0)" container_init "$H" "$F9" "$TMPDIR/ws9x" || RC=$?
assert_eq "a manifest for another base stops it" "1 1" \
    "$RC $(grep -c 'is not a valid manifest for this engagement' "$TMPDIR/init.out")"
RC=0
EXPECT="" container_init "$H" "$F9" "$TMPDIR/ws9y" || RC=$?
assert_eq "so does no base given" 1 "$RC"
# agent-work set update = none for lib/mid.
A="$TMPDIR/agentwork"
g clone -q "$S/top" "$A"
g -C "$A" config -f .gitmodules submodule.lib/mid.update none
g -C "$A" commit -q -am 'lib/mid: update = none'
container_init "$A" "$F9" "$TMPDIR/ws9a"
assert_eq "update = none leaves lib/mid out" no \
    "$(present "$TMPDIR/ws9a/lib/mid/.git")"
assert_eq "saying so" 1 \
    "$(grep -c '^submodules: lib/mid: skipped, update = none' "$TMPDIR/init.out")"
assert_eq "and what is under it is skipped" 1 \
    "$(grep -c '^submodules: lib/mid/deep/le af: skipped, its superproject is not checked out$' \
        "$TMPDIR/init.out")"
assert_eq "without a URL in the checkout's config for either" ":" \
    "$(git -C "$TMPDIR/ws9a" config submodule.lib/mid.url || true):$(git -C "$TMPDIR/ws9a" config 'submodule.deep/le af.url' || true)"
# agent-work renamed lib/mid in .gitmodules.
A2="$TMPDIR/agentwork2"
g clone -q "$S/top" "$A2"
g -C "$A2" config -f .gitmodules --rename-section \
    submodule.lib/mid submodule.renamed
g -C "$A2" commit -q -am 'lib/mid renamed'
container_init "$A2" "$F9" "$TMPDIR/ws9b"
assert_eq "a name the checkout maps differently: skipped" 1 \
    "$(grep -c '^submodules: lib/mid: skipped, its name in this checkout.s .gitmodules is another$' \
        "$TMPDIR/init.out")"
assert_eq "no URL set for either name" ":" \
    "$(git -C "$TMPDIR/ws9b" config submodule.lib/mid.url || true):$(git -C "$TMPDIR/ws9b" config submodule.renamed.url || true)"
# agent-work made vendor/other a directory holding two gitlinks.
A3="$TMPDIR/agentwork3"
g clone -q "$S/top" "$A3"
g -C "$A3" rm -q --cached vendor/other
g -C "$A3" update-index --add --cacheinfo "160000,${LEAF1},vendor/other/one"
g -C "$A3" update-index --add --cacheinfo "160000,${LEAF1},vendor/other/two"
g -C "$A3" commit -q -m 'vendor/other is a directory of gitlinks'
container_init "$A3" "$F9" "$TMPDIR/ws9c"
assert_eq "a path that is no longer a single gitlink: skipped" 1 \
    "$(grep -c '^submodules: vendor/other: skipped, not a gitlink in this checkout$' \
        "$TMPDIR/init.out")"
assert_eq "and the gitlinks under it stay uninitialized" "no no" \
    "$(present "$TMPDIR/ws9c/vendor/other/one/.git") $(present "$TMPDIR/ws9c/vendor/other/two/.git")"
# A URL rewrite in effect: the submodule would not come from its
# mirror, and the startup stops.
if git -c a.b=c config --get a.b >/dev/null 2>&1 \
        && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=a.b GIT_CONFIG_VALUE_0=c \
            git config --get a.b >/dev/null 2>&1; then
    # The fork has the commit lib/mid's gitlink records, so the clone
    # works; only the check of where it came from stops it.
    RC=0
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$S/mid-fork/.git.insteadOf" \
        GIT_CONFIG_VALUE_0="$F9/1.git" \
        container_init "$H" "$F9" "$TMPDIR/ws9d" || RC=$?
    assert_eq "a mirror URL rewritten to a fork that has the commit stops it" \
        "1 yes" "$RC $(git -C "$TMPDIR/ws9d/lib/mid" cat-file -e \
            "${FORK_ONLY}^{commit}" 2>/dev/null && echo yes || echo no)"
    assert_eq "saying so" 1 \
        "$(grep -c '^submodules: lib/mid: not checked out from 1.git' \
            "$TMPDIR/init.out")"
else
    echo "  (this Git takes no GIT_CONFIG_COUNT; the URL rewrite case runs on 2.31 and later)"
fi
# A manifest that is not valid: nothing configured, startup stops.
cp "$M/manifest.json" "$TMPDIR/m.json"
mkdir -p "$TMPDIR/rt9e"
jq '.mirrors[0].id = 7' "$TMPDIR/m.json" > "$TMPDIR/rt9e/manifest.json"
RC=0
container_init "$H" "$TMPDIR/rt9e" "$TMPDIR/ws9e" || RC=$?
assert_eq "an invalid manifest stops it" "1 1" \
    "$RC $(grep -c 'is not a valid manifest' "$TMPDIR/init.out")"
mkdir -p "$TMPDIR/rt9f"
RC=0
container_init "$H" "$TMPDIR/rt9f" "$TMPDIR/ws9f" || RC=$?
assert_eq "no manifest: nothing done, nothing said" "0 " \
    "$RC $(cat "$TMPDIR/init.out")"

# A join appended an entry whose mirror is not made yet, after this
# container's launch found the others ready: it checks those out.
mkdir -p "$TMPDIR/rt9g"
cp -R "$M/." "$TMPDIR/rt9g/"
jq '.mirrors += [.mirrors[0] | .id = 5 | .parent = 0 | .path = "bmV3"]' \
    "$M/manifest.json" > "$TMPDIR/rt9g/manifest.json"
RC=0
COUNT=4 container_init "$H" "$TMPDIR/rt9g" "$TMPDIR/ws9g" || RC=$?
assert_eq "the entries counted at launch are checked out" \
    "0 submodules: 4 of 4 checked out from mirrors" \
    "$RC $(tail -1 "$TMPDIR/init.out")"
RC=0
COUNT=5 container_init "$H" "$TMPDIR/rt9g" "$TMPDIR/ws9h" || RC=$?
assert_eq "counting the one not made yet would stop it" 1 "$RC"
RC=0
COUNT=6 container_init "$H" "$TMPDIR/rt9g" "$TMPDIR/ws9i" || RC=$?
assert_eq "a count past the manifest's entries stops it" 1 "$RC"
RC=0
COUNT="" container_init "$H" "$TMPDIR/rt9g" "$TMPDIR/ws9j" || RC=$?
assert_eq "so does no count given" 1 "$RC"

# ============================================================
echo ""
echo "=== 10. Manifest checks ==="

bad() {   # LABEL JQ
    jq "$2" "$TMPDIR/m.json" > "$TMPDIR/bad.json"
    assert_eq "$1" no \
        "$(swarm_mirrors_manifest_ok "$TMPDIR/bad.json" "$BASE" \
            && echo yes || echo no)"
}
assert_eq "the manifest as made is valid" yes \
    "$(swarm_mirrors_manifest_ok "$TMPDIR/m.json" "$BASE" \
        && echo yes || echo no)"
bad "an id out of order" '.mirrors[1].id = 3'
bad "an id that is not an integer" '.mirrors[0].id = 1.5'
bad "a parent that is not earlier" '.mirrors[1].parent = 2'
bad "a negative parent" '.mirrors[0].parent = -1'
bad "a commit of another length" '.mirrors[0].commit = "abc"'
bad "a name that is not base64" '.mirrors[0].name = "a b"'
bad "an empty path" '.mirrors[0].path = ""'
bad "a path with a NUL" ".mirrors[0].path = \"$(printf 'a\000b' | base64)\""
bad "a path with a newline" ".mirrors[0].path = \"$(printf 'a\nb' | base64)\""
bad "a path with a tab" ".mirrors[0].path = \"$(printf 'a\tb' | base64)\""
bad "base64 that is not canonical" '.mirrors[0].path = "YR=="'
bad "a path twice under one parent" '.mirrors[3].parent = 1 | .mirrors[3].path = .mirrors[1].path'
bad "another base" ".base = \"$(printf '%040d' 0)\""
bad "another schema" '.schema = "x"'
bad "no mirrors list" 'del(.mirrors)'
{ jq '.mirrors[0].id = 7' "$TMPDIR/m.json"; cat "$TMPDIR/m.json"; } \
    > "$TMPDIR/bad.json"
assert_eq "two documents, the last one valid" no \
    "$(swarm_mirrors_manifest_ok "$TMPDIR/bad.json" "$BASE" \
        && echo yes || echo no)"
mkdir -p "$TMPDIR/rt10"
cp "$TMPDIR/bad.json" "$TMPDIR/rt10/manifest.json"
RC=0
container_init "$H" "$TMPDIR/rt10" "$TMPDIR/ws10" || RC=$?
assert_eq "and a container refuses them too" 1 "$RC"

# ============================================================
echo ""
echo "=== 11. Joins ==="

touch "$M/1.git/sentinel"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a join with nothing new succeeds" 0 "$RC"
assert_eq "and leaves the mirrors as they are" yes \
    "$(present "$M/1.git/sentinel")"
mv "$M/2.git" "$TMPDIR/two.git"
assert_eq "a gone mirror: not ready" 1 \
    "$( (swarm_mirrors_ready "$H" "$M" "$BASE") >/dev/null 2>&1; echo $?)"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a join makes it again" 0 "$RC"
assert_eq "under its id" "$(git -C "$S/mid" rev-parse "${MID1}:deep/le af")" \
    "$(git -C "$M/2.git" rev-parse -q --verify refs/swarm/gitlink)"
populate "$H" unused "$S/leaf"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a submodule initialized since is appended" "5|0|unused|unused" \
    "$(entries "$M" | tail -1)"
assert_eq "the others keep their ids" "1 2 3 4 5" \
    "$(jq -r '[.mirrors[].id] | map(tostring) | join(" ")' \
        "$M/manifest.json")"
assert_eq "and it is mirrored" true \
    "$(git -C "$M/5.git" rev-parse --is-bare-repository)"
# A mirror there needs nothing of the host's any more: its source made
# shallow, or without the commit, a join still goes through.
XG=$(cd -P "$H/vendor/other/x" && git rev-parse --absolute-git-dir)
echo "$LEAF1" > "$XG/shallow"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a join with a listed source made shallow since succeeds" 0 "$RC"
rm "$XG/shallow"
mv "$XG" "$TMPDIR/x-gitdir"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "and with its git dir gone" 0 "$RC"
mv "$TMPDIR/x-gitdir" "$XG"
g -C "$M/4.git" update-ref -d refs/swarm/gitlink
assert_eq "an incomplete mirror (no pin): not ready" 1 \
    "$( (swarm_mirrors_ready "$H" "$M" "$BASE") >/dev/null 2>&1; echo $?)"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a join refuses it too, pointing at cleanup" "1 1" \
    "$RC $(grep -c 'is not a complete mirror.*cleanup' "$TMPDIR/out")"
g -C "$M/4.git" update-ref refs/swarm/gitlink "$LEAF1"
# lib/mid's host git dir moved away (its gitfile leads nowhere): the
# join reads the host's .gitmodules there without it.
MIDG=$(cd -P "$H/lib/mid" && git rev-parse --absolute-git-dir)
mv "$MIDG" "$TMPDIR/mid-gitdir"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a join with a listed parent's git dir gone succeeds" 0 "$RC"
mv "$TMPDIR/mid-gitdir" "$MIDG"
mkdir "$M/2.git.new"
mv "$M/2.git" "$TMPDIR/two-b.git"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a .new left by a stopped run refuses" 1 "$RC"
assert_eq "saying cleanup removes it" 1 \
    "$(grep -c '2.git.new is left from a run stopped half way' "$TMPDIR/out")"
rmdir "$M/2.git.new"
mv "$TMPDIR/two-b.git" "$M/2.git"
OTHER_BASE=$(g -C "$H" commit-tree -m other "$(git -C "$H" rev-parse 'HEAD^{tree}')")
make_mirrors "$H" "$M" "$OTHER_BASE" missing
assert_eq "a manifest for another base refuses" 1 "$RC"
make_mirrors "$H" "$M" "$BASE"
assert_eq "a new engagement never takes a manifest over" 1 "$RC"
# A listed mirror gone, and the host no longer has that submodule.
g -C "$H" submodule deinit -q -f -- unused >/dev/null 2>&1
mv "$M/5.git" "$TMPDIR/five.git"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a gone mirror the host cannot give again refuses" 1 "$RC"
mv "$TMPDIR/five.git" "$M/5.git"
make_mirrors "$H" "$M" "$BASE" missing
assert_eq "a listed one the host no longer has stays listed" "0 5" \
    "$RC $(jq '.mirrors | length' "$M/manifest.json")"
mkdir -p "$TMPDIR/rt11/mirrors"
make_mirrors "$H" "$TMPDIR/rt11/mirrors" "$BASE" missing
assert_eq "a join with mirrors/ empty mirrors as a creation does" \
    "0 4" "$RC $(jq '.mirrors | length' "$TMPDIR/rt11/mirrors/manifest.json")"
mkdir -p "$TMPDIR/rt11b/mirrors/lib_mid.git"
make_mirrors "$H" "$TMPDIR/rt11b/mirrors" "$BASE" missing
assert_eq "mirrors without a manifest (an earlier release's) refuse" 1 "$RC"
assert_eq "saying so" 1 \
    "$(grep -c 'holds mirrors without a manifest, which an earlier release' \
        "$TMPDIR/out")"
assert_eq "and nothing is written" "lib_mid.git" \
    "$(ls "$TMPDIR/rt11b/mirrors")"

# ============================================================
echo ""
echo "=== 12. Ready, and the mount ==="

swarm_mirrors_mount_args "$H" "$M" "$BASE"
assert_eq "ready: mirrors/ read-only at /mirrors, the base and the count" \
    "--mount type=bind,src=${M},dst=/mirrors,readonly -e SWARM_MIRRORS_BASE=${BASE} -e SWARM_MIRRORS_COUNT=5" \
    "${SWARM_MIRROR_ARGS[*]}"
PIN=$(git -C "$M/3.git" rev-parse refs/swarm/gitlink)
g -C "$M/3.git" update-ref refs/swarm/gitlink \
    "$(g -C "$M/3.git" commit-tree -m elsewhere "${PIN}^{tree}")"
assert_eq "a mirror whose pin is not the listed commit: not ready" 1 \
    "$( (swarm_mirrors_ready "$H" "$M" "$BASE") >/dev/null 2>&1; echo $?)"
g -C "$M/3.git" update-ref refs/swarm/gitlink "$PIN"
RC=0
(swarm_mirrors_mount_args "$H" "$TMPDIR/rt11b/mirrors" "$BASE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "an earlier release's mirrors: refused" 1 "$RC"
RC=0
(swarm_mirrors_mount_args "$H" "$TMPDIR/nothing-here" "$BASE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "no manifest while the base maps submodules: refused" 1 "$RC"
assert_eq "saying the mirrors were never made" 1 \
    "$(grep -c 'mirrors were never made' "$TMPDIR/out")"
PLAIN="$TMPDIR/plain"
g init -q "$PLAIN"
g -C "$PLAIN" commit -q --allow-empty -m plain
swarm_mirrors_mount_args "$PLAIN" "$TMPDIR/nothing-here" \
    "$(git -C "$PLAIN" rev-parse HEAD)"
assert_eq "no manifest and nothing to mirror: no mount, no error" 0 \
    "${#SWARM_MIRROR_ARGS[@]}"
RC=0
(swarm_mirrors_mount_args "$PLAIN" "$TMPDIR/nothing-here" "$FAKE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "a base that cannot be read is no 'nothing to mirror'" 1 "$RC"
assert_eq "saying so" 1 "$(grep -c "cannot read the engagement's base" \
    "$TMPDIR/out")"

# ============================================================
echo ""
echo "=== 13. The manifest comes first ==="

# The second clone fails: the manifest lists every mirror, the first is
# there, a join makes the others.
RC=0
(
    swarm_recovery_git() {
        local a
        for a in "$@"; do
            if [ "$a" = "$TMPDIR/rt13/mirrors/2.git.new" ]; then
                return 1
            fi
        done
        env -u GIT_DIR git "$@"
    }
    swarm_mirrors_make "$H" "$TMPDIR/rt13/mirrors" "$BASE"
) > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "a failed clone stops mirroring" 1 "$RC"
assert_eq "the manifest lists every mirror" 4 \
    "$(jq '.mirrors | length' "$TMPDIR/rt13/mirrors/manifest.json")"
assert_eq "the first is there, the second is not" "yes no" \
    "$(present "$TMPDIR/rt13/mirrors/1.git") $(present "$TMPDIR/rt13/mirrors/2.git")"
assert_eq "not ready" 1 \
    "$( (swarm_mirrors_ready "$H" "$TMPDIR/rt13/mirrors" "$BASE") \
        >/dev/null 2>&1; echo $?)"
make_mirrors "$H" "$TMPDIR/rt13/mirrors" "$BASE" missing
assert_eq "a join makes the rest" "0 yes yes" \
    "$RC $(present "$TMPDIR/rt13/mirrors/2.git") $(present "$TMPDIR/rt13/mirrors/4.git")"

# ============================================================
echo ""
echo "=== 14. A mirror every Git reads ==="

# A user's defaults that would make a repository older Git refuses:
# Git 2.56's init.defaultSubmodulePathConfig, Git 2.45's reftable.
mkdir -p "$TMPDIR/home"
printf '[init]\n\tdefaultSubmodulePathConfig = true\n\tdefaultRefFormat = reftable\n' \
    > "$TMPDIR/home/.gitconfig"
RC=0
(HOME="$TMPDIR/home" GIT_CONFIG_GLOBAL="$TMPDIR/home/.gitconfig" \
    GIT_DEFAULT_REF_FORMAT=reftable \
    swarm_mirrors_make "$H" "$TMPDIR/rt14/mirrors" "$BASE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "mirroring succeeds" 0 "$RC"
assert_eq "no repository extension in a mirror" "0 " \
    "$(git -C "$TMPDIR/rt14/mirrors/1.git" config --local \
        core.repositoryformatversion) $(git -C "$TMPDIR/rt14/mirrors/1.git" \
        config --local --get-regexp '^extensions\.' || true)"
# The user's URL rewrites do not reach the host's clones either: a fork
# that has the commit would pass every other check.
printf '[url "%s"]\n\tinsteadOf = %s\n' "$S/mid-fork/.git" \
    "$(cd -P "$H/.git/modules/lib/mid" && pwd -P)" > "$TMPDIR/home/.gitconfig"
RC=0
(HOME="$TMPDIR/home" GIT_CONFIG_GLOBAL="$TMPDIR/home/.gitconfig" \
    swarm_mirrors_make "$H" "$TMPDIR/rt14b/mirrors" "$BASE") \
    > "$TMPDIR/out" 2>&1 || RC=$?
assert_eq "a URL rewrite of the user's is not applied" "0 no" \
    "$RC $(git -C "$TMPDIR/rt14b/mirrors/1.git" cat-file -e \
        "${FORK_ONLY}^{commit}" 2>/dev/null && echo yes || echo no)"

# ============================================================
echo ""
echo "=== 15. The push path's sync ==="

# A workspace as a container has it, its submodules moved off their
# gitlinks: the sync puts them back, at any depth, fetching nothing.
WS="$TMPDIR/ws15"
container_init "$H" "$M" "$WS"
WS=$(cd -P "$WS" && pwd -P)
g -C "$WS/lib/mid" checkout -q --detach HEAD~0
g -C "$WS/lib/mid" commit -q --allow-empty -m drift
g -C "$WS/lib/mid/deep/le af" commit -q --allow-empty -m drift
_log() { printf '%s\n' "$*"; }
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "both levels are back at their gitlinks" \
    "$(git -C "$WS" rev-parse HEAD:lib/mid) $(git -C "$WS/lib/mid" rev-parse 'HEAD:deep/le af')" \
    "$(git -C "$WS/lib/mid" rev-parse HEAD) $(git -C "$WS/lib/mid/deep/le af" rev-parse HEAD)"
assert_eq "no status left in the superproject" "" \
    "$(git -C "$WS" status --porcelain --ignore-submodules=none)"
# A gitlink whose commit the submodule lacks: logged, the others go on.
g -C "$WS" update-index --cacheinfo "160000,${FAKE},lib/mid"
g -C "$WS/vendor/other" commit -q --allow-empty -m drift
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "one it cannot put back is logged" 1 \
    "$(grep -c "lib/mid: cannot be put back at ${FAKE}" "$TMPDIR/sync.out")"
assert_eq "and the next is put back all the same" \
    "$(git -C "$WS" rev-parse HEAD:vendor/other)" \
    "$(git -C "$WS/vendor/other" rev-parse HEAD)"
g -C "$WS" update-index --cacheinfo "160000,$(git -C "$WS" rev-parse HEAD:lib/mid),lib/mid"
# A submodule whose git dir is outside the workspace is left alone.
g clone -q --bare "$S/leaf" "$TMPDIR/outside-gd.git"
printf 'gitdir: %s\n' "$TMPDIR/outside-gd.git" > "$WS/vendor/other/x/.git.new"
mv "$WS/vendor/other/x/.git" "$TMPDIR/x.gitfile"
mv "$WS/vendor/other/x/.git.new" "$WS/vendor/other/x/.git"
OUTSIDE_HEAD=$(git --git-dir="$TMPDIR/outside-gd.git" rev-parse HEAD)
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "a git dir outside the workspace is not touched" "$OUTSIDE_HEAD" \
    "$(git --git-dir="$TMPDIR/outside-gd.git" rev-parse HEAD)"
assert_eq "saying so" 1 \
    "$(grep -c 'vendor/other/x: left as it is' "$TMPDIR/sync.out")"
mv "$TMPDIR/x.gitfile" "$WS/vendor/other/x/.git"
# vendor/other's checkout does not go into x by itself, even with
# submodule.recurse on there: x's git dir, where vendor/other's
# modules/ leads, is outside the workspace and off its gitlink, and it
# stays so.
OG=$(cd -P "$WS/vendor/other" && git rev-parse --absolute-git-dir)
XWT=$(cd -P "$WS/vendor/other/x" && pwd -P)
mv "$OG/modules/deep/le af" "$TMPDIR/ext-x.git"
ln -s "$TMPDIR/ext-x.git" "$OG/modules/deep/le af"
git config --file "$TMPDIR/ext-x.git/config" core.worktree "$XWT"
g -C "$WS/vendor/other/x" commit -q --allow-empty -m 'off its gitlink'
EXT_HEAD=$(git --git-dir="$TMPDIR/ext-x.git" rev-parse HEAD)
g -C "$WS/vendor/other" config submodule.recurse true
g -C "$WS/vendor/other" commit -q --allow-empty -m drift
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "vendor/other is put back" \
    "$(git -C "$WS" rev-parse HEAD:vendor/other)" \
    "$(git -C "$WS/vendor/other" rev-parse HEAD)"
assert_eq "submodule.recurse does not take that checkout into x" \
    "$EXT_HEAD" "$(git --git-dir="$TMPDIR/ext-x.git" rev-parse HEAD)"
assert_eq "which the sync leaves as it is, saying so" 1 \
    "$(grep -c 'vendor/other/x: left as it is' "$TMPDIR/sync.out")"
g -C "$WS/vendor/other" config --unset submodule.recurse
rm "$OG/modules/deep/le af"
mv "$TMPDIR/ext-x.git" "$OG/modules/deep/le af"
git config --file "$OG/modules/deep/le af/config" core.worktree "$XWT"
# No fsmonitor of the workspace's runs, for listing either.
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$TMPDIR/fsmonitor-ran" \
    > "$TMPDIR/fsmonitor.sh"
chmod +x "$TMPDIR/fsmonitor.sh"
g -C "$WS" config core.fsmonitor "$TMPDIR/fsmonitor.sh"
g -C "$WS/lib/mid" config core.fsmonitor "$TMPDIR/fsmonitor.sh"
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "no fsmonitor runs" no "$(present "$TMPDIR/fsmonitor-ran")"
g -C "$WS" config --unset core.fsmonitor
g -C "$WS/lib/mid" config --unset core.fsmonitor
# A gitlink in a merge conflict (stages 1 to 3): left as it is, with
# the agent's edits in it.
WM="$TMPDIR/ws15m"
container_init "$H" "$M" "$WM"
WM=$(cd -P "$WM" && pwd -P)
MID0=$(git -C "$WM" rev-parse HEAD:lib/mid)
g -C "$WM/lib/mid" commit -q --allow-empty -m one
ONE=$(git -C "$WM/lib/mid" rev-parse HEAD)
g -C "$WM/lib/mid" checkout -q --detach "$MID0"
g -C "$WM/lib/mid" commit -q --allow-empty -m two
TWO=$(git -C "$WM/lib/mid" rev-parse HEAD)
g -C "$WM" checkout -q -b side
g -C "$WM" update-index --cacheinfo "160000,${ONE},lib/mid"
g -C "$WM" commit -q -m 'lib/mid at one'
g -C "$WM" checkout -q -
g -C "$WM" update-index --cacheinfo "160000,${TWO},lib/mid"
g -C "$WM" commit -q -m 'lib/mid at two'
g -C "$WM" merge -q side >/dev/null 2>&1 || true
assert_eq "(lib/mid is unmerged: three stages)" 3 \
    "$(git -C "$WM" ls-files -s -- lib/mid | wc -l | tr -d ' ')"
echo edit >> "$WM/lib/mid/mid.txt"
swarm_submodules_sync "$WM" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "an unmerged gitlink's submodule stays where it is" "$TWO" \
    "$(git -C "$WM/lib/mid" rev-parse HEAD)"
assert_eq "with the edit in it" "edit" "$(tail -1 "$WM/lib/mid/mid.txt")"
assert_eq "saying so, once" 1 \
    "$(grep -c 'lib/mid: left as it is, unmerged' "$TMPDIR/sync.out")"
# A git dir under the workspace whose common dir is outside it.
MG=$(cd -P "$WS/lib/mid" && git rev-parse --absolute-git-dir)
printf '%s\n' "$TMPDIR/outside-gd.git" > "$MG/commondir"
g -C "$WS/lib/mid" commit -q --allow-empty -m drift 2>/dev/null || true
swarm_submodules_sync "$WS" _log > "$TMPDIR/sync.out" 2>&1
assert_eq "a common dir outside the workspace: left as it is" 1 \
    "$(grep -c 'lib/mid: left as it is' "$TMPDIR/sync.out")"
rm -f "$MG/commondir"

# ============================================================
echo ""
echo "=== 16. SHA-256 repositories ==="

g init -q --object-format=sha256 "$TMPDIR/leaf256"
g -C "$TMPDIR/leaf256" commit -q --allow-empty -m leaf
g init -q --object-format=sha256 "$TMPDIR/top256"
g -C "$TMPDIR/top256" submodule add -q "$TMPDIR/leaf256" sub >/dev/null 2>&1
g -C "$TMPDIR/top256" commit -q -m top
B256=$(git -C "$TMPDIR/top256" rev-parse HEAD)
make_mirrors "$TMPDIR/top256" "$TMPDIR/rt16/mirrors" "$B256"
assert_eq "a SHA-256 checkout and submodule are mirrored" "0 sub" \
    "$RC $(listed "$TMPDIR/rt16/mirrors")"
assert_eq "the mirror pins the 64-digit commit" \
    "$(git -C "$TMPDIR/top256" rev-parse HEAD:sub)" \
    "$(git -C "$TMPDIR/rt16/mirrors/1.git" rev-parse -q --verify \
        refs/swarm/gitlink)"
EXPECT=$B256 container_init "$TMPDIR/top256" "$TMPDIR/rt16/mirrors" \
    "$TMPDIR/ws16"
assert_eq "and a container checks it out" \
    "submodules: 1 of 1 checked out from mirrors" "$(tail -1 "$TMPDIR/init.out")"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
