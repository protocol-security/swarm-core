#!/bin/bash

# Preservation checks: before anything deletes engine state, every
# piece of agent work in it has to be in the checkout.  Sourced by
# launch.sh after lib/project.sh.

# Refs of the bare repo that hold agent work.  refs/swarm-runs/ is kept
# for per-run namespaces.
SWARM_PRESERVATION_REFS=(
    refs/heads/agent-work
    refs/heads/swarm/
    refs/heads/agent-parked/
    refs/swarm-runs/
)

# Git for the preservation checks.  Replacement objects and grafts can
# give a commit parents it does not have, which would make work look
# contained, so both are turned off.  Git warns about the graft file
# setting itself; that advice is silenced, because the checks treat
# any message on stderr as a failure.
swarm_preserve_git() {
    GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null \
        git -c advice.graftFileDeprecated=false "$@"
}

# Succeed when the checkout at ROOT is a repository with a commit at
# HEAD; say why on stderr otherwise.  Callers run this before
# swarm_tip_contained, so that a failure there means a missing commit.
swarm_checkout_readable() {
    local root="$1"
    if ! swarm_preserve_git -C "$root" rev-parse --verify --quiet \
            'HEAD^{commit}' >/dev/null 2>&1; then
        echo "ERROR: cannot read the commit at HEAD in ${root}." >&2
        return 1
    fi
}

# Succeed when commit SHA is in the history of the checkout at ROOT
# (its HEAD).  Return 1 when it is not, including when the checkout does
# not have the object at all, and 2 when git cannot tell.  The checkout
# must have passed swarm_checkout_readable.
swarm_tip_contained() {
    local root="$1" sha="$2" errf rc=0 err type
    errf=$(mktemp) || return 2
    # Git can report a broken object store on stderr and still exit 0,
    # so every step checks stderr as well as the status.  cat-file -e
    # exits 1 without a word for a missing object.
    swarm_preserve_git -C "$root" cat-file -e "$sha" 2>"$errf" || rc=$?
    if [ "$rc" -eq 1 ] && [ ! -s "$errf" ]; then
        rm -f "$errf"
        return 1
    fi
    if [ "$rc" -eq 0 ] && [ ! -s "$errf" ]; then
        type=$(swarm_preserve_git -C "$root" cat-file -t "$sha" \
            2>"$errf") || rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ ! -s "$errf" ] && [ "$type" = commit ]; then
        swarm_preserve_git -C "$root" merge-base --is-ancestor "$sha" \
            HEAD 2>"$errf" || rc=$?
        if [ "$rc" -eq 1 ] && [ ! -s "$errf" ]; then
            rm -f "$errf"
            return 1
        fi
    fi
    err=$(cat "$errf")
    rm -f "$errf"
    if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
        echo "ERROR: cannot read ${sha} in ${root}: ${err}" >&2
        return 2
    fi
    # Not a commit: nothing in HEAD's history.
    [ "$type" = commit ] || return 1
    return 0
}

# Check the preservation refs of bare repo BARE against the checkout at
# ROOT.  Return 0 when the checkout contains every tip, 1 when some are
# missing (printed as "<ref> <sha>" lines), and 2 when the check could
# not be made (said on stderr).  Callers branch on the status.
swarm_preservation_check() {
    local bare="$1" root="$2" tmp err sha type ref status rc=0
    if [ -L "$bare" ] || [ ! -d "$bare" ] \
            || [ "$(swarm_preserve_git -C "$bare" rev-parse \
                --is-bare-repository 2>/dev/null)" != true ]; then
        echo "ERROR: ${bare} is not a bare repository." >&2
        return 2
    fi
    swarm_checkout_readable "$root" || return 2
    tmp=$(mktemp) || return 2
    err=$(mktemp) || { rm -f "$tmp"; return 2; }
    # for-each-ref skips a broken ref with only a warning and still
    # succeeds, so anything on stderr counts as a failure too.
    if ! swarm_preserve_git -C "$bare" for-each-ref \
            --format='%(objectname) %(objecttype) %(refname)' \
            "${SWARM_PRESERVATION_REFS[@]}" > "$tmp" 2> "$err" \
            || [ -s "$err" ]; then
        echo "ERROR: cannot list the refs of ${bare}:" >&2
        sed 's/^/  /' "$err" >&2
        rm -f "$tmp" "$err"
        return 2
    fi
    rm -f "$err"
    while read -r sha type ref; do
        if [ "$type" != commit ]; then
            echo "ERROR: ${ref} in ${bare} does not point to a commit." >&2
            rc=2
            break
        fi
        status=0
        swarm_tip_contained "$root" "$sha" || status=$?
        case "$status" in
            0) ;;
            1)
                printf '%s %s\n' "$ref" "$sha"
                rc=1 ;;
            *)
                echo "ERROR: cannot compare ${ref} with ${root}." >&2
                rc=2
                break ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return "$rc"
}

# Explain the "<ref> <sha>" lines of swarm_preservation_check (on
# stdin) for bare repo BARE, on stderr.
swarm_preservation_explain() {
    local bare="$1" ref sha quoted qref
    quoted=$(printf '%q' "$bare")
    echo "The checkout does not contain this agent work yet:" >&2
    while read -r ref sha; do
        [ -n "$ref" ] || continue
        qref=$(printf '%q' "$ref")
        case "$ref" in
            refs/heads/agent-work|refs/heads/swarm/*/interactive-*)
                echo "  ${ref#refs/heads/} ${sha:0:12}: run ./harvest.sh" \
                     "to merge it" >&2 ;;
            *)
                echo "  ${ref#refs/heads/} ${sha:0:12}: look at it with" \
                     "git fetch ${quoted} ${qref}, then merge or" \
                     "cherry-pick what you keep" >&2 ;;
        esac
    done
    echo "A ref you have decided to drop can be deleted from the bare" \
         "repo with:" >&2
    echo "  git --git-dir=${quoted} update-ref -d <ref> <sha>" >&2
}
