#!/bin/bash
# Inventory one repository location and pack everything Git keeps there
# into a bundle, so cleanup can copy it into the checkout before it
# deletes the location.  Runs on the host for the bare repo and the
# mirrors, and inside a throwaway container (volume mounted read-only)
# for a workspace.  It only reads ROOT.
#
# Usage: preserve-scan.sh worktree ROOT CONTEXT OUT
#        preserve-scan.sh gitdir ROOT - OUT
#        preserve-scan.sh userconfig - - OUT
#        preserve-scan.sh files ROOT FORMAT OUT
#
# worktree: ROOT is a checkout (a workspace) whose repository is
#   ROOT/.git; CONTEXT (full, slim or none) says which deletions under
#   .claude the engine made itself; CONTEXT layer is a checkout in a
#   container's own layer (retire), where no file is the engine's.
# gitdir: ROOT is a repository directory (a bare repo or a mirror).
# files: ROOT is what is left of one that a deletion got part of the way
#   through: every file is stored as a blob, those under objects/
#   whatever their size; FORMAT (sha1 or sha256) is the object format of
#   the repository the bundle is for.
# userconfig: run as a container's user, with its HOME and
#   XDG_CONFIG_HOME, in a snapshot of that container: reports the global
#   and system git config settings that keep repository data outside a
#   workspace, and config files that lie on a mount the snapshot lacks.
# OUT is an empty directory.  On success the scan writes:
#   OUT/report     one line per finding (see below)
#   OUT/bundle     a bundle whose refs are refs/v/<n>/t/<k> (one per
#                  object to keep), refs/v/<n>/f/<k> (one per file of the
#                  git dir) and refs/v/<n>/manifest, refs/v/<n>/files
#   OUT/objects    every object id the bundle must carry, one per line
#   OUT/external-worktrees  (worktree mode, origin retire-volume) the
#                  linked worktrees outside ROOT the scan checked, each
#                  path ended by a NUL; written only at the scan's normal
#                  end with no block reported
# Report lines:
#   empty                          ROOT has no files at all
#   gitdir <n> <path>              a git dir, relative to ROOT
#   block <what> <detail>          content the bundle cannot carry
#   uncommitted <what> <detail>    content outside Git's history that
#                                  only an explicit discard may drop
#   layer-uncommitted <what> <detail>  the same in a linked worktree
#                                  outside ROOT, in the container's layer
#   external-worktree <path>       such a worktree, checked
#   gone-worktree <path>           a worktree registered outside ROOT
#                                  whose directory is not there
#   deferred-worktree <path>       one cleanup's scan leaves to retire
#   layer-link <path>              where a symlink in the volume leads
#                                  out of it (worktree mode, resolved):
#                                  in the image or in the container's
#                                  own layer
#   layer-via <path>               a symlink outside the volume that a
#                                  link in it passes
#   layer-path <path>              any path outside the volume such a
#                                  link visits
# Exit status: 0 when the report is complete, and so are the bundle and
# the object list (except after a block that keeps a worktree scan from
# reading the work tree: a filter driver, an include, an embedded
# repository, a git dir or repository whose path holds a newline, a
# core.worktree outside, a mismatched worktree, a common dir elsewhere,
# a special file among a git dir's own files, a partial clone; the scan
# then stops there, with no bundle); 3 when the scan cannot
# tell (message on stderr).  Compatible with Bash 3.2.

set -euo pipefail

# Git's own environment must not redirect anything this scan reads.
for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$_v"
done
# Replacement objects and grafts would make Git walk parents a commit
# does not have, so objects could look reached that the bundle lacks.
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
# No transport at all, whatever protocol.* a repository sets: a missing
# object must not make Git fetch it from a remote that repository names
# (which, for a local path, runs the remote's uploadpack command).
# GIT_NO_LAZY_FETCH does that from Git 2.45 on; an empty allow-list
# does it on any Git.
export GIT_ALLOW_PROTOCOL=''
export LC_ALL=C

MODE="${1:-}"
ROOT="${2:-}"
CONTEXT="${3:-}"
OUT="${4:-}"
# Who runs the scan (SWARM_SCAN_ORIGIN, set by the caller): retire's scan
# of a container's volume (retire-volume), of a checkout in its layer
# (retire-layer), cleanup's helper passes (cleanup), or anything else
# (other).  Only retire-volume lets a linked worktree outside ROOT
# through (accept_external_worktree).
case "${SWARM_SCAN_ORIGIN:-other}" in
    retire-volume|retire-layer|cleanup) ORIGIN="$SWARM_SCAN_ORIGIN" ;;
    *) ORIGIN=other ;;
esac

# A single file larger than this, or more than TOTAL bytes of files per
# git dir tree, is reported as uncommitted instead of being stored.
# The tests lower them through SWARM_SCAN_FILE_LIMIT/_TOTAL_LIMIT.
FILE_LIMIT="${SWARM_SCAN_FILE_LIMIT:-$((256 * 1024 * 1024))}"
TOTAL_LIMIT="${SWARM_SCAN_TOTAL_LIMIT:-$((2 * 1024 * 1024 * 1024))}"

fail() {
    echo "preserve-scan: $*" >&2
    exit 3
}

case "$MODE" in
    worktree|gitdir|userconfig|files) ;;
    *) fail "unknown mode: ${MODE}" ;;
esac
if [ "$MODE" = worktree ]; then
    case "$CONTEXT" in
        full|slim|none|layer) ;;
        *) fail "unknown context: ${CONTEXT}" ;;
    esac
fi
# Only each repository's own config applies: the global and system
# files of whoever runs the scan (in a container, files its agent could
# write) must not change what Git reports or runs.  userconfig mode
# reads those files on purpose.
if [ "$MODE" != userconfig ]; then
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fi
# Git before 2.32 ignores GIT_CONFIG_GLOBAL: in a container (whose home
# files the agent may have written), no home to read either.  The
# host's own repositories (gitdir mode) keep it, so that an include of
# ~/... in their config resolves as Git resolves it.
if [ "$MODE" = worktree ]; then
    export HOME="${OUT:-/nonexistent}/.no-home" \
        XDG_CONFIG_HOME="${OUT:-/nonexistent}/.no-home"
fi
[ "$MODE" = userconfig ] || [ -d "$ROOT" ] || fail "not a directory: ${ROOT}"
[ -d "$OUT" ] || fail "not a directory: ${OUT}"

# The shell's read ends a loop at a read error just as at the end of
# its list, so a scan could miss what the rest of a list holds.  This
# read stops the scan instead; an error is all the builtin writes to
# standard error here.  (In canon_nm, which runs in a subshell, the
# failure reaches its callers as a path that does not resolve, which
# they report as a block.)
# shellcheck disable=SC2329,SC2162  # called by every loop below, and
# every caller passes its own options (-r among them)
read() {
    local __rc=0
    builtin read "$@" 2> "$OUT/.read-err" || __rc=$?
    if [ -s "$OUT/.read-err" ]; then
        fail "cannot read a list: $(cat "$OUT/.read-err")"
    fi
    return "$__rc"
}
# Print the resolved form of directory $1.  Command substitution would
# drop trailing newlines and turn "repo<LF>" into "repo", so the x keeps
# them; a path with a newline anywhere fails (the scan's lists are
# line-based).
canon() {
    local r
    r=$(cd -P "$1" 2>/dev/null && pwd -P && printf x) || return 1
    r="${r%x}"
    r="${r%$'\n'}"
    case "$r" in
        *$'\n'*) return 1 ;;
    esac
    printf '%s' "$r"
}

# Succeed when path $1 is a directory on the way to ROOT (/tmp and
# /tmp/fixture for ROOT /tmp/fixture/repo): resolving a path inside ROOT
# visits them, and they hold nothing ROOT depends on.  ROOT is canonical
# (resolved), so none of them is a link.  For ROOT /workspace there are
# none.
on_the_way_to_root() {
    case "$ROOT/" in
        "$1"/*) return 0 ;;
    esac
    return 1
}

# Print what Git reads from pointer file $1 (a commondir, a gitfile):
# the whole file with its trailing CR and LF dropped, as Git reads it.
# Fails when a CR or LF is left inside (Git would keep it and go
# elsewhere than this scan's line-based lists say) or the file cannot
# be read.
read_pointer() {
    local v
    v=$(cat "$1" && printf x) || return 1
    v="${v%x}"
    while :; do
        case "$v" in
            *$'\n'|*$'\r') v="${v%?}" ;;
            *) break ;;
        esac
    done
    case "$v" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    printf '%s' "$v"
}

# Print file $1, which must hold one line: its content with one final LF
# dropped.  Fails when anything else is left (another line, a CR) or the
# file is empty or cannot be read.
read_one_line() {
    local v
    v=$(cat "$1" && printf x) || return 1
    v="${v%x}"
    v="${v%$'\n'}"
    case "$v" in
        ''|*$'\n'*|*$'\r'*) return 1 ;;
    esac
    printf '%s' "$v"
}

# Print path $1 on one line, newlines shown as \n.
oneline() {
    printf '%s' "$1" | awk 'BEGIN { ORS = "\\n" } { print }' \
        | sed 's/\\n$//'
}

# Succeed when file $1 holds a NUL byte, or cannot be read.  Git stops
# reading a path at a NUL, while the shell's read drops it and carries
# on, so the two would disagree on what such a file names.
has_nul() {
    local all kept
    all=$(wc -c 2>/dev/null < "$1" | tr -d ' ') || return 0
    kept=$(tr -d '\000' 2>/dev/null < "$1" | wc -c | tr -d ' ') || return 0
    [ -n "$all" ] && [ "$all" = "$kept" ] && return 1
    return 0
}

# Print where absolute path $1 leads, resolved the way the kernel does:
# components from the left, a symlink replaced by its target before any
# later ".." applies, "." dropped; components that do not exist here
# are kept as text (they may exist only where the link was made).  In
# worktree mode the scan runs from a snapshot of the stopped container
# itself (retire commits it), so the links on the way are that
# container's own.  Every symlink passed is appended to file $2, and
# every path visited (links or not) to file $3, when given.  Fails (1)
# after 40 links (a loop), and (2) at a name with a newline, which the
# line-based lists here cannot hold.
real_path() {
    local rest="${1#/}" out="" comp n=0 t via="${2:-/dev/null}"
    local seen="${3:-/dev/null}"
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$comp" in
            ''|.) continue ;;
            ..) out="${out%/*}"; continue ;;
            *$'\n'*) return 2 ;;
        esac
        # Every path visited, before any later ".." takes it back.
        printf '%s\n' "${out}/${comp}" >> "$seen"
        if [ -L "${out}/${comp}" ]; then
            n=$((n + 1))
            [ "$n" -le 40 ] || return 1
            printf '%s\n' "${out}/${comp}" >> "$via"
            t=$(readlink -n "${out}/${comp}" && printf x) || return 1
            t="${t%x}"
            case "$t" in
                /*) out="" ; t="${t#/}" ;;
            esac
            if [ -n "$rest" ]; then rest="${t}/${rest}"; else rest="$t"; fi
            continue
        fi
        out="${out}/${comp}"
    done
    printf '%s' "${out:-/}"
}

# Git records worktree paths resolved; compare against the same form.
if [ "$MODE" != userconfig ]; then
    ROOT=$(canon "$ROOT") \
        || fail "cannot resolve ${2:-}, or it holds a newline"
fi
_entries=$(ls -A "$OUT") || fail "cannot list ${OUT}"
[ -z "$_entries" ] || fail "output directory is not empty: ${OUT}"

ERR="$OUT/.err"
REPORT="$OUT/report"
SCRATCH="$OUT/scratch.git"
: > "$REPORT"

# Run git on git dir $1 with the settings every read here needs, and
# fail the scan on a non-zero exit or on anything it writes to stderr.
# The excludes and attributes files Git reads by default from the
# runner's home (~/.config/git) are not the repository's: they are
# turned off like the rest of the global config.
g() {
    local dir="$1"
    shift
    if ! git --git-dir="$dir" -c safe.directory='*' \
            -c core.excludesFile=/dev/null -c core.attributesFile=/dev/null \
            -c core.fsmonitor=false -c core.untrackedCache=false \
            -c advice.graftFileDeprecated=false --no-optional-locks \
            "$@" 2>"$ERR"; then
        fail "git $* in ${dir} failed: $(cat "$ERR")"
    fi
    [ ! -s "$ERR" ] || fail "git $* in ${dir}: $(cat "$ERR")"
}

# The same for a work tree $1 whose git dir Git finds itself.  A file
# whose content changed is found by its stat data: its ctime too, which
# no tool can put back, whatever the repository's config says.
gw() {
    local dir="$1"
    shift
    if ! git -C "$dir" -c safe.directory='*' \
            -c core.excludesFile=/dev/null -c core.attributesFile=/dev/null \
            -c core.fsmonitor=false -c core.untrackedCache=false \
            -c core.trustctime=true -c core.checkStat=default \
            -c advice.graftFileDeprecated=false --no-optional-locks \
            "$@" 2>"$ERR"; then
        fail "git $* in ${dir} failed: $(cat "$ERR")"
    fi
    [ ! -s "$ERR" ] || fail "git $* in ${dir}: $(cat "$ERR")"
}

# A write that fails ends the scan, also where a caller tests the
# result (errexit does not apply there).
report() {
    printf '%s\n' "$*" >> "$REPORT" || fail "cannot write the report"
}

# git config on the file that -f names, and on nothing else: no
# repository looked for around the current directory (the workspace's
# own, where the helper runs the scan), no global or system file (Git
# reads those first, includes and all, whatever -f names).
cfg() {
    GIT_DIR="$OUT/.no-repository" GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null HOME="$OUT/.no-home" \
        XDG_CONFIG_HOME="$OUT/.no-home" git config "$@"
}

# Run a command, killing it once SWARM_SCAN_GIT_TIMEOUT seconds (default
# 30) have passed; OUT/.timed-out then says so.  The watchdog stops at
# its next tick once the command has ended.
bounded() {
    local secs="${SWARM_SCAN_GIT_TIMEOUT:-30}" pid wpid rc=0
    rm -f "$OUT/.timed-out" "$OUT/.bounded-done"
    "$@" &
    pid=$!
    (
        i=0
        while [ "$i" -lt "$secs" ]; do
            sleep 1
            [ ! -e "$OUT/.bounded-done" ] || exit 0
            i=$((i + 1))
        done
        : > "$OUT/.timed-out"
        kill -9 "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wpid=$!
    wait "$pid" || rc=$?
    : > "$OUT/.bounded-done"
    wait "$wpid" 2>/dev/null || true
    return "$rc"
}

# Print the size of file $1 in bytes.
fsize() {
    wc -c < "$1" | tr -d ' '
}

# canon, for paths the repository's own settings name (core.worktree,
# commondir, alternates, gitfiles, worktree back-pointers): also fails
# when resolving the path visits one of the mounts the snapshot lacks
# ($OUT/.mounts, worktree mode), since there it may lead elsewhere in
# the container, and reports the links it passes outside ROOT as
# layer-via (the container may have made them).
canon_nm() {
    local v m
    : > "$OUT/.cnm"
    : > "$OUT/.cnv"
    real_path "$1" "$OUT/.cnv" "$OUT/.cnm" >/dev/null || return 1
    # Links outside ROOT on the way are the container's to tell about:
    # report them for retire's comparison with docker diff.
    while IFS= read -r v; do
        case "$v" in
            "$ROOT"|"$ROOT"/*) ;;
            *) report "layer-via $(oneline "$v")" ;;
        esac
    done < "$OUT/.cnv"
    while IFS= read -r v; do
        case "$v" in
            "$ROOT"|"$ROOT"/*) ;;
            *) on_the_way_to_root "$v" \
                   || report "layer-path $(oneline "$v")" ;;
        esac
    done < "$OUT/.cnm"
    if [ -s "$OUT/.mounts" ]; then
        while IFS= read -r v; do
            while IFS= read -r m; do
                [ -n "$m" ] || continue
                case "$v" in
                    "$m"|"$m"/*) return 1 ;;
                esac
            done < "$OUT/.mounts"
        done < "$OUT/.cnm"
    fi
    canon "$1"
}

# ---- Linked worktrees outside ROOT --------------------------------------

# Succeed when path $1 is at, or below, an entry of the scan's mount set
# (OUT/.mounts: the container's other mount points, as configured and as
# resolved).
in_mount_set() {
    local m
    [ -s "$OUT/.mounts" ] || return 1
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        case "$1" in
            "$m"|"$m"/*) return 0 ;;
        esac
    done < "$OUT/.mounts"
    return 1
}

# Succeed when an entry of the scan's mount set is at, or below, $1.
mount_below() {
    local m
    [ -s "$OUT/.mounts" ] || return 1
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        case "$m" in
            "$1"|"$1"/*) return 0 ;;
        esac
    done < "$OUT/.mounts"
    return 1
}

# Succeed when $1 is an absolute path with no empty, "." or ".."
# component, no component longer than 255 bytes and no trailing slash.
normalized_abs() {
    local rest comp
    case "$1" in
        /) return 0 ;;
        /*/|//*) return 1 ;;
        /*) ;;
        *) return 1 ;;
    esac
    rest="${1#/}"
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$comp" in
            ''|.|..) return 1 ;;
        esac
        [ "${#comp}" -le 255 ] || return 1
    done
    return 0
}

# Print yes when directory $1 holds an entry named $2 (one component),
# no when a whole listing of $1 has none; fail when $1 cannot be listed.
# A stat that fails does not say why; a listing that works and lacks the
# name shows that it is not there.
dir_has_entry() {
    local pat
    pat=$(printf '%s' "$2" | sed 's/[][*?\\]/\\&/g') || return 1
    : > "$OUT/.entry-err"
    find "$1" -mindepth 1 -maxdepth 1 -name "$pat" -print \
        2>"$OUT/.entry-err" > "$OUT/.entry" || return 1
    [ ! -s "$OUT/.entry-err" ] || return 1
    if [ -s "$OUT/.entry" ]; then echo yes; else echo no; fi
}

# Where the normalized absolute directory $1 stands, walked from / one
# component at a time.  Sets WT_STATE to "absent" when a component does
# not exist (every one before it being a directory that is not a link,
# in a parent this scan can search), or "present" when $1 is such a
# directory itself.  Fails, with WT_WHY set, when a component is a link
# or not a directory, a parent cannot be searched (inspection is not
# absence), or $1 is at or below a mount of the scan's mount set.
WT_STATE=""
WT_WHY=""
worktree_dir_state() {
    local rest="${1#/}" p="" comp parent
    WT_STATE=""
    WT_WHY=""
    if in_mount_set "$1"; then
        WT_WHY="under a mount"
        return 1
    fi
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        parent="${p:-/}"
        p="${p}/${comp}"
        if [ ! -x "$parent" ]; then
            WT_WHY="cannot inspect $(oneline "$parent")"
            return 1
        fi
        if [ -L "$p" ]; then
            WT_WHY="a link on the way: $(oneline "$p")"
            return 1
        fi
        if [ ! -e "$p" ]; then
            # Absent only when a listing of the parent says so.
            case "$(dir_has_entry "$parent" "$comp")" in
                no)
                    WT_STATE=absent
                    return 0 ;;
                yes) WT_WHY="cannot inspect $(oneline "$p")" ;;
                *) WT_WHY="cannot inspect $(oneline "$parent")" ;;
            esac
            return 1
        fi
        if [ ! -d "$p" ]; then
            WT_WHY="not a directory on the way: $(oneline "$p")"
            return 1
        fi
    done
    WT_STATE=present
}

# Report a block for the linked worktree at $1 (why: $2) and fail.
external_refused() {
    report "block external $(oneline "$1") ($2)"
    return 1
}

# Check the linked worktree at $1, present outside ROOT in the
# container's own layer and registered by admin dir $2, before Git reads
# anything there: no mount at or below it, no file that is not a regular
# file, a directory or a link, no repository inside but its own .git, a
# .git that is a regular file naming $2 back, and links that resolve
# inside it (past its own ancestors only, never through a mount).  Then
# queue it for check_checkout under its absolute path (whose findings are
# layer-uncommitted) and record it.  Reports a block and fails otherwise.
accept_external_worktree() {
    local dir="$1" d="$2" p n v t sz
    [ "$dir" != / ] || external_refused / "a worktree at the root"         || return 1
    if mount_below "$dir"; then
        external_refused "$dir" "a mount inside it"
        return 1
    fi
    find "$dir" -xdev \( \( ! -type f ! -type d ! -type l \) -o -name .git \
        -o \( -name HEAD \( -type f -o -type l \) \) \) -print0 \
        2>"$ERR" > "$OUT/.ext-find" || fail "cannot list $(oneline "$dir")"
    [ ! -s "$ERR" ] || fail "cannot list $(oneline "$dir"): $(cat "$ERR")"
    while IFS= read -r -d '' p; do
        if [ ! -L "$p" ] && [ -e "$p" ] && [ ! -f "$p" ] && [ ! -d "$p" ]
        then
            external_refused "$dir" "a special file: $(oneline "$p")"
            return 1
        fi
        case "$p" in
            "$dir/.git") ;;
            */.git)
                external_refused "$dir" "a repository inside: $(oneline "$p")"
                return 1 ;;
            */HEAD)
                n="${p%/HEAD}"
                if [ -d "$n/objects" ] || [ -f "$n/commondir" ]; then
                    external_refused "$dir" "a repository inside: $(oneline "$n")"
                    return 1
                fi ;;
        esac
    done < "$OUT/.ext-find"
    if [ -L "$dir/.git" ] || [ ! -f "$dir/.git" ]; then
        external_refused "$dir" "its .git is not a file"
        return 1
    fi
    sz=$(wc -c < "$dir/.git" | tr -d ' ') || sz=-1
    if [ "$sz" -lt 0 ] || [ "$sz" -gt 4096 ] || has_nul "$dir/.git"; then
        external_refused "$dir" "its .git cannot be read as a gitfile"
        return 1
    fi
    if ! v=$(read_one_line "$dir/.git"); then
        external_refused "$dir" "its .git cannot be read as a gitfile"
        return 1
    fi
    case "$v" in
        "gitdir: /"*) v="${v#gitdir: }" ;;
        "gitdir: "*)
            external_refused "$dir" "its .git names a relative git dir"
            return 1 ;;
        *)
            external_refused "$dir" "its .git cannot be read as a gitfile"
            return 1 ;;
    esac
    if [ "$v" != "$d" ]; then
        external_refused "$dir" "its .git names another git dir"
        return 1
    fi
    find "$dir" -xdev -type l -print0 2>"$ERR" > "$OUT/.ext-links" \
        || fail "cannot list $(oneline "$dir")"
    [ ! -s "$ERR" ] || fail "cannot list $(oneline "$dir"): $(cat "$ERR")"
    while IFS= read -r -d '' p; do
        : > "$OUT/.ext-via"
        : > "$OUT/.ext-seen"
        if ! t=$(real_path "$p" "$OUT/.ext-via" "$OUT/.ext-seen" \
                && printf x); then
            external_refused "$dir" "a link out: $(oneline "$p")"
            return 1
        fi
        t="${t%x}"
        case "$t" in
            "$dir"/*) ;;
            *)
                external_refused "$dir" "a link out: $(oneline "$p")"
                return 1 ;;
        esac
        while IFS= read -r v; do
            case "$v" in
                "$dir"/*) ;;
                *)
                    external_refused "$dir" "a link out: $(oneline "$p")"
                    return 1 ;;
            esac
        done < "$OUT/.ext-via"
        while IFS= read -r v; do
            # Its own ancestors are on the way to it, and were walked.
            case "$v" in
                "$dir"|"$dir"/*) ;;
                *)
                    case "$dir/" in
                        "$v"/*) ;;
                        *)
                            external_refused "$dir" "a link out: $(oneline "$p")"
                            return 1 ;;
                    esac ;;
            esac
            if in_mount_set "$v"; then
                external_refused "$dir" "a link through a mount: $(oneline "$p")"
                return 1
            fi
        done < "$OUT/.ext-seen"
    done < "$OUT/.ext-links"
    queue_checkout "$dir" "$dir" "$d"
    report "external-worktree $(oneline "$dir")"
    printf '%s\0' "$dir" >> "$OUT/.external-worktrees" \
        || fail "cannot record the linked worktree $(oneline "$dir")"
}

# ---- Files and bundle (gitdir, worktree and files modes) ----------------

# Write to OUT/.fkeep, NUL-separated, every path under directory TOP
# that is not a directory, except those listed in file EXEMPT (one per
# line).  Paths are read NUL-separated, so any byte in a name survives;
# a path with a newline in it is never exempt (exempt names are hex).
list_files() {
    local top="$1" exempt="$2" f
    : > "$OUT/.flist"
    : > "$OUT/.fnl"
    find "$top" ! -type d -print0 2>"$ERR" > "$OUT/.flist0" \
        || fail "cannot list ${top}"
    [ ! -s "$ERR" ] || fail "cannot list ${top}: $(cat "$ERR")"
    while IFS= read -r -d '' f; do
        case "$f" in
            *$'\n'*) printf '%s\0' "$f" >> "$OUT/.fnl" ;;
            *) printf '%s\n' "$f" >> "$OUT/.flist" ;;
        esac
    done < "$OUT/.flist0"
    sort "$OUT/.flist" -o "$OUT/.flist"
    comm -23 "$OUT/.flist" "$exempt" | tr '\n' '\0' > "$OUT/.fkeep"
    cat "$OUT/.fnl" >> "$OUT/.fkeep"
}

# Store every path of OUT/.fkeep (under TOP) in SCRATCH: a symlink as
# its target string, a regular file as its bytes, each as a blob
# referenced by refs/v/<ID>/f/<k>, with the list "<k> <mode> <size>
# <path>" (NUL-terminated, paths relative to TOP) as refs/v/<ID>/files.
# A file over the size limits is reported as uncommitted instead, unless
# its path relative to TOP starts with ALWAYS/ (files mode keeps
# objects/ whatever its size); such files do not count toward the total,
# which TOTAL_USED keeps across every call of one scan.  Any other kind
# of file fails the scan.
TOTAL_USED=0
store_files() {
    local top="$1" always="$2" id="$3" f rel target blob size mode files
    local keep k=0
    : > "$OUT/.files"
    : > "$OUT/.fupd"
    while IFS= read -r -d '' f; do
        rel="${f#"$top"/}"
        if [ -L "$f" ]; then
            # readlink -n prints the target as is; the x keeps a
            # trailing newline of the target from command substitution.
            target=$(readlink -n "$f" && printf x) \
                || fail "cannot read ${f}"
            target="${target%x}"
            k=$((k + 1))
            blob=$(printf '%s' "$target" \
                | git --git-dir="$SCRATCH" hash-object -w --stdin) \
                || fail "cannot store ${f}"
            printf 'update refs/v/%s/f/%s %s\n' "$id" "$k" "$blob" \
                >> "$OUT/.fupd"
            printf '%s 120000 0 %s\0' "$k" "$rel" >> "$OUT/.files"
            continue
        fi
        [ -f "$f" ] || fail "special file: ${f}"
        size=$(fsize "$f") || fail "cannot read ${f}"
        keep=no
        if [ -n "$always" ]; then
            case "$rel" in
                "$always"/*) keep=yes ;;
            esac
        fi
        if [ "$keep" = no ]; then
            if [ "$size" -gt "$FILE_LIMIT" ] \
                    || [ $((TOTAL_USED + size)) -gt "$TOTAL_LIMIT" ]; then
                report "uncommitted large-file ${f#"$ROOT"/} ${size}"
                continue
            fi
            TOTAL_USED=$((TOTAL_USED + size))
        fi
        k=$((k + 1))
        blob=$(git --git-dir="$SCRATCH" hash-object -w --no-filters --stdin \
            < "$f") || fail "cannot store ${f}"
        mode=100644
        [ ! -x "$f" ] || mode=100755
        printf 'update refs/v/%s/f/%s %s\n' "$id" "$k" "$blob" >> "$OUT/.fupd"
        printf '%s %s %s %s\0' "$k" "$mode" "$size" "$rel" >> "$OUT/.files"
    done < "$OUT/.fkeep"
    git --git-dir="$SCRATCH" update-ref --stdin < "$OUT/.fupd" 2>"$ERR" \
        || fail "cannot record the files of ${top}: $(cat "$ERR")"
    files=$(git --git-dir="$SCRATCH" hash-object -w --stdin \
        < "$OUT/.files") || fail "cannot write the file list of ${top}"
    git --git-dir="$SCRATCH" update-ref "refs/v/$id/files" "$files"
}

make_bundle() {
    git --git-dir="$SCRATCH" -c safe.directory='*' bundle create \
        "$OUT/bundle" --all >/dev/null 2>"$ERR" \
        || fail "cannot create the bundle: $(cat "$ERR")"
}

# ---- files mode -----------------------------------------------------------

# A remnant that is no longer a git dir (a deletion got part of the
# way): every file under ROOT is stored, with no history to inventory.
# Files under objects/ are stored whatever their size: they may hold
# history no earlier snapshot has.  CONTEXT is the object format of the
# repository the bundle goes into (sha1 or sha256).
if [ "$MODE" = files ]; then
    case "$CONTEXT" in
        sha1|sha256) ;;
        *) fail "files mode needs the object format, sha1 or sha256" ;;
    esac
    git init -q --bare --object-format="$CONTEXT" "$SCRATCH" \
        || fail "cannot create ${SCRATCH}"
    : > "$OUT/objects"
    : > "$OUT/.exempt"
    list_files "$ROOT" "$OUT/.exempt"
    store_files "$ROOT" objects 0
    make_bundle
    exit 0
fi

# ---- userconfig mode ----------------------------------------------------

if [ "$MODE" = userconfig ]; then
    # The mounts the snapshot lacks: the container's own
    # (SWARM_SCAN_MOUNTS) and those Docker makes in every container.
    # /workspace too: this check runs without the volume.  Each mount
    # counts as configured and as resolved here.
    printf '%s\n' "${SWARM_SCAN_MOUNTS:-}" /workspace /dev /proc /sys \
        /etc/hosts /etc/hostname /etc/resolv.conf | grep '^/' \
        > "$OUT/.um0" || : > "$OUT/.um0"
    cp "$OUT/.um0" "$OUT/.um"
    while IFS= read -r m; do
        mr=$(real_path "$m" && printf x) || fail "cannot resolve mount ${m}"
        printf '%s\n' "${mr%x}" >> "$OUT/.um"
    done < "$OUT/.um0"
    # The files Git reads for its global settings, worked out here as
    # Git does (XDG_CONFIG_HOME, else HOME/.config; then HOME): git
    # would read them before it named them.  The system file is named
    # by git var, run with no global file and no repository, and within
    # a time limit (it reads that file first): a git built with another
    # prefix reads it elsewhere than /etc/gitconfig.  A git that cannot
    # name it (older than 2.42, stopped by a file it cannot parse, or
    # out of time) is refused, with its first message.
    : > "$OUT/.uf"
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s\n' "$XDG_CONFIG_HOME/git/config" >> "$OUT/.uf"
    elif [ "${HOME+set}" = set ]; then
        printf '%s\n' "$HOME/.config/git/config" >> "$OUT/.uf"
    fi
    [ "${HOME+set}" != set ] || printf '%s\n' "$HOME/.gitconfig" >> "$OUT/.uf"
    : > "$OUT/.ue"
    if ! bounded env HOME="$OUT/.no-home" XDG_CONFIG_HOME="$OUT/.no-home" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_DIR="$OUT/.no-repository" \
            git var GIT_CONFIG_SYSTEM >> "$OUT/.uf" 2>"$OUT/.ue" \
            || [ -s "$OUT/.ue" ]; then
        if [ -e "$OUT/.timed-out" ]; then
            report "block config-paths-unknown (git var did not answer in time)"
        else
            report "block config-paths-unknown $(oneline "$(head -n 1 "$OUT/.ue")")"
        fi
        exit 0
    fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            /*) ;;
            *) report "block config-path ${f}"; continue ;;
        esac
        : > "$OUT/.us"
        rp_rc=0
        r=$(real_path "$f" /dev/null "$OUT/.us" && printf x) || rp_rc=$?
        if [ "$rp_rc" -ne 0 ]; then
            report "block config-path $(oneline "$f")"
            continue
        fi
        r="${r%x}"
        printf '%s\n' "$r" >> "$OUT/.us"
        on_mount=""
        while IFS= read -r v; do
            while IFS= read -r m; do
                case "$v" in
                    "$m"|"$m"/*) on_mount="$m" ;;
                esac
            done < "$OUT/.um"
        done < "$OUT/.us"
        if [ -n "$on_mount" ]; then
            report "block config-on-mount $(oneline "$f") ${on_mount}"
            continue
        fi
        # A missing file is fine only when its nearest existing
        # directory can be searched (else "missing" may be a permission
        # error); an existing file must be readable, and git must read
        # it without a word on stderr.
        if [ ! -e "$r" ] && [ ! -L "$r" ]; then
            pdir=$(dirname "$r")
            while [ ! -e "$pdir" ] && [ "$pdir" != / ]; do
                pdir=$(dirname "$pdir")
            done
            if [ -d "$pdir" ] && [ -x "$pdir" ]; then
                continue
            fi
            report "block config-unreadable $(oneline "$f")"
            continue
        fi
        if [ ! -f "$r" ] || [ ! -r "$r" ]; then
            report "block config-unreadable $(oneline "$f")"
            continue
        fi
        rc=0
        cfg -f "$r" --name-only --get-regexp \
            '^(lfs\.storage|core\.worktree|core\.hookspath|include\..*|includeif\..*)$' \
            > "$OUT/.uk" 2>"$OUT/.ue" || rc=$?
        if [ -s "$OUT/.ue" ]; then
            report "block config-unreadable $(oneline "$f"): $(oneline "$(head -n 1 "$OUT/.ue")")"
            continue
        fi
        case "$rc" in
            0) report "block config-setting $(oneline "$f") $(tr '\n' ' ' < "$OUT/.uk")" ;;
            1) ;;
            *) report "block config-unreadable $(oneline "$f")" ;;
        esac
    done < "$OUT/.uf"
    exit 0
fi

# ---- Find the git dirs --------------------------------------------------

# A git dir is a directory with HEAD and either an objects/ directory
# (a repository) or a commondir file (a linked worktree's git dir).
# Every one under TOP is listed, at any depth, whatever its name (a
# submodule can be called logs or refs): module repos under modules/,
# worktree dirs under worktrees/, and modules of worktrees.  HEAD may be
# a symlink (core.preferSymlinkRefs).  The HEAD files Git keeps
# elsewhere (logs/HEAD) sit in directories that have neither objects/
# nor commondir.
list_gitdirs() {
    local top="$1" head d
    find "$top" \( -type f -o -type l \) -name HEAD -print0 2>"$ERR" \
        > "$OUT/.heads" || fail "cannot list ${top}"
    [ ! -s "$ERR" ] || fail "cannot list ${top}: $(cat "$ERR")"
    while IFS= read -r -d '' head; do
        d="${head%/HEAD}"
        [ -d "$d/objects" ] || [ -f "$d/commondir" ] || continue
        # The git dir list is line-based; a git dir whose path holds a
        # newline is reported instead of listed (its name is shown with
        # the newlines as \n).  Unchecked, it keeps git status from
        # running (a submodule's status would use its config).
        case "$d" in
            *$'\n'*)
                report "block newline-path $(printf '%s' "${d#"$ROOT"/}" \
                    | awk 'BEGIN { ORS = "\\n" } { print }')"
                UNCHECKED_REPO=yes
                continue ;;
        esac
        printf '%s\n' "$d"
    done < "$OUT/.heads"
}

# ---- The container's other mounts (worktree mode) -----------------------

# Checked first: an empty volume or one without a repository still
# must not be hidden or reached by another mount.
: > "$OUT/.mounts"
if [ "$MODE" = worktree ]; then
    # The container's other mounts (SWARM_SCAN_MOUNTS, one destination
    # per line, from retire), as configured and as resolved here: the
    # snapshot has neither their contents nor the links inside them, so
    # any path a link visits at or below one blocks.
    if [ -n "${SWARM_SCAN_MOUNTS:-}" ]; then
        printf '%s\n' "$SWARM_SCAN_MOUNTS" | grep '^/' > "$OUT/.mounts-lit" \
            || : > "$OUT/.mounts-lit"
        # Each destination as configured and as resolved here, tagged
        # with the configured one: "<configured><TAB><form>".
        : > "$OUT/.mounts-forms"
        while IFS= read -r om; do
            omr=$(real_path "$om" && printf x) \
                || fail "cannot resolve mount ${om}"
            omr="${omr%x}"
            printf '%s\t%s\n%s\t%s\n' "$om" "$om" "$om" "$omr" \
                >> "$OUT/.mounts-forms"
        done < "$OUT/.mounts-lit"
        while IFS= read -r m; do
            case "$m" in
                /*) ;;
                *) continue ;;
            esac
            printf '%s\n' "$m" >> "$OUT/.mounts"
            # The container made this mount after the others, through
            # whatever they hold; the snapshot has none of that, so a
            # destination whose path passes through another mount cannot
            # be resolved here.
            : > "$OUT/.mseen"
            mr=$(real_path "$m" /dev/null "$OUT/.mseen" && printf x) \
                || fail "cannot resolve mount ${m}"
            # Any path visited at, or below, another mount (as configured
            # or as resolved) means the destination goes through it.
            while IFS= read -r ms; do
                while IFS="$(printf '\t')" read -r om of; do
                    [ "$om" != "$m" ] || continue
                    case "$ms" in
                        "$of"|"$of"/*)
                            report "block mount-through-mount $(oneline "$m") $(oneline "$om")" ;;
                    esac
                done < "$OUT/.mounts-forms"
            done < "$OUT/.mseen"
            mr="${mr%x}"
            [ "$mr" = "$m" ] || printf '%s\n' "$mr" >> "$OUT/.mounts"
            # A mount that lands in the volume (through a link on its
            # path) hides part of it in the container; one that holds the
            # volume is not this layout either.
            for mm in "$m" "$mr"; do
                case "$mm" in
                    "$ROOT"|"$ROOT"/*)
                        report "block mount-in-workspace $(oneline "$m")" ;;
                esac
                case "$ROOT" in
                    "$mm"/*)
                        report "block mount-around-workspace $(oneline "$m")" ;;
                esac
            done
        done <<EOF_MOUNTS
${SWARM_SCAN_MOUNTS}
EOF_MOUNTS
    fi
fi

# ---- Worktree-mode checks -----------------------------------------------

TOP=""
if [ "$MODE" = worktree ]; then
    # Find prints one x per entry, whatever bytes the names hold.
    _entries=$(find "$ROOT" -mindepth 1 -maxdepth 1 -exec printf x \;) \
        || fail "cannot list ${ROOT}"
    if [ -z "$_entries" ]; then
        report "empty"
        exit 0
    fi
    if [ -L "$ROOT/.git" ]; then
        report "block gitlink ${ROOT}/.git is a symlink"
        exit 0
    fi
    if [ ! -e "$ROOT/.git" ]; then
        report "block nogit files without a repository in ${ROOT}"
        exit 0
    fi
    [ -d "$ROOT/.git" ] || {
        report "block gitfile ${ROOT}/.git is not a directory"
        exit 0
    }
    TOP="$ROOT/.git"
else
    TOP="$ROOT"
    [ -f "$TOP/HEAD" ] || fail "not a git dir: ${TOP}"
fi

# Set when a git dir or a repository below ROOT cannot be checked (its
# path holds a newline): git status must not run then.
UNCHECKED_REPO=""

# The trees of git dirs this scan carries (TOPS): TOP and, in worktree
# mode, the .git directory of every repository nested in the checkout,
# at any depth (a clone or a git init there), each checked and carried
# the way TOP is.  find lists every .git below ROOT without looking
# inside one, so no git dir's own files are taken for another
# repository.  A .git that is a real directory holding a repository
# (HEAD, objects/, not bare) is a TOP; .git files (the pointers of
# submodules and linked worktrees) are resolved further on, once every
# git dir is listed, and any other .git is reported there.
TOPS="$OUT/.tops"
printf '%s\n' "$TOP" > "$TOPS"
: > "$OUT/.markers"
if [ "$MODE" = worktree ]; then
    find "$ROOT" -name .git -print0 -prune 2>"$ERR" > "$OUT/.markers" \
        || fail "cannot list ${ROOT}"
    [ ! -s "$ERR" ] || fail "cannot list ${ROOT}: $(cat "$ERR")"
    : > "$OUT/.tops-n"
    while IFS= read -r -d '' e; do
        [ "$e" != "$TOP" ] || continue
        case "$e" in
            *$'\n'*) continue ;;
        esac
        [ -d "$e" ] && [ ! -L "$e" ] || continue
        [ -d "$e/objects" ] && [ ! -L "$e/objects" ] || continue
        [ -f "$e/HEAD" ] || [ -L "$e/HEAD" ] || continue
        if [ -f "$e/config" ]; then
            rc=0
            bare=$(cfg -f "$e/config" --bool --get core.bare \
                2>/dev/null) || rc=$?
            case "$rc" in
                0) [ "$bare" != true ] || continue ;;
                1) ;;
                *) fail "cannot parse ${e}/config" ;;
            esac
        fi
        printf '%s\n' "$e" >> "$OUT/.tops-n"
    done < "$OUT/.markers"
    sort "$OUT/.tops-n" >> "$TOPS"
fi
# Succeed when path $1 is one of the TOPS or inside one.
in_a_top() {
    local t
    while IFS= read -r t; do
        case "$1" in
            "$t"|"$t"/*) return 0 ;;
        esac
    done < "$TOPS"
    return 1
}
GITDIRS="$OUT/.gitdirs"
: > "$GITDIRS"
while IFS= read -r t; do
    list_gitdirs "$t" >> "$GITDIRS"
    grep -qxF -- "$t" "$GITDIRS" || printf '%s\n' "$t" >> "$GITDIRS"
done < "$TOPS"

# No file in a git dir may be a special file: Git opens many of them
# (HEAD, config, the index, packed-refs, info/exclude, pack indexes,
# the commit-graph), a FIFO there would hang the scan, and a device or
# a socket is no repository data.  In a work tree Git opens .gitignore,
# .gitattributes and .gitmodules.  A symlink is followed, so one that
# leads to a special file counts too (links that lead out of ROOT are
# checked further on).  This stops the scan at once, before any of them
# is read.
: > "$OUT/.special"
while IFS= read -r d; do
    find "$d" \( -type l -o ! \( -type f -o -type d \) \) -print0 \
        2>"$ERR" >> "$OUT/.special" || fail "cannot list ${d}"
    [ ! -s "$ERR" ] || fail "cannot list ${d}: $(cat "$ERR")"
done < "$GITDIRS"
if [ "$MODE" = worktree ]; then
    find "$ROOT" \( -name .gitignore -o -name .gitattributes \
        -o -name .gitmodules \) ! -type f -print0 2>"$ERR" \
        >> "$OUT/.special" || fail "cannot list ${ROOT}"
    [ ! -s "$ERR" ] || fail "cannot list ${ROOT}: $(cat "$ERR")"
fi
LC_ALL=C sort -zu "$OUT/.special" > "$OUT/.special-u" \
    || fail "cannot sort the special files"
while IFS= read -r -d '' f; do
    # A symlink to a regular file or a directory is no special file;
    # test -e and -f look at the target without opening it.
    if [ -L "$f" ] && { [ ! -e "$f" ] || [ -f "$f" ] || [ -d "$f" ]; }
    then
        continue
    fi
    [ ! -d "$f" ] || continue
    report "block special-file $(oneline "${f#"$ROOT"/}")"
done < "$OUT/.special-u"
if grep -q '^block special-file ' "$REPORT"; then
    exit 0
fi

# In gitdir mode (a repository the engine made, which agents can write)
# Git reads the config as it is, following an include wherever it
# points: an include of a FIFO would hang the scan.  The engine writes
# none, so one stops the scan before any git command reads the config.
# (A workspace's config files are read on their own, includes left out;
# an include there blocks below.)
if [ "$MODE" = gitdir ]; then
    _cfg_stop=""
    while IFS= read -r d; do
        for cf in "$d/config" "$d/config.worktree"; do
            [ -f "$cf" ] || continue
            rc=0
            cfg -f "$cf" --name-only --get-regexp \
                '^(include|includeif)\.' > "$OUT/.inc" 2>/dev/null \
                || rc=$?
            case "$rc" in
                0)
                    report "block config-include ${d#"$ROOT"/}"
                    _cfg_stop=yes ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
        done
    done < "$GITDIRS"
    [ -z "$_cfg_stop" ] || exit 0
fi

# Unsupported layouts that keep history outside these git dirs.  In a
# workspace the config files are read on their own, includes left out
# (an include blocks below); a repository the engine made (gitdir mode)
# is read as Git reads it, once it holds no include.
while IFS= read -r d; do
    [ ! -f "$d/shallow" ] || report "block shallow ${d#"$ROOT"/}"
    _lfs=""
    if [ "$MODE" = worktree ]; then
        for cf in "$d/config" "$d/config.worktree"; do
            [ -f "$cf" ] || continue
            _v=$(cfg -f "$cf" --get lfs.storage 2>/dev/null) || _v=""
            [ -z "$_v" ] || _lfs="$_v"
        done
    else
        _lfs=$(git --git-dir="$d" -c safe.directory='*' config \
            --get lfs.storage 2>/dev/null || true)
    fi
    [ -z "$_lfs" ] || report "block lfs-storage ${d#"$ROOT"/} ${_lfs}"
done < "$GITDIRS"

# In worktree mode the location is a volume whose container is about to
# go: repository settings that send work-tree files or config to other
# places in that container (a core.worktree outside ROOT, includes),
# and symlinks inside a git dir that point outside ROOT, leave data the
# bundle does not carry.  Each git dir's own config files are read
# directly.
if [ "$MODE" = worktree ]; then
    cp "$GITDIRS" "$OUT/.gitdirs-l"
    while IFS= read -r d; do
        rel="${d#"$ROOT"/}"
        # A git dir's common dir (objects, refs) must be in the volume.
        if [ -f "$d/commondir" ] && has_nul "$d/commondir"; then
            report "block commondir ${rel} (unreadable or NUL byte)"
        elif [ -f "$d/commondir" ] \
                && ! cd_v=$(read_pointer "$d/commondir"); then
            report "block commondir ${rel} (unreadable, or a line break inside)"
        elif [ -f "$d/commondir" ]; then
            case "$cd_v" in
                /*) ;;
                *) cd_v="$d/$cd_v" ;;
            esac
            cd_c=$(canon_nm "$cd_v") || cd_c=""
            case "$cd_c" in
                "$ROOT"/*)
                    # Only a common dir this scan inspects as a git dir
                    # of its own (a linked worktree's repository) is
                    # accepted; any other layout keeps objects and config
                    # the checks above do not see.
                    if ! grep -qxF "$cd_c" "$OUT/.gitdirs-l"; then
                        report "block commondir ${rel} $(oneline "$cd_v")"
                    fi ;;
                *) report "block commondir ${rel} $(oneline "$cd_v")" ;;
            esac
        fi
        for cf in "$d/config" "$d/config.worktree"; do
            [ -f "$cf" ] || continue
            rc=0
            cfg -f "$cf" --name-only --get-regexp \
                '^(include\..*|includeif\..*)$' > "$OUT/.inc" 2>/dev/null \
                || rc=$?
            case "$rc" in
                0) report "block config-include ${rel}" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
            # A filter driver is a command Git runs on work-tree files
            # (git status can run a clean filter): it would run inside
            # this scan.  It blocks rather than being switched off, which
            # would make every filtered file look modified.
            rc=0
            cfg -f "$cf" --name-only --get-regexp '^filter\.' \
                > "$OUT/.flt" 2>/dev/null || rc=$?
            case "$rc" in
                0) report "block filter-driver ${rel} $(oneline "$(head -n 1 "$OUT/.flt")")" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
            # Custom hooks live wherever the setting says, resolved
            # against a base that depends on the repository layout; the
            # engine never sets it, so any value blocks.
            rc=0
            cfg -f "$cf" --get core.hooksPath >/dev/null 2>&1 \
                || rc=$?
            case "$rc" in
                0) report "block core-hookspath ${rel}" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
            # core.worktree is relative to the git dir; submodule git
            # dirs set it to their checkout inside ROOT.
            rc=0
            wtv=$(cfg -f "$cf" --get core.worktree 2>/dev/null \
                && printf x) || rc=$?
            # Git prints the value and a newline; any other newline is
            # part of the value.
            wtv="${wtv%x}"
            wtv="${wtv%$'\n'}"
            case "$wtv" in
                *$'\n'*)
                    report "block core-worktree ${rel} (newline in path)"
                    continue ;;
            esac
            case "$rc" in
                0)
                    case "$wtv" in
                        /*) ;;
                        *) wtv="$d/$wtv" ;;
                    esac
                    wtc=$(canon_nm "$wtv") || wtc=""
                    # A work tree inside a git dir is out of sight of the
                    # search for repositories below ROOT (it skips every
                    # .git), and status would go there.
                    if in_a_top "$wtc"; then
                        report "block gitdir-worktree ${rel} ${wtv}"
                    else
                        case "$wtc" in
                            "$ROOT"|"$ROOT"/*) ;;
                            *) report "block core-worktree ${rel} ${wtv}" ;;
                        esac
                    fi ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
        done
    done < "$GITDIRS"
    # Every symlink anywhere in the volume (checkout, git dirs, object
    # pools named by alternates) is resolved to where it really leads.
    # Links to directories inside ROOT are fine: their contents are in
    # ROOT and this walk visits them where they are.  A link that leads
    # out of ROOT is reported as "layer-link <path>": whether that path
    # holds the container's own data only the container can tell
    # (retire compares it with docker diff).  A loop blocks.
    find "$ROOT" -type l -print0 2>"$ERR" > "$OUT/.links" \
        || fail "cannot list ${ROOT}"
    [ ! -s "$ERR" ] || fail "cannot list ${ROOT}: $(cat "$ERR")"
    while IFS= read -r -d '' l; do
        : > "$OUT/.via"
        : > "$OUT/.seen"
        # The x keeps a trailing newline of the path.
        rp_rc=0
        lt=$(real_path "$l" "$OUT/.via" "$OUT/.seen" && printf x) || rp_rc=$?
        case "$rp_rc" in
            0) ;;
            2)
                report "block newline-path $(oneline "${l#"$ROOT"/}")"
                continue ;;
            *)
                # Resolution stopped (a loop, or a link it cannot read).
                # If it had reached a mount the snapshot lacks, say so.
                hit=""
                while IFS= read -r v; do
                    while IFS= read -r m; do
                        [ -n "$m" ] || continue
                        case "$v" in
                            "$m"|"$m"/*) hit="$m" ;;
                        esac
                    done < "$OUT/.mounts"
                done < "$OUT/.seen"
                if [ -n "$hit" ]; then
                    report "block mount-crossing $(oneline "${l#"$ROOT"/}") $(oneline "$hit")"
                else
                    report "block link-loop $(oneline "${l#"$ROOT"/}")"
                fi
                continue ;;
        esac
        lt="${lt%x}"
        out_of_root=""
        while IFS= read -r v; do
            case "$v" in
                "$ROOT"|"$ROOT"/*) ;;
                *) on_the_way_to_root "$v" || out_of_root=yes ;;
            esac
        done < "$OUT/.seen"
        case "$lt" in
            *$'\n'*)
                report "block newline-path $(oneline "${l#"$ROOT"/}")"
                continue ;;
        esac
        case "$lt" in
            "$ROOT"|"$ROOT"/*) ;;
            *)
                # A directory outside ROOT can hold further links that
                # lead anywhere; only a file (or a path that does not
                # exist here) is compared with the container's changes.
                if [ -d "$lt" ]; then
                    report "block outside-dir-link $(oneline "${l#"$ROOT"/}")"
                    continue
                fi
                report "layer-link $(oneline "$lt")" ;;
        esac
        # The chain's steps outside ROOT, also when it ends inside it:
        # links passed (layer-via, compared with the container's
        # changes) and every path visited (layer-path, compared with its
        # other mounts, whose contents the snapshot lacks).
        [ -n "$out_of_root" ] || continue
        while IFS= read -r v; do
            case "$v" in
                "$ROOT"|"$ROOT"/*) ;;
                *) report "layer-via $(oneline "$v")" ;;
            esac
        done < "$OUT/.via"
        while IFS= read -r v; do
            case "$v" in
                "$ROOT"|"$ROOT"/*) ;;
                *)
                    ! on_the_way_to_root "$v" || continue
                    report "layer-path $(oneline "$v")"
                    while IFS= read -r m; do
                        [ -n "$m" ] || continue
                        case "$v" in
                            "$m"|"$m"/*)
                                report "block mount-crossing $(oneline "${l#"$ROOT"/}") $(oneline "$m")" ;;
                        esac
                    done < "$OUT/.mounts" ;;
            esac
        done < "$OUT/.seen"
    done < "$OUT/.links"

    # Object stores that borrow from elsewhere: every alternates entry,
    # followed through the alternates of the stores it names, must stay
    # inside ROOT.
    : > "$OUT/.alt-seen"
    while IFS= read -r d; do
        [ -d "$d/objects" ] && printf '%s\n' "$d/objects"
    done < "$GITDIRS" > "$OUT/.alt-queue"
    while [ -s "$OUT/.alt-queue" ]; do
        od=$(head -1 "$OUT/.alt-queue")
        tail -n +2 "$OUT/.alt-queue" > "$OUT/.alt-q2"
        mv "$OUT/.alt-q2" "$OUT/.alt-queue"
        grep -qxF "$od" "$OUT/.alt-seen" && continue
        printf '%s\n' "$od" >> "$OUT/.alt-seen"
        [ -f "$od/info/alternates" ] || continue
        if has_nul "$od/info/alternates"; then
            report "block alternates $(oneline "${od#"$ROOT"/}") (unreadable or NUL byte)"
            continue
        fi
        # The last entry counts even without a final newline.
        while IFS= read -r alt || [ -n "$alt" ]; do
            case "$alt" in
                ''|'#'*) continue ;;
                '"'*)
                    # Git decodes a quoted entry (C-style escapes); this
                    # scan does not, so it cannot tell where it points.
                    report "block alternates $(oneline "${od#"$ROOT"/}") $(oneline "$alt")"
                    continue ;;
                /*) ;;
                *) alt="$od/$alt" ;;
            esac
            ac=$(canon_nm "$alt") || ac=""
            case "$ac" in
                "$ROOT"/*) printf '%s\n' "$ac" >> "$OUT/.alt-queue" ;;
                *) report "block alternates $(oneline "${od#"$ROOT"/}") $(oneline "$alt")" ;;
            esac
        done < "$od/info/alternates"
    done

    # A partial clone leaves objects to its promisor remote: its history
    # is not all here, and this scan never fetches.  A partial-clone
    # setting (extensions.partialClone, a remote's promisor or
    # partialCloneFilter) in either config file of any git dir, or a
    # promisor pack in any object store this scan reads (alternates
    # included, whatever the pack's name), refuses, also when every
    # object happens to be there.
    while IFS= read -r d; do
        rel="${d#"$ROOT"/}"
        for cf in "$d/config" "$d/config.worktree"; do
            [ -f "$cf" ] || continue
            rc=0
            cfg -f "$cf" --get extensions.partialClone >/dev/null 2>&1 \
                || rc=$?
            case "$rc" in
                0) report "block promisor ${rel} extensions.partialClone" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
            rc=0
            cfg -f "$cf" --name-only --get-regexp \
                '^remote\..*\.(promisor|partialclonefilter)$' \
                > "$OUT/.prom" 2>/dev/null || rc=$?
            case "$rc" in
                0) report "block promisor ${rel} $(oneline "$(head -n 1 "$OUT/.prom")")" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
        done
    done < "$GITDIRS"
    while IFS= read -r od; do
        [ -d "$od/pack" ] || continue
        find -H "$od/pack" -mindepth 1 -maxdepth 1 -name '*.promisor' \
            -print 2>"$ERR" > "$OUT/.promp" || fail "cannot list ${od}/pack"
        [ ! -s "$ERR" ] || fail "cannot list ${od}/pack: $(cat "$ERR")"
        if [ -s "$OUT/.promp" ]; then
            report "block promisor $(oneline "${od#"$ROOT"/}") $(oneline "$(head -n 1 "$OUT/.promp" | sed 's|.*/||')")"
        fi
    done < "$OUT/.alt-seen"
fi

# Engine files and the deletions the context mode makes: in the
# workspace's own checkout ($2 = "."), where the engine writes those
# paths, entry XY PATH ($1, $3) is not work.  In submodules and
# worktrees it is.
engine_entry() {
    local xy="$1" rel="$2" path="$3"
    # A checkout in a container's layer is the agent's alone.
    [ "$CONTEXT" != layer ] || return 1
    [ "$rel" = "." ] || return 1
    case "$path" in
        agent_logs|agent_logs/*|.claude/settings.local.json) return 0 ;;
    esac
    if [ "$xy" = " D" ]; then
        case "$path" in
            .claude/*)
                [ "$CONTEXT" != none ] || return 0
                if [ "$CONTEXT" = slim ] && [ "$path" != .claude/CLAUDE.md ]
                then
                    return 0
                fi ;;
        esac
    fi
    return 1
}

# Succeed when ignored-directory entry $3 of the checkout at $1 (shown
# as $2) stands for nothing but the engine's file: .claude/ in the
# workspace's own checkout (never in a layer), a real directory that
# holds .claude/settings.local.json, a regular file, and nothing else,
# as the file system (not Git, which skips what it takes for a .git)
# lists it.  Git shows an ignored directory as one entry when nothing in
# it is tracked; anything else in it keeps that entry reported whole.
engine_dir_only() {
    local wt="$1" rel="$2" path="$3" entries
    [ "$CONTEXT" != layer ] || return 1
    [ "$rel" = "." ] && [ "$path" = ".claude/" ] || return 1
    [ -d "$wt/.claude" ] && [ ! -L "$wt/.claude" ] || return 1
    [ -f "$wt/.claude/settings.local.json" ] \
        && [ ! -L "$wt/.claude/settings.local.json" ] || return 1
    entries=$(cd "$wt/.claude" && find . -mindepth 1 -print 2>/dev/null \
        | head -n 2 && echo x) || return 1
    [ "$entries" = "./settings.local.json"$'\n'"x" ]
}

# Succeed when status record $2 (XY) $3 (path) of the checkout at $1 is
# the directory of a repository nested in it that this scan carries and
# checks on its own: an untracked (??) or ignored (!!) directory, not a
# link, whose .git is one of the TOPS.  Git shows such a directory as
# one entry and does not look inside it.  Tracked records are never
# skipped.
nested_entry() {
    local wt="$1" xy="$2" path="$3" d
    case "$xy" in
        '??'|'!!') ;;
        *) return 1 ;;
    esac
    case "$path" in
        */) ;;
        *) return 1 ;;
    esac
    d="$wt/${path%/}"
    [ -d "$d" ] && [ ! -L "$d" ] && [ -d "$d/.git" ] && [ ! -L "$d/.git" ] \
        || return 1
    grep -qxF -- "$d/.git" "$TOPS"
}

# Work-tree content outside Git's history, for the checkout at $1 with
# git dir $3 ($2 is its path in the report).  Both are passed
# explicitly, so a core.worktree setting cannot point status elsewhere.
# Status is read NUL-separated (-z), so paths come unquoted and whole.
check_checkout() {
    local wt="$1" rel="$2" gd="$3" rec xy path t f nested kind=uncommitted
    # A linked worktree outside ROOT (its name absolute) is in the
    # container's layer, which docker rm deletes.
    case "$rel" in
        /*) kind=layer-uncommitted ;;
    esac
    # No rename detection: a rename record would hide its new path from
    # the filters below.  --ignore-submodules=dirty: a submodule counts
    # when its commit differs from the one recorded, but status does not
    # look into its work tree (that would run git there, with whatever
    # git dir and config it names): every submodule checkout is checked
    # on its own, with its validated git dir (queue_checkout).
    gw "$wt" --git-dir="$gd" --work-tree="$wt" status --porcelain=v1 -z \
        --no-renames --untracked-files=all --ignore-submodules=dirty \
        > "$OUT/.st"
    while IFS= read -r -d '' rec; do
        xy="${rec:0:2}"
        path="${rec:3}"
        engine_entry "$xy" "$rel" "$path" && continue
        nested_entry "$wt" "$xy" "$path" && continue
        report "${kind} dirty ${rel}: ${xy} $(oneline "$path")"
    done < "$OUT/.st"
    gw "$wt" --git-dir="$gd" --work-tree="$wt" status --porcelain=v1 -z \
        --no-renames --untracked-files=all --ignored=matching \
        --ignore-submodules=all > "$OUT/.st"
    while IFS= read -r -d '' rec; do
        [ "${rec:0:3}" = "!! " ] || continue
        path="${rec:3}"
        engine_entry "!!" "$rel" "$path" && continue
        engine_dir_only "$wt" "$rel" "$path" && continue
        nested_entry "$wt" "!!" "$path" && continue
        report "${kind} ignored ${rel}: $(oneline "$path")"
    done < "$OUT/.st"
    gw "$wt" --git-dir="$gd" --work-tree="$wt" ls-files -v -z > "$OUT/.ls"
    while IFS= read -r -d '' rec; do
        case "${rec:0:1}" in
            [a-z]|S) report "${kind} hidden ${rel}: ${rec:0:1} $(oneline "${rec:2}")" ;;
        esac
    done < "$OUT/.ls"
    # Status shows nothing below a submodule's path, and a submodule
    # directory without its .git (never initialized, or its .git
    # removed) is no checkout of its own: every file there is listed.
    gw "$wt" --git-dir="$gd" --work-tree="$wt" ls-files -s -z > "$OUT/.gl"
    while IFS= read -r -d '' rec; do
        case "$rec" in
            "160000 "*) ;;
            *) continue ;;
        esac
        path="${rec#*$'\t'}"
        if [ -e "$wt/$path/.git" ] || [ -L "$wt/$path/.git" ] \
                || [ -L "$wt/$path" ] || [ ! -d "$wt/$path" ]; then
            continue
        fi
        # A repository nested below it (one of the TOPS) is carried and
        # checked on its own: its tree is left out of this listing.
        : > "$OUT/.gls" || fail "cannot write ${OUT}/.gls"
        while IFS= read -r t; do
            case "$t" in
                "$wt/$path"/*/.git)
                    printf '%s\n' "${t%/.git}" >> "$OUT/.gls" \
                        || fail "cannot write ${OUT}/.gls" ;;
            esac
        done < "$TOPS"
        find "$wt/$path" -mindepth 1 ! -type d -print0 2>"$ERR" \
            > "$OUT/.glf" || fail "cannot list ${wt}/${path}"
        [ ! -s "$ERR" ] || fail "cannot list ${wt}/${path}: $(cat "$ERR")"
        while IFS= read -r -d '' f; do
            nested=false
            while IFS= read -r t; do
                case "$f" in
                    "$t"/*) nested=true; break ;;
                esac
            done < "$OUT/.gls"
            $nested && continue
            report "${kind} dirty ${rel}: ?? $(oneline "${f#"$wt"/}")"
        done < "$OUT/.glf"
    done < "$OUT/.gl"
}

# Report every index entry of checkout $1 (shown as $2, git dir $3)
# whose path Git itself would never write: absolute, with an empty, "."
# or ".." component, or with a ".git" component (in any case).  Such a
# path can lead into a git dir, where the search for repositories below
# ROOT does not look.
check_index_paths() {
    local wt="$1" rel="$2" gd="$3" p lc
    gw "$wt" --git-dir="$gd" --work-tree="$wt" ls-files -z > "$OUT/.lsf"
    while IFS= read -r -d '' p; do
        lc=$(printf '%s' "$p" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' \
            'abcdefghijklmnopqrstuvwxyz')
        case "/$lc/" in
            //*|*//*|*/./*|*/../*|*/.git/*)
                report "block index-in-gitdir ${rel}: $(oneline "$p")" ;;
        esac
    done < "$OUT/.lsf"
}

# Queue checkout $1 (shown as $2, git dir $3) for check_checkout, which
# runs only once every repository below ROOT has been validated.
queue_checkout() {
    printf '%s\0%s\0%s\0' "$1" "$2" "$3" >> "$OUT/.checkouts" \
        || fail "cannot queue the checkout $(oneline "$2")"
}

# Queue the checkout at $1 (shown as $2) whose .git file names git dir
# $3 (resolved), when that is a git dir this scan checked, in one of the
# TOPS: a submodule's module repo, or a linked worktree's admin dir that
# names $1 back (that checkout is queued with the linked worktrees
# below).  Return 1 when $3 is none of those, for the caller to report;
# 0 when it queued the checkout or reported why not.
gitfile_target() {
    local wt="$1" rel="$2" target="$3" t rest bp bpwt wtc
    while IFS= read -r t; do
        case "$target" in
            "$t"/worktrees/*)
                # A linked worktree's own admin dir (one level below
                # worktrees/, with its gitdir back-pointer) is checked
                # with the others below.  Anything deeper, such as a
                # module repo of a linked worktree, is a submodule
                # checkout and is checked here.
                rest="${target#"$t"/worktrees/}"
                case "$rest" in
                    */*)
                        if grep -qxF -- "$target" "$GITDIRS"; then
                            queue_checkout "$wt" "$rel" "$target"
                            return 0
                        fi
                        return 1 ;;
                esac
                [ -f "$target/gitdir" ] \
                    && grep -qxF -- "$target" "$GITDIRS" || return 1
                # Only when its back-pointer names this checkout; a
                # copied worktree dir points at another one and is not
                # checked there.
                if has_nul "$target/gitdir"; then
                    report "block mismatched-worktree $(oneline "$rel")"
                    return 0
                fi
                bp=$(cat "$target/gitdir")
                case "$bp" in
                    /*) ;;
                    *) bp="$target/$bp" ;;
                esac
                bpwt=$(canon "${bp%/.git}") || bpwt=""
                wtc=$(canon "$wt") || wtc="-"
                [ "$bpwt" = "$wtc" ] \
                    || report "block mismatched-worktree ${rel}"
                return 0 ;;
            "$t"/*)
                # Only a git dir this scan checked (in GITDIRS).
                if grep -qxF -- "$target" "$GITDIRS"; then
                    queue_checkout "$wt" "$rel" "$target"
                    return 0
                fi
                return 1 ;;
        esac
    done < "$TOPS"
    return 1
}

if [ "$MODE" = worktree ]; then
    : > "$OUT/.checkouts"
    # Every other .git below ROOT is either the git dir of a repository
    # nested in the checkout (one of the TOPS: its checkout is queued
    # here) or a .git file that leads to a git dir this scan checked;
    # anything else is a repository the bundle does not see.  This is
    # checked before git status runs: status looks into submodules
    # (--ignore-submodules=none) with the config of whatever git dir
    # their .git names.
    while IFS= read -r -d '' e; do
        [ "$e" != "$TOP" ] || continue
        wt="${e%/.git}"
        rel="${wt#"$ROOT"/}"
        case "$rel" in
            *$'\n'*)
                report "block newline-path $(printf '%s' "$rel" \
                    | awk 'BEGIN { ORS = "\\n" } { print }')"
                UNCHECKED_REPO=yes
                continue ;;
        esac
        if [ -d "$e" ] && [ ! -L "$e" ] && grep -qxF -- "$e" "$TOPS"; then
            queue_checkout "$wt" "$rel" "$e"
            continue
        fi
        if [ -f "$e" ] && [ ! -L "$e" ]; then
            if has_nul "$e"; then
                report "block embedded $(oneline "$rel") (unreadable or NUL byte in .git)"
                continue
            fi
            # Git reads the whole file and drops only trailing CR and LF:
            # a line break inside would name another path than the one
            # checked here.
            target=$(read_pointer "$e") || target=""
            case "$target" in
                "gitdir: "*) target="${target#gitdir: }" ;;
                *) target="" ;;
            esac
            if [ -z "$target" ]; then
                report "block embedded $(oneline "$rel") (not one gitdir line in .git)"
                continue
            fi
            case "$target" in
                /*) ;;
                *) target="$wt/$target" ;;
            esac
            target=$(canon_nm "$target") || target=""
            gitfile_target "$wt" "$rel" "$target" && continue
        fi
        report "block embedded ${rel}"
    done < "$OUT/.markers"
    # A repository directory anywhere below ROOT outside the .git
    # directories (a bare clone, a copied .git under another name) holds
    # history the bundle does not carry: it blocks, whatever filters
    # would apply to its files.
    find "$ROOT" -name .git -prune -o \( -type f -o -type l \) \
        -name HEAD -print0 2>"$ERR" > "$OUT/.otherheads" \
        || fail "cannot list ${ROOT}"
    [ ! -s "$ERR" ] || fail "cannot list ${ROOT}: $(cat "$ERR")"
    while IFS= read -r -d '' h; do
        r="${h%/HEAD}"
        [ -d "$r/objects" ] || [ -f "$r/commondir" ] || continue
        [ "${r##*/}" != .git ] || continue
        rel="${r#"$ROOT"/}"
        case "$rel" in
            *$'\n'*)
                report "block newline-path $(printf '%s' "$rel" \
                    | awk 'BEGIN { ORS = "\\n" } { print }')"
                UNCHECKED_REPO=yes ;;
            *) report "block embedded ${rel}" ;;
        esac
    done < "$OUT/.otherheads"

    # Linked worktrees: inside ROOT they are checked like any checkout.
    # Outside it (a container's /tmp) their files are not in the volume:
    # one whose directory is gone is a note, cleanup defers the others to
    # retire, and retire's volume scan checks one in the container's own
    # layer (accept_external_worktree); anything else blocks.
    while IFS= read -r d; do
        [ -f "$d/gitdir" ] || continue
        if has_nul "$d/gitdir"; then
            report "block missing-worktree $(oneline "${d#"$ROOT"/}") (unreadable or NUL byte)"
            continue
        fi
        # The back-pointer as Git reads it: one line, a path ending in
        # /.git, short, with no control character.
        sz=$(wc -c < "$d/gitdir" | tr -d ' ') || sz=-1
        if [ "$sz" -lt 0 ] || [ "$sz" -gt 4096 ] \
                || ! wtgit=$(read_one_line "$d/gitdir"); then
            report "block worktree-pointer $(oneline "${d#"$ROOT"/}") (not one short line)"
            continue
        fi
        case "$wtgit" in
            *[[:cntrl:]]*)
                report "block worktree-pointer $(oneline "${d#"$ROOT"/}") (a control character)"
                continue ;;
        esac
        case "$wtgit" in
            */.git) ;;
            *)
                report "block worktree-pointer $(oneline "$wtgit") (not a .git path)"
                continue ;;
        esac
        case "$wtgit" in
            /*)
                dir="${wtgit%/.git}"
                if ! normalized_abs "$dir"; then
                    report "block worktree-pointer $(oneline "$wtgit") (not a normalized path)"
                    continue
                fi
                case "$dir" in
                    "$ROOT"|"$ROOT"/*) ;;
                    *)
                        # Outside ROOT: its own text, never resolved, so
                        # every component of it is walked.
                        if ! worktree_dir_state "$dir"; then
                            report "block worktree-path $(oneline "$dir") (${WT_WHY})"
                            continue
                        fi
                        case "$ORIGIN:$WT_STATE" in
                            cleanup:absent)
                                report "deferred-worktree $(oneline "$dir")" ;;
                            cleanup:present)
                                # A directory of the image cleanup
                                # scans from: the worktree only if its
                                # .git names this admin dir back.
                                if [ -f "$dir/.git" ] && [ ! -L "$dir/.git" ] \
                                        && [ "$(read_one_line "$dir/.git" 2>/dev/null)" = "gitdir: $d" ]
                                then
                                    report "block external $(oneline "$dir") (present where cleanup scans)"
                                else
                                    report "deferred-worktree $(oneline "$dir")"
                                fi ;;
                            *:absent)
                                report "gone-worktree $(oneline "$dir")" ;;
                            retire-volume:present)
                                accept_external_worktree "$dir" "$d" || true ;;
                            *)
                                report "block external $(oneline "$dir")" ;;
                        esac
                        continue ;;
                esac
                wtgit="${dir}/.git"
                relptr="" ;;
            *)
                # The back-pointer is relative to this admin dir when
                # the worktree was added with --relative-paths.
                relptr="$wtgit"
                wtgit="$d/$wtgit" ;;
        esac
        wt="${wtgit%/.git}"
        if ! wt=$(canon_nm "$wt"); then
            report "block missing-worktree ${wtgit%/.git}"
            continue
        fi
        if in_a_top "$wt"; then
            report "block gitdir-worktree ${wt#"$ROOT"/}"
            continue
        fi
        case "$wt" in
            "$ROOT"/*) queue_checkout "$wt" "${wt#"$ROOT"/}" "$d" ;;
            *)
                if [ -n "$relptr" ]; then
                    report "block worktree-pointer $(oneline "$relptr") (relative, outside)"
                else
                    report "block external ${wt}"
                fi ;;
        esac
    done < "$GITDIRS"
    # Only now is the work tree read (git status, ls-files), with the
    # config of the git dirs checked above, and not at all when one of
    # those findings would let status run with a config nobody checked:
    # a filter driver, an include, an embedded repository or a git dir
    # or repository whose path holds a newline (UNCHECKED_REPO; status
    # looks into submodules with their own config), a core.worktree
    # outside or inside a git dir (a submodule's status goes there,
    # to whatever repositories it holds), a worktree whose admin dir
    # does not name it back, a common dir elsewhere.  Such a location is
    # refused anyway; other blocks still let the scan finish its report.
    # The index names paths too: status refreshes every entry, and for a
    # gitlink reads the repository at its path.  Git never puts an entry
    # under the git dir itself (only a hand-written index does), and the
    # search for repositories below ROOT skips the git dir, so any such
    # entry, in any checkout's index, blocks.  ls-files reads the index
    # without refreshing it.
    # ls-files reads each checkout's config, includes and all: it runs
    # only once none of those findings is there.
    if [ -n "$UNCHECKED_REPO" ] \
            || grep -qE '^block (filter-driver|config-include|embedded|core-worktree|gitdir-worktree|mismatched-worktree|commondir|promisor) ' \
            "$REPORT"; then
        exit 0
    fi
    check_index_paths "$ROOT" "." "$TOP"
    while IFS= read -r -d '' wt && IFS= read -r -d '' rel \
            && IFS= read -r -d '' gd; do
        check_index_paths "$wt" "$rel" "$gd"
    done < "$OUT/.checkouts"
    if grep -q '^block index-in-gitdir ' "$REPORT"; then
        exit 0
    fi
    check_checkout "$ROOT" "." "$TOP"
    while IFS= read -r -d '' wt && IFS= read -r -d '' rel \
            && IFS= read -r -d '' gd; do
        check_checkout "$wt" "$rel" "$gd"
    done < "$OUT/.checkouts"
fi

# Unfinished operations, in every git dir.
while IFS= read -r d; do
    for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG \
            rebase-merge rebase-apply sequencer; do
        [ ! -e "$d/$f" ] || report "uncommitted operation ${d#"$ROOT"/}/${f}"
    done
    for f in "$d"/*AUTOSTASH*; do
        [ ! -e "$f" ] || report "uncommitted operation ${f#"$ROOT"/}"
    done
done < "$GITDIRS"

# ---- Objects to keep ----------------------------------------------------

# The scratch repo uses the source's hash; every git dir must share it.
FORMAT=$(git --git-dir="$TOP" -c safe.directory='*' rev-parse \
    --show-object-format 2>/dev/null) || fail "cannot read the hash of ${TOP}"
while IFS= read -r d; do
    f=$(git --git-dir="$d" -c safe.directory='*' rev-parse \
        --show-object-format 2>/dev/null) || fail "cannot read the hash of ${d}"
    [ "$f" = "$FORMAT" ] || fail "${d} uses ${f}, ${TOP} uses ${FORMAT}"
done < "$GITDIRS"
git init -q --bare --object-format="$FORMAT" "$SCRATCH" \
    || fail "cannot create ${SCRATCH}"
: > "$SCRATCH/objects/info/alternates"
OBJECTS="$OUT/objects"
: > "$OBJECTS"
n=0
while IFS= read -r d; do
    n=$((n + 1))
    rel="${d#"$ROOT"/}"
    [ "$d" != "$ROOT" ] || rel="."
    report "gitdir ${n} ${rel}"
    tips="$OUT/.tips.$n"
    : > "$tips"
    # The object store this git dir uses.
    if [ -d "$d/objects" ]; then
        store="$d"
    else
        has_nul "$d/commondir" && fail "cannot read ${d}/commondir"
        common=$(read_pointer "$d/commondir") \
            || fail "cannot read ${d}/commondir"
        case "$common" in
            /*) store="$common" ;;
            *) store="$d/$common" ;;
        esac
    fi
    store=$(canon "$store") || fail "no object store for ${d}"
    grep -qxF "$store/objects" "$SCRATCH/objects/info/alternates" \
        || printf '%s\n' "$store/objects" >> "$SCRATCH/objects/info/alternates"
    # Refs (only a repository has its own).
    if [ -d "$d/objects" ]; then
        g "$d" for-each-ref --format='%(objectname)' >> "$tips"
    fi
    # Every object id in HEAD, the reflogs, and the other files Git
    # keeps directly in the git dir or in an operation's directory
    # (ORIG_HEAD, MERGE_AUTOSTASH, rebase-merge/autostash, ...).
    for f in "$d"/* "$d"/rebase-merge/* "$d"/rebase-apply/* \
            "$d"/sequencer/*; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
            index|packed-refs|config|description) continue ;;
        esac
        grep -aowE '[0-9a-f]{40}([0-9a-f]{24})?' "$f" >> "$tips" || true
    done
    if [ -d "$d/logs" ]; then
        find "$d/logs" -type f -print0 2>"$ERR" > "$OUT/.logs" \
            || fail "cannot list ${d}/logs"
        [ ! -s "$ERR" ] || fail "cannot list ${d}/logs: $(cat "$ERR")"
        while IFS= read -r -d '' f; do
            awk '{ print $1; print $2 }' "$f" >> "$tips" \
                || fail "cannot read ${f}"
        done < "$OUT/.logs"
    fi
    # Keep the ids that name an object in this store.
    sort -u "$tips" | grep -vE '^0+$' > "$tips.u" || true
    g "$d" cat-file --batch-check='%(objectname) %(objecttype)' \
        < "$tips.u" > "$tips.c"
    grep -v ' missing$' "$tips.c" | awk '{ print $1 }' > "$tips" || true
    # Every object of a repository's own store that those tips do not
    # reach becomes a tip too: objects held only by the index or by
    # nothing at all.
    if [ -d "$d/objects" ]; then
        g "$d" cat-file --batch-all-objects --batch-check='%(objectname)' \
            > "$OUT/.all.$n"
        sort -u "$OUT/.all.$n" > "$OUT/.all.$n.s"
        g "$d" rev-list --objects --no-object-names --stdin < "$tips" \
            > "$OUT/.reach.$n"
        sort -u "$OUT/.reach.$n" > "$OUT/.reach.$n.s"
        comm -23 "$OUT/.all.$n.s" "$OUT/.reach.$n.s" >> "$tips"
        cat "$OUT/.all.$n.s" >> "$OBJECTS"
    fi
    sort -u "$tips" -o "$tips"
    k=0
    while IFS= read -r oid; do
        k=$((k + 1))
        printf 'update refs/v/%s/t/%s %s\n' "$n" "$k" "$oid"
    done < "$tips" > "$OUT/.upd.$n"
    git --git-dir="$SCRATCH" update-ref --stdin < "$OUT/.upd.$n" 2>"$ERR" \
        || fail "cannot record the objects of ${d}: $(cat "$ERR")"
    manifest=$(git --git-dir="$SCRATCH" hash-object -w --stdin \
        < "$tips") || fail "cannot write the manifest of ${d}"
    git --git-dir="$SCRATCH" update-ref "refs/v/$n/manifest" "$manifest"
    # Where this git dir was, relative to ROOT ("." in gitdir mode), so
    # that refs/v/<n> can be told apart after import.
    gpath=$(printf '%s' "$rel" \
        | git --git-dir="$SCRATCH" hash-object -w --stdin) \
        || fail "cannot write the path of ${d}"
    git --git-dir="$SCRATCH" update-ref "refs/v/$n/path" "$gpath"
    printf '%s\n' "$d" > "$OUT/.gitdir.$n"
done < "$GITDIRS"
sort -u "$OBJECTS" -o "$OBJECTS"

# ---- Files of the git dirs ----------------------------------------------

# Every file and symlink under TOP is stored as a blob, except the
# .pack and .idx files of a pack whose index Git verifies and whose
# objects are all in the inventory: verify-pack recomputes every
# object's hash and checks both files' trailing checksums, so their
# bytes are exactly what the bundle carries.  Loose object files are
# stored like any other file (a loose file can hold bytes after its
# zlib stream that no reader returns), and so are a pack's .rev,
# .mtimes and .bitmap files.
EXEMPT="$OUT/.exempt"
: > "$EXEMPT"
regular() {
    [ -f "$1" ] && [ ! -L "$1" ]
}
while IFS= read -r d; do
    [ -d "$d/objects/pack" ] && [ ! -L "$d/objects/pack" ] || continue
    for p in "$d"/objects/pack/pack-*.pack; do
        regular "$p" || continue
        base="${p%.pack}"
        hex="${base##*/pack-}"
        case "$hex" in
            *[!0-9a-f]*) continue ;;
        esac
        [ "${#hex}" -eq 40 ] || [ "${#hex}" -eq 64 ] || continue
        regular "$base.idx" || continue
        # Run in the source repo, so the pack is read with its hash.
        git --git-dir="$d" -c safe.directory='*' verify-pack "$base.idx" \
            >/dev/null 2>&1 || continue
        git show-index --object-format="$FORMAT" < "$base.idx" \
            > "$OUT/.pidx.raw" 2>/dev/null || continue
        awk '{ print $2 }' "$OUT/.pidx.raw" | sort -u > "$OUT/.pidx"
        [ -s "$OUT/.pidx" ] || continue
        comm -23 "$OUT/.pidx" "$OBJECTS" > "$OUT/.pmiss"
        [ ! -s "$OUT/.pmiss" ] || continue
        printf '%s\n%s\n' "$base.pack" "$base.idx" >> "$EXEMPT"
    done
done < "$GITDIRS"
sort -u "$EXEMPT" -o "$EXEMPT"

# TOP's files as refs/v/0/...; those of a nested repository's git dir
# tree under the number of its git dir in the inventory.
list_files "$TOP" "$EXEMPT"
store_files "$TOP" "" 0
while IFS= read -r t; do
    [ "$t" != "$TOP" ] || continue
    id=$(grep -nxF -- "$t" "$GITDIRS" | cut -d: -f1) || id=""
    case "$id" in
        ''|*[!0-9]*) fail "${t} is not once among the git dirs" ;;
    esac
    list_files "$t" "$EXEMPT"
    store_files "$t" "" "$id"
done < "$TOPS"

# ---- Bundle -------------------------------------------------------------

make_bundle
# The linked worktrees let through outside ROOT are published only now,
# at the scan's normal end and with no block reported: a block or a
# failure on the way leaves no list.
if [ "$MODE" = worktree ] && [ -f "$OUT/.external-worktrees" ]; then
    brc=0
    grep -q '^block ' "$REPORT" || brc=$?
    case "$brc" in
        0) ;;
        1)
            mv "$OUT/.external-worktrees" "$OUT/external-worktrees" \
                || fail "cannot publish the linked worktrees" ;;
        *) fail "cannot read the report" ;;
    esac
fi
exit 0
