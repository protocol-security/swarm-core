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
    local bare="$1" root="$2" tmp err sha type ref status rc=0 seen=0 lines
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
        seen=$((seen + 1))
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
    # A read that fails ends the loop like the end of the list: every
    # ref must have been looked at (unless the loop broke off above).
    if [ "$rc" -ne 2 ]; then
        if ! lines=$(wc -l < "$tmp") || [ "$seen" -ne "$((lines + 0))" ]
        then
            echo "ERROR: cannot read the refs of ${bare} in full." >&2
            rc=2
        fi
    fi
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

# ---- Recovery snapshots -------------------------------------------------
#
# Before cleanup deletes a repository location (the bare repo, a
# mirror, a workspace volume), lib/preserve-scan.sh packs everything Git
# keeps there into a bundle, and swarm_recovery_import copies that
# bundle into the checkout under
#   refs/swarm-recovery/<engagement>/<snapshot>/<source>/
# so no commit, object or git-dir file of the location has its only
# copy in what is deleted.  The engine never deletes recovery refs.

SWARM_RECOVERY_NS="refs/swarm-recovery"

# Print a new snapshot id: UTC time and 8 random hex digits.
swarm_recovery_snapshot_id() {
    local rand
    rand=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') \
        || return 1
    [ "${#rand}" -eq 8 ] || return 1
    printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$rand"
}

# Git in the checkout for recovery work: no environment redirection,
# no hooks or fsmonitor, no lazy fetches from promisor remotes.
swarm_recovery_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_NAMESPACE -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
        GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 \
        GIT_GRAFT_FILE=/dev/null \
        git -c core.fsmonitor=false -c core.hooksPath=/dev/null \
        -c fetch.prune=false -c fetch.pruneTags=false \
        -c advice.graftFileDeprecated=false "$@"
}

# Print the device:inode of PATH.  GNU stat takes -c; BSD stat takes
# -f, and GNU stat -f means something else, so the form is chosen once.
swarm_dev_ino() {
    if [ -z "${SWARM_STAT_FORM:-}" ]; then
        if stat -c '%d:%i' / >/dev/null 2>&1; then
            SWARM_STAT_FORM=-c
        else
            SWARM_STAT_FORM=-f
        fi
    fi
    stat "$SWARM_STAT_FORM" '%d:%i' "$1"
}

# Succeed when the checkout at ROOT keeps every object in its own
# store, so objects imported there survive the deletion of TARGETS
# (directories cleanup is about to delete; may be empty).  Refuses a
# shallow or partial clone, alternates, symlinks in the object store,
# an object store inside RUNTIME or a target, and a target that shares
# a directory with the git dir or the checkout's own git dir, or a pack
# file with the object store (bind mounts).
swarm_checkout_storage_ok() {
    local root="$1" runtime="$2"
    shift 2
    local common objects canon t tcanon
    common=$(swarm_recovery_git -C "$root" rev-parse --git-common-dir \
        2>/dev/null) || {
        echo "ERROR: cannot read the git dir of ${root}." >&2
        return 1
    }
    case "$common" in
        /*) ;;
        *) common="$root/$common" ;;
    esac
    objects="$common/objects"
    if [ "$(swarm_recovery_git -C "$root" rev-parse \
            --is-shallow-repository 2>/dev/null)" != false ]; then
        echo "ERROR: ${root} is a shallow clone; recovery needs full" \
             "history (git fetch --unshallow)." >&2
        return 1
    fi
    local names name val partial=""
    partial=$(swarm_recovery_git -C "$root" config --get \
        extensions.partialClone 2>/dev/null) || partial=""
    names=$(swarm_recovery_git -C "$root" config --name-only \
        --get-regexp '^remote\..*\.promisor$' 2>/dev/null) || names=""
    for name in $names; do
        val=$(swarm_recovery_git -C "$root" config --type=bool --get \
            "$name" 2>/dev/null) || val=true
        [ "$val" = false ] || partial=yes
    done
    if [ -n "$partial" ]; then
        echo "ERROR: ${root} is a partial clone; recovery needs every" \
             "object locally." >&2
        return 1
    fi
    if [ -s "$objects/info/alternates" ]; then
        echo "ERROR: ${root} borrows objects (${objects}/info/alternates)." \
             "Run git repack -a -d there, then remove that file." >&2
        return 1
    fi
    # Recovery refs live in the same git dir; they must not be stored
    # through a link into what cleanup deletes either.
    local links
    links=$(find "$objects" "$common/refs" -type l -print) || {
        echo "ERROR: cannot list ${objects} and ${common}/refs." >&2
        return 1
    }
    if [ -n "$links" ] || [ -L "$objects" ] || [ -L "$common" ] \
            || [ -L "$common/refs" ] || [ -L "$common/packed-refs" ] \
            || [ -e "$common/reftable" ]; then
        echo "ERROR: the object store or refs of ${root} contain" \
             "symlinks (or use reftable); make them plain directories" \
             "first." >&2
        return 1
    fi
    local ccanon gcanon x
    if ! canon=$(cd -P "$objects" 2>/dev/null && pwd -P) \
            || ! ccanon=$(cd -P "$common" 2>/dev/null && pwd -P); then
        echo "ERROR: cannot resolve ${common}." >&2
        return 1
    fi
    # The checkout's own git dir as well (a linked worktree's lives apart
    # from the common one).
    if ! gcanon=$(swarm_recovery_git -C "$root" rev-parse \
            --absolute-git-dir 2>/dev/null) \
            || ! gcanon=$(cd -P "$gcanon" 2>/dev/null && pwd -P); then
        echo "ERROR: cannot resolve the git dir of ${root}." >&2
        return 1
    fi
    # Every target, whether or not this host has it (a volume's
    # Mountpoint can be a path in Docker's own machine), may not be
    # the git dir or its object store, nor lie inside or around either.
    for t in "$runtime" "$@"; do
        tcanon=$(swarm_path_resolve "$t") || {
            echo "ERROR: cannot resolve ${t}." >&2
            return 1
        }
        for x in "$ccanon" "$canon" "$gcanon"; do
            case "$x/" in
                "$tcanon"/*)
                    echo "ERROR: the git dir of ${root} is at or inside" \
                         "${t}." >&2
                    return 1 ;;
            esac
            case "$tcanon/" in
                "$x"/*)
                    echo "ERROR: ${t} is inside the git dir of ${root}." >&2
                    return 1 ;;
            esac
        done
    done
    [ "$#" -gt 0 ] || return 0
    # The same directory or pack file seen through a bind mount has the
    # same device and inode under both paths.  Every directory of the
    # checkout's own git dir counts (it is the common one, or a linked
    # worktree's, which lives apart); of the common one, those of the
    # object store and the refs.
    local tmp p rc=0
    tmp=$(mktemp -d) || return 1
    {
        if [ "$gcanon" = "$ccanon" ]; then
            find "$gcanon" -type d -print || rc=1
        else
            find "$objects" "$common/refs" "$gcanon" -type d -print \
                || rc=1
        fi
        for p in "$objects/pack" "$objects/info"; do
            [ ! -d "$p" ] || find "$p" -type f -print || rc=1
        done
        [ ! -f "$common/packed-refs" ] || printf '%s\n' "$common/packed-refs"
    } > "$tmp/mine.paths"
    for t in "$@"; do
        [ -d "$t" ] || continue
        find "$t" \( -type d -o -path '*/objects/pack/*' \
            -o -path '*/objects/info/*' \) -print >> "$tmp/theirs.paths" \
            || rc=1
    done
    : >> "$tmp/theirs.paths"
    for p in mine theirs; do
        while IFS= read -r t; do
            swarm_dev_ino "$t" || rc=1
        done < "$tmp/$p.paths" > "$tmp/$p.ids" || rc=1
        sort -u "$tmp/$p.ids" -o "$tmp/$p.ids" || rc=1
    done
    if [ "$rc" -ne 0 ]; then
        rm -rf "$tmp"
        echo "ERROR: cannot list the git dir of ${root} or what" \
             "cleanup deletes." >&2
        return 1
    fi
    comm -12 "$tmp/mine.ids" "$tmp/theirs.ids" > "$tmp/both" || rc=1
    if [ "$rc" -ne 0 ] || [ -s "$tmp/both" ]; then
        rm -rf "$tmp"
        echo "ERROR: the git dir of ${root} shares files with what" \
             "cleanup deletes (a bind mount?)." >&2
        return 1
    fi
    rm -rf "$tmp"
}

# Copy the scan output in DIR (from lib/preserve-scan.sh) into the
# checkout at ROOT under PREFIX/ and verify it: every ref of the bundle
# exists under PREFIX/ with the same object, and every object of the
# inventory, and everything the new refs reach, is in the checkout.
# PREFIX must hold no refs yet.  Fails without changing anything else.
swarm_recovery_import() {
    local root="$1" dir="$2" prefix="$3" heads got
    case "$prefix" in
        "$SWARM_RECOVERY_NS"/*) ;;
        *) echo "ERROR: not a recovery prefix: ${prefix}" >&2; return 1 ;;
    esac
    if ! got=$(swarm_recovery_git -C "$root" for-each-ref \
            --format='%(refname)' "$prefix/" 2>/dev/null); then
        echo "ERROR: cannot read the refs of ${root}." >&2
        return 1
    fi
    if [ -n "$got" ]; then
        echo "ERROR: ${prefix} already holds refs in ${root}." >&2
        return 1
    fi
    if ! swarm_recovery_git -C "$root" bundle verify "$dir/bundle" \
            >/dev/null 2>&1; then
        echo "ERROR: the bundle in ${dir} does not verify." >&2
        return 1
    fi
    heads=$(swarm_recovery_git -C "$root" bundle list-heads "$dir/bundle" \
        2>/dev/null) || {
        echo "ERROR: cannot list the bundle in ${dir}." >&2
        return 1
    }
    if ! swarm_recovery_git -C "$root" fetch --quiet --no-tags --no-prune \
            --no-write-fetch-head --no-recurse-submodules --no-auto-gc \
            "$dir/bundle" "refs/v/*:${prefix}/*" >/dev/null 2>&1; then
        echo "ERROR: cannot import the bundle in ${dir} into ${root}." >&2
        return 1
    fi
    got=$(swarm_recovery_git -C "$root" for-each-ref \
        --format='%(objectname) %(refname)' "$prefix/" 2>/dev/null \
        | sed "s|^\([0-9a-f]*\) ${prefix}/|\1 refs/v/|" | sort) || got=""
    if [ "$got" != "$(printf '%s\n' "$heads" | sort)" ]; then
        echo "ERROR: the refs imported into ${prefix} do not match the" \
             "bundle." >&2
        return 1
    fi
    # Every object of the inventory must be in the checkout.  The
    # output goes to a file first, so no early exit hides a failure.
    local tmp
    tmp=$(mktemp -d) || return 1
    if [ ! -f "$dir/objects" ] \
            || ! swarm_recovery_git -C "$root" cat-file --batch-check \
                < "$dir/objects" > "$tmp/check" 2>/dev/null \
            || [ "$(wc -l < "$tmp/check")" -ne "$(wc -l < "$dir/objects")" ] \
            || grep ' missing$' "$tmp/check" > "$tmp/missing"; then
        rm -rf "$tmp"
        echo "ERROR: objects of the inventory are missing in ${root}." >&2
        return 1
    fi
    if ! swarm_recovery_git -C "$root" for-each-ref --format='%(objectname)' \
            "$prefix/" > "$tmp/tips" 2>/dev/null \
            || ! swarm_recovery_git -C "$root" rev-list --objects \
                --no-object-names --missing=error --stdin \
                < "$tmp/tips" > "$tmp/reach" 2>/dev/null; then
        rm -rf "$tmp"
        echo "ERROR: history under ${prefix} is incomplete in ${root}." >&2
        return 1
    fi
    # Every inventoried object must hang off the new refs.
    if ! sort -u "$tmp/reach" > "$tmp/want" \
            || ! comm -23 "$dir/objects" "$tmp/want" > "$tmp/outside"; then
        rm -rf "$tmp"
        return 1
    fi
    if [ -s "$tmp/outside" ]; then
        rm -rf "$tmp"
        echo "ERROR: objects of the inventory are not under ${prefix}." >&2
        return 1
    fi
    # Presence is checked here; content is checked once for all imports
    # by swarm_recovery_verify_checkout, before anything is deleted.
    rm -rf "$tmp"
}

# Succeed when every object in the checkout at ROOT has the content its
# name says.  Fetch skips objects the checkout already has, and Git does
# not re-hash objects it reads, so an object stored under the wrong name
# (or two objects with swapped contents) would pass every presence
# check.  git fsck --full re-hashes every loose and packed object.
# Cleanup runs this once after its imports and before it deletes
# anything.  It reads the whole object store, so it takes a while on a
# large repository.
swarm_recovery_verify_checkout() {
    local root="$1" err
    err=$(mktemp) || return 1
    if ! swarm_recovery_git -C "$root" fsck --full --no-dangling \
            --no-progress >/dev/null 2>"$err"; then
        echo "ERROR: git fsck found problems in ${root}; recovery refs" \
             "there cannot be trusted:" >&2
        sed 's/^/  /' "$err" | head -20 >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
}

# Scan the host directory PATH (a bare repo or a mirror: MODE gitdir)
# into the empty directory OUT.  Returns the scanner's status.
swarm_scan_host() {
    local path="$1" out="$2"
    bash "$(dirname "${BASH_SOURCE[0]}")/preserve-scan.sh" gitdir "$path" - \
        "$out"
}

# Run docker ARGS in a process group of its own and wait for it.  A
# Ctrl-C at the terminal then reaches the caller (whose cleanup waits
# for this job: wait with no operand) but not the docker client, which,
# stopped mid-request, can leave the daemon to make a container or an
# image after that cleanup ran.  Its standard input is the caller's,
# or /dev/null when that is a terminal.
swarm_docker_own_group() {
    local rc=0 had_m=false
    case "$-" in
        *m*) had_m=true ;;
    esac
    set -m
    if [ -t 0 ]; then
        docker "$@" < /dev/null &
    else
        docker "$@" &
    fi
    if [ "$had_m" = false ]; then
        set +m
    fi
    wait "$!" || rc=$?
    return "$rc"
}

# More docker run arguments for swarm_scan_volume (retire's helper
# label; cleanup's name and label); empty by default.
SWARM_SCAN_DOCKER_ARGS=()

# Scan workspace volume VOL with image IMAGE (context CONTEXT) into the
# empty directory OUT: the scanner runs in a throwaway container with
# the volume read-only and no network, as root so it can read every
# file, and streams its results back as a tar archive.  MOUNTS (optional,
# one path per line) names the scanned container's other mount points.
swarm_scan_volume() {
    local vol="$1" image="$2" context="$3" out="$4" mounts="${5:-}" rc=0
    swarm_docker_own_group run --rm -i --pull never --network none --user 0 \
        "${SWARM_SCAN_DOCKER_ARGS[@]+"${SWARM_SCAN_DOCKER_ARGS[@]}"}" \
        -e "SWARM_SCAN_MOUNTS=${mounts}" \
        --entrypoint bash \
        --mount "type=volume,src=${vol},dst=/workspace,readonly,volume-nocopy" \
        "$image" -c '
            # The image may be a snapshot of a container with its own
            # files anywhere, so the scratch space is a new directory.
            d=$(mktemp -d) || exit 3
            cat > "$d/scan.sh" || exit 3
            mkdir "$d/out" || exit 3
            bash "$d/scan.sh" worktree /workspace "$1" "$d/out" >&2 || exit $?
            cd "$d/out" || exit 3
            set -- report
            [ ! -f bundle ] || set -- "$@" bundle
            [ ! -f objects ] || set -- "$@" objects
            tar -cf - "$@" || exit 3
        ' scan "$context" \
        < "$(dirname "${BASH_SOURCE[0]}")/preserve-scan.sh" \
        > "$out/scan.tar" || rc=$?
    [ "$rc" -eq 0 ] || return 3
    tar -C "$out" -xf "$out/scan.tar" 2>/dev/null || return 3
    rm -f "$out/scan.tar"
}
