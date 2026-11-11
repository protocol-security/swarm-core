#!/bin/bash
# swarm-target-checkout DIR: make DIR a checkout of the engagement's
# target, from the snapshot launch.sh mounts read-only in every
# container (SWARM_TARGET_MIRROR, /target-upstream), without the network
# and without the caller's Git configuration or environment.  DIR gets
# HEAD detached at TARGET_REV, its pin as refs/swarm/target and, with a
# base, refs/swarm/target-base at TARGET_REV_BASE; a pin at another
# object is refused.  Installed in the image as
# /usr/local/bin/swarm-target-checkout, for a setup hook (as root,
# through sudo -E) or an agent.
#
# DIR must not exist, or be an empty directory, and must not be a link;
# its parent directory must exist (links above DIR are followed).  The
# checkout is built in a temporary directory beside DIR and renamed to
# DIR at the end: until then a failure leaves DIR as it was.
# The rename fails when DIR has become a link, a file or a directory
# that is not empty meanwhile; it does not notice DIR replaced by
# another empty directory, and the checkout gets the helper's owner and
# mode, the umask's.  This keeps the checkout to the recorded commit and
# the caller's Git settings out of it; it is no barrier against another
# process of the same container user.
#
# Every Git command runs with no user or system configuration and every
# GIT_* variable of the caller unset, hooks, fsmonitor, automatic gc and
# submodule recursion off, no protocol allowed but file for the one
# fetch.  With no configuration no filter driver exists, so no attribute
# of the target runs one (LFS pointers stay as they are), and no URL
# rewrite applies.  Git's local transport runs upload-pack with the
# repository-local variables cleared (the -c settings among them): it
# reads the snapshot's own config, which launch.sh's join validator
# checked on the host, with no global or system configuration.  The
# target's submodules and LFS content are not fetched.  A second run on
# the same DIR refuses: it is not empty.
#
# Compatible with Bash 3.2.  Prints "ERROR: ..." and exits 1 on refusal
# or failure.
set -euo pipefail

FINISHED=false
PRIV=""
BUILD=""

# Delete the helper's directories however it ends, and never let a run
# that stopped short end with status 0 (Bash 3.2 runs the EXIT trap with
# $? at 0 when set -u stops the script).
on_exit() {
    local rc=$?
    [ -z "$BUILD" ] || rm -rf -- "$BUILD" 2>/dev/null || true
    [ -z "$PRIV" ] || rm -rf -- "$PRIV" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && ! $FINISHED; then
        echo "ERROR: swarm-target-checkout stopped before the end of its" \
             "run." >&2
        exit 1
    fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Succeed when $1 is a full commit id: 40 or 64 lowercase hex digits.
full_id() {
    case "$1" in
        ''|*[!0123456789abcdef]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    die "usage: swarm-target-checkout DIR"
fi

M="${SWARM_TARGET_MIRROR:-}"
if [ -z "$M" ]; then
    die "this engagement has no target (SWARM_TARGET_MIRROR is empty)."
fi
case "$M" in
    /*) ;;
    *) die "SWARM_TARGET_MIRROR is not an absolute path." ;;
esac
# The path goes into a command line Git runs through sh (--upload-pack).
SAFE='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-'
case "$M" in
    *[!$SAFE]*)
        die "SWARM_TARGET_MIRROR holds a character other than letters," \
            "digits and /._-." ;;
esac
REV="${TARGET_REV:-}"
BASE="${TARGET_REV_BASE:-}"
if ! full_id "$REV"; then
    die "TARGET_REV is not a full commit id: $(printf '%q' "$REV")"
fi
if [ -n "$BASE" ] && ! full_id "$BASE"; then
    die "TARGET_REV_BASE is not a full commit id: $(printf '%q' "$BASE")"
fi

# Where DIR is: its name, and the physical path of the directory it is
# in ("./" before a relative one, so that cd cannot read "-" or a name
# starting with a dash as anything else; the "x" keeps trailing
# newlines).
d="$1"
while :; do
    case "$d" in
        ?*/) d="${d%/}" ;;
        *) break ;;
    esac
done
NAME="${d##*/}"
case "$d" in
    */*) PARENT="${d%/*}" ;;
    *) PARENT=. ;;
esac
case "$NAME" in
    ''|.|..) die "DIR must end in a name, not $(printf '%q' "$1")." ;;
esac
case "$PARENT" in
    '') PARENT=/ ;;
    /*) ;;
    *) PARENT="./$PARENT" ;;
esac
if ! PARENT=$(CDPATH='' cd -P -- "$PARENT" 2>/dev/null && pwd -P && echo x)
then
    die "the directory DIR is in does not exist: $(printf '%q' "$1")"
fi
PARENT="${PARENT%x}"
PARENT="${PARENT%$'\n'}"
D="${PARENT%/}/$NAME"
if [ -L "$D" ]; then
    die "${D} is a link."
fi
if [ -e "$D" ]; then
    [ -d "$D" ] || die "${D} is there and is not a directory."
    entries=$(ls -A -- "$D") || die "cannot list ${D}."
    [ -z "$entries" ] || die "${D} is not empty."
fi

PRIV=$(mktemp -d "${TMPDIR:-/tmp}/swarm-target-checkout.XXXXXX") \
    || die "cannot make a temporary directory."
BUILD=$(mktemp -d "${PARENT%/}/.swarm-target-checkout.XXXXXX") \
    || die "cannot make a directory in ${PARENT}."

# None of the caller's Git variables, then the helper's own.
while IFS= read -r v; do
    case "$v" in
        GIT_*) unset "$v" ;;
    esac
done < <(compgen -e)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE="$PRIV/no-grafts" \
    GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL='' HOME="$PRIV" \
    XDG_CONFIG_HOME="$PRIV"
# core.fsmonitor empty: Git 2.30 reads a value as a hook to run.
G=(git -c core.hooksPath=/dev/null -c core.fsmonitor= -c gc.auto=0
    -c maintenance.auto=false -c fetch.writeCommitGraph=false
    -c fetch.recurseSubmodules=no -c submodule.recurse=false)
B=(--git-dir="$BUILD/.git")

FMT=$("${G[@]}" -c safe.directory="$M" --git-dir="$M" rev-parse \
    --show-object-format) || die "cannot read the snapshot at ${M}."
case "$FMT" in
    sha1) LEN=40 ;;
    sha256) LEN=64 ;;
    *) die "the snapshot at ${M} has an unknown object format." ;;
esac
if [ "${#REV}" -ne "$LEN" ] \
        || { [ -n "$BASE" ] && [ "${#BASE}" -ne "$LEN" ]; }; then
    die "the snapshot's ids are ${FMT} (${LEN} digits); TARGET_REV or" \
        "TARGET_REV_BASE is not."
fi

# The files ref backend, named where Git knows the option (git init -h
# lists it and exits with its usage status).
RF=""
HELP=$("${G[@]}" init -h 2>&1) || true
case "$HELP" in
    *--ref-format*) RF=--ref-format=files ;;
esac
# shellcheck disable=SC2086  # RF is one option or nothing
"${G[@]}" init -q --template= --object-format="$FMT" $RF -- "$BUILD" \
    > /dev/null || die "cannot make a repository in ${BUILD}."

SPECS=(refs/swarm/target:refs/swarm/target)
[ -z "$BASE" ] || SPECS+=(refs/swarm/target-base:refs/swarm/target-base)
GIT_ALLOW_PROTOCOL="file" "${G[@]}" "${B[@]}" fetch -q --no-tags \
    --no-recurse-submodules --no-write-fetch-head \
    --upload-pack="git -c safe.directory=$M upload-pack" -- "$M" \
    "${SPECS[@]}" || die "cannot fetch the target's pins from ${M}."

# Each pin must be the commit itself: its own id, not a tag of it.  (The
# refs are fixed names and the ids checked hex: no option can hide in
# them, and Git before 2.50 takes --end-of-options for a path in
# checkout.)
check_pin() {
    local ref="$1" want="$2" got type
    got=$("${G[@]}" "${B[@]}" rev-parse --verify --quiet "$ref") \
        || die "the snapshot has no ${ref}."
    if [ "$got" != "$want" ]; then
        die "${ref} is ${got} in the snapshot, not ${want}: it is not" \
            "this engagement's snapshot."
    fi
    type=$("${G[@]}" "${B[@]}" cat-file -t "$got") \
        || die "cannot read ${ref} in the snapshot."
    [ "$type" = commit ] || die "${ref} does not point to a commit."
}
check_pin refs/swarm/target "$REV"
[ -z "$BASE" ] || check_pin refs/swarm/target-base "$BASE"

(cd "$BUILD" && "${G[@]}" "${B[@]}" --work-tree="$BUILD" checkout -q \
    --detach "$REV") || die "cannot check out ${REV} in ${BUILD}."
UMASK=$(umask)
chmod "$(printf '%o' $(( 0777 & ~UMASK )))" "$BUILD" \
    || die "cannot set the mode of ${BUILD}."

# publish
if ! ERR=$(perl -e 'rename($ARGV[0], $ARGV[1]) or die "$!\n"' -- \
        "$BUILD" "$D" 2>&1); then
    die "cannot put the checkout at ${D}: ${ERR}"
fi
# From here DIR holds the checkout; a failure to print the lines below
# still ends the run with a non-zero status.
BUILD=""
echo "Checked out ${REV} at ${D}."
[ -z "$BASE" ] || echo "Its base is ${BASE}, as refs/swarm/target-base."
FINISHED=true
