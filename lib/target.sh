#!/bin/bash
# The audit target of an engagement: TARGET_REPO at TARGET_REV, and an
# optional base (TARGET_REV_BASE, from TARGET_REV_BASE_REPO or the same
# repository), resolved once on the host into a snapshot that every
# container of the engagement mounts read-only.  This file checks the
# inputs and builds the snapshot; recording it with the engagement and
# mounting it are up to the callers.
#
# The network fetch writes into one scratch directory, which is never
# published; the snapshot is built in another by a local fetch from the
# first, which is waited for to the end, then pinned and checked.
# Every Git command here bounds itself: perl resets SIGALRM to its
# default action, unblocks it, arms alarm() and execs Git, so the kernel
# ends that Git process at the deadline.  Nothing signals a process from
# outside.  The alarm bounds Git, not its helpers: after a timeout, a
# remote helper or an index-pack may run on, but only into the scratch
# directory of its own attempt, which is never published and which a
# later run deletes.
#
# Compatible with Bash 3.2.  Functions print "ERROR: ..." and return 1
# on refusal or failure.

# Succeed when any of the four input variables is set, even empty.
swarm_target_requested() {
    [ -n "${TARGET_REPO+x}${TARGET_REV+x}" ] \
        || [ -n "${TARGET_REV_BASE+x}${TARGET_REV_BASE_REPO+x}" ]
}

# Check repository value $2 of variable $1: an absolute local path,
# ssh://, scp-like [user@]host:path, or https:// without userinfo, query
# or fragment.  Nothing else: a relative path, plain http://, file://,
# another scheme, a transport helper (<helper>::<address>), a leading
# dash.
swarm_target_repo_check() {
    local name="$1" v="$2" host helper='^[A-Za-z0-9][A-Za-z0-9+.-]*::'
    case "$v" in
        '')
            echo "ERROR: ${name} is set but empty." >&2
            return 1 ;;
        *[[:cntrl:]]*)
            echo "ERROR: ${name} holds a control character." >&2
            return 1 ;;
        -*)
            echo "ERROR: ${name} starts with a dash." >&2
            return 1 ;;
    esac
    if [[ "$v" =~ $helper ]]; then
        echo "ERROR: ${name} names a Git transport helper (<helper>::);" \
             "give an ssh://, [user@]host:path or https:// URL, or an" \
             "absolute path." >&2
        return 1
    fi
    case "$v" in
        /*) return 0 ;;
        ssh://*) return 0 ;;
        https://*)
            host="${v#https://}"
            host="${host%%/*}"
            case "$host" in
                *@*)
                    echo "ERROR: ${name} holds a user name or a credential;" \
                         "keep them in your Git credential helper or ssh" \
                         "configuration." >&2
                    return 1 ;;
            esac
            case "$v" in
                *'?'*|*'#'*)
                    echo "ERROR: ${name} holds a query or a fragment." >&2
                    return 1 ;;
            esac
            return 0 ;;
        http://*)
            echo "ERROR: ${name} is plain http://; give an https:// or" \
                 "ssh URL." >&2
            return 1 ;;
        file://*)
            echo "ERROR: ${name} is a file:// URL; give the absolute path." >&2
            return 1 ;;
        *://*)
            echo "ERROR: ${name} has a scheme other than ssh:// and" \
                 "https://." >&2
            return 1 ;;
    esac
    # scp-like: a colon before any slash.
    case "${v%%/*}" in
        *:*) return 0 ;;
    esac
    echo "ERROR: ${name} is a relative path; give an absolute one." >&2
    return 1
}

# Succeed when $1 is a full commit id: 40 (SHA-1) or 64 (SHA-256)
# lowercase hex digits.
swarm_target_full_id() {
    case "$1" in
        *[!0123456789abcdef]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

# Check revision value $2 of variable $1: a full commit id, a full ref
# under refs/heads/ or refs/tags/, or a branch or tag name.  An
# abbreviated id or an expression is no name: resolution refuses it when
# no branch or tag is called that.
swarm_target_rev_check() {
    local name="$1" v="$2"
    case "$v" in
        '')
            echo "ERROR: ${name} is set but empty." >&2
            return 1 ;;
        *[[:cntrl:]]*)
            echo "ERROR: ${name} holds a control character." >&2
            return 1 ;;
        -*)
            echo "ERROR: ${name} starts with a dash." >&2
            return 1 ;;
    esac
    if swarm_target_full_id "$v"; then
        return 0
    fi
    case "$v" in
        refs/heads/*|refs/tags/*)
            if ! _swarm_target_refname_ok "$v"; then
                echo "ERROR: ${name} is not a valid ref: ${v}" >&2
                return 1
            fi
            return 0 ;;
        refs/*)
            echo "ERROR: ${name} is a ref outside refs/heads/ and" \
                 "refs/tags/: ${v}" >&2
            return 1 ;;
    esac
    if ! _swarm_target_refname_ok "refs/heads/$v"; then
        echo "ERROR: ${name} is no full commit id, full ref, branch or" \
             "tag name: ${v}" >&2
        return 1
    fi
}

# Succeed when $1 is a valid full ref name by the rules of
# git-check-ref-format(1), checked here without running Git: Git reads
# its configuration as it starts, which could hold the input checks up
# before any bound applies.
_swarm_target_refname_ok() {
    local r="$1" c
    case "$r" in
        */*) ;;
        *) return 1 ;;
    esac
    case "$r" in
        /*|*/|*//*|*.|*..*|*'@{'*|*\\*) return 1 ;;
        *[[:cntrl:]]*|*' '*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*) return 1 ;;
    esac
    # No component starts with a dot or ends with .lock.
    while :; do
        c="${r%%/*}"
        case "$c" in
            .*|*.lock) return 1 ;;
        esac
        [ "$r" != "$c" ] || return 0
        r="${r#*/}"
    done
}

# Check the four inputs together and set
# SWARM_TARGET_BASE_REPO_EFFECTIVE: the base's repository, or empty
# without a base.
swarm_target_inputs_check() {
    SWARM_TARGET_BASE_REPO_EFFECTIVE=""
    if [ -z "${TARGET_REPO+x}" ] || [ -z "${TARGET_REV+x}" ]; then
        echo "ERROR: a target needs both TARGET_REPO and TARGET_REV." >&2
        return 1
    fi
    swarm_target_repo_check TARGET_REPO "$TARGET_REPO" || return 1
    swarm_target_rev_check TARGET_REV "$TARGET_REV" || return 1
    if [ -n "${TARGET_REV_BASE_REPO+x}" ] && [ -z "${TARGET_REV_BASE+x}" ]
    then
        echo "ERROR: TARGET_REV_BASE_REPO needs TARGET_REV_BASE." >&2
        return 1
    fi
    [ -n "${TARGET_REV_BASE+x}" ] || return 0
    swarm_target_rev_check TARGET_REV_BASE "$TARGET_REV_BASE" || return 1
    if [ -n "${TARGET_REV_BASE_REPO+x}" ]; then
        swarm_target_repo_check TARGET_REV_BASE_REPO \
            "$TARGET_REV_BASE_REPO" || return 1
        SWARM_TARGET_BASE_REPO_EFFECTIVE="$TARGET_REV_BASE_REPO"
    else
        SWARM_TARGET_BASE_REPO_EFFECTIVE="$TARGET_REPO"
    fi
}

# Print the physical path of local repository $1, or $1 itself for a URL.
swarm_target_physical() {
    case "$1" in
        /*)
            (cd -P -- "$1" 2>/dev/null && pwd -P) || {
                echo "ERROR: no directory at ${1}." >&2
                return 1
            } ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Print timeout value $2 of variable $1, a whole number of seconds from
# 1 to 86400, or refuse it.
swarm_target_seconds() {
    local name="$1" v="$2"
    case "$v" in
        ''|*[!0123456789]*|??????*)
            echo "ERROR: ${name} must be a whole number of seconds from 1" \
                 "to 86400." >&2
            return 1 ;;
    esac
    v=$((10#$v))
    if [ "$v" -lt 1 ] || [ "$v" -gt 86400 ]; then
        echo "ERROR: ${name} must be a whole number of seconds from 1" \
             "to 86400." >&2
        return 1
    fi
    printf '%s\n' "$v"
}

# ---- Git commands, isolated and bounded -----------------------------------

# Unset, in the current (sub)shell, the variables through which the
# environment redirects or reconfigures Git: repository selectors,
# injected settings, tracing, defaults for new repositories.
_swarm_target_clear_env() {
    local v
    for v in "${!GIT_@}"; do
        case "$v" in
            GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY|\
            GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_INDEX_FILE|GIT_NAMESPACE|\
            GIT_SHALLOW_FILE|GIT_CONFIG|GIT_CONFIG_PARAMETERS|\
            GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|\
            GIT_TRACE*|GIT_CURL_VERBOSE|GIT_DEFAULT_REF_FORMAT|\
            GIT_DEFAULT_HASH|GIT_QUARANTINE_PATH|GIT_REFLOG_ACTION)
                unset "$v" ;;
        esac
    done
}

# Close, in the current (sub)shell, the engagement lock's descriptor
# (the one SWARM_LOCK_FD names, which swarm_lock validated), so that no
# Git process, helper or daemon holds the lock.
_swarm_target_close_lock() {
    local fd="${SWARM_LOCK_FD:-}"
    case "$fd" in
        ''|*[!0123456789]*) ;;
        *) [ "$fd" -lt 3 ] || eval "exec ${fd}>&-" ;;
    esac
    unset SWARM_LOCK_FD
}

# The perl part of every command: SIGALRM to its default action and
# unblocked (an inherited ignore or block would defeat the alarm), the
# alarm armed, then exec.  The alarm survives exec.
_SWARM_TARGET_ALARM='use POSIX ();
my $secs = shift @ARGV;
$SIG{ALRM} = "DEFAULT";
POSIX::sigprocmask(POSIX::SIG_UNBLOCK(),
    POSIX::SigSet->new(POSIX::SIGALRM())) or exit 126;
alarm($secs);
exec { $ARGV[0] } @ARGV;
print STDERR "cannot run $ARGV[0]: $!\n";
exit 127;'

# Settings every Git command of the resolution gets on its command line:
# no hooks, no fsmonitor, no automatic gc or maintenance, no commit-graph
# writing (Git's progress machinery would replace the alarm), no
# submodules, object checks on.
_SWARM_TARGET_GIT_C=(-c core.hooksPath=/dev/null -c core.fsmonitor=false
    -c gc.auto=0 -c maintenance.auto=false -c fetch.writeCommitGraph=false
    -c fetch.recurseSubmodules=no -c fetch.fsckObjects=true
    -c transfer.fsckObjects=true)

# Run git ARGS on repository GITDIR ($2) for the network, bounded by
# SECS ($1) seconds, in a subshell of its own.  The user's Git
# configuration stays (it holds the authentication), with no prompt of
# any kind, only the file, ssh and https transports (Git applies the
# list after url.insteadOf, and to redirects), no replace objects or
# grafts (the graft file named does not exist: an existing empty one
# would make Git print a deprecation notice), stdin closed.
# shellcheck disable=SC2030  # the environment is the subshell's own
_swarm_target_git_net() {
    local secs="$1" gitdir="$2" rc=0
    shift 2
    (
        _swarm_target_clear_env
        _swarm_target_close_lock
        export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' \
            SSH_ASKPASS_REQUIRE=never GIT_ALLOW_PROTOCOL=file:ssh:https \
            GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
            GIT_GRAFT_FILE="${SWARM_TARGET_TMP}/no-grafts"
        # An empty GIT_SSH_COMMAND or GIT_SSH counts as unset (Git
        # would run an empty command).
        [ -n "${GIT_SSH_COMMAND:-}" ] || unset GIT_SSH_COMMAND
        [ -n "${GIT_SSH:-}" ] || unset GIT_SSH
        if [ -z "${GIT_SSH_COMMAND+x}" ] && [ -z "${GIT_SSH+x}" ]; then
            perl -e "$_SWARM_TARGET_ALARM" -- "$secs" git \
                --git-dir="$gitdir" config --get core.sshCommand \
                > /dev/null 2>&1 < /dev/null || rc=$?
            case "$rc" in
                0) ;;
                1) export GIT_SSH_COMMAND='ssh -o BatchMode=yes' ;;
                *)
                    echo "cannot read core.sshCommand from the Git" \
                         "configuration (status ${rc})" >&2
                    exit 1 ;;
            esac
        fi
        exec perl -e "$_SWARM_TARGET_ALARM" -- "$secs" git \
            "${_SWARM_TARGET_GIT_C[@]}" -c http.followRedirects=initial \
            --git-dir="$gitdir" "$@" < /dev/null
    )
}

# Run git ARGS locally, on repository GITDIR ($3, or none when empty),
# bounded by SECS ($1) seconds, in a subshell of its own: from /, with
# no global or system configuration and only the transports PROTOCOLS
# ($2: empty for none, or file), stdin closed.
# shellcheck disable=SC2031  # the environment is the subshell's own
_swarm_target_git_local() {
    local secs="$1" protocols="$2" gitdir="$3"
    shift 3
    (
        _swarm_target_clear_env
        _swarm_target_close_lock
        unset GIT_CONFIG_SYSTEM
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            HOME="${SWARM_TARGET_TMP}/no-home" \
            XDG_CONFIG_HOME="${SWARM_TARGET_TMP}/no-home" \
            GIT_ALLOW_PROTOCOL="$protocols" GIT_TERMINAL_PROMPT=0 \
            GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
            GIT_GRAFT_FILE="${SWARM_TARGET_TMP}/no-grafts"
        cd / || exit 1
        exec perl -e "$_SWARM_TARGET_ALARM" -- "$secs" git \
            "${_SWARM_TARGET_GIT_C[@]}" ${gitdir:+"--git-dir=$gitdir"} \
            "$@" < /dev/null
    )
}

# Show the last lines of output file $1, printable characters only, with
# what could carry a credential masked, since a URL rewrite in the
# user's configuration can bring credentials the inputs never had: every
# URL, whole, up to the next space (Git's own anonymizing can leave a
# piece of a query looking like a host: https://h?t=a@SECRET becomes
# https://SECRET/), and, in any other word, what comes before its last @
# (a transport can print a piece of a URL on its own, as curl's "Could
# not resolve host: x@y").  The error says whose repository it was.
_swarm_target_show() {
    local url='[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*'
    [ -s "$1" ] || return 0
    tail -n 5 "$1" | LC_ALL=C tr -cd '[:print:]\n' \
        | sed -E -e "s|${url}|<masked-url>|g" \
            -e 's/(^|[[:space:]])[^[:space:]<]*@/\1<masked>@/g' \
        | cut -c 1-300 | sed 's/^/  /' >&2
}

# Report that WHAT ($2, a phrase) ended with status $1: past its bound
# of $4 seconds (SIGALRM), or failing with the output in $3 (or in $5
# when $3 is empty).
_swarm_target_failed() {
    local rc="$1" what="$2" err="$3" secs="$4" out="${5:-}"
    if [ "$rc" -eq 142 ]; then
        echo "ERROR: ${what} took longer than ${secs} seconds." >&2
        return 0
    fi
    echo "ERROR: ${what} failed (status ${rc})." >&2
    if [ -s "$err" ]; then
        _swarm_target_show "$err"
    elif [ -n "$out" ]; then
        _swarm_target_show "$out"
    fi
}

# Run git ARGS locally on repository $2 (none when empty, no transport),
# bounded by the local timeout, output in the temporary directory's out
# and err files; report a failure as WHAT ($1) failing.
_swarm_target_local() {
    local what="$1" dir="$2" rc=0
    shift 2
    _swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" "" "$dir" "$@" \
        > "$SWARM_TARGET_TMP/out" 2> "$SWARM_TARGET_TMP/err" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    _swarm_target_failed "$rc" "$what" "$SWARM_TARGET_TMP/err" \
        "$SWARM_TARGET_LOCAL_SECS" "$SWARM_TARGET_TMP/out"
    return 1
}

# ---- Resolution -------------------------------------------------------------

# Print "<full ref> <id>" for revision $3 (a name or a full ref) of
# variable $1 in repository $2, from one ls-remote through scratch
# repository $4, matching names exactly: a full ref as listed; a name as
# refs/heads/<name> or refs/tags/<name>, refusing when both or neither
# exist.  The resolution then fetches that id, never the name: Git
# expands a fetch source the remote does not have by its rules for
# abbreviated names, so refs/heads/<x> could bring
# refs/heads/refs/heads/<x>.  ($5 is the object format.)
_swarm_target_list() {
    local var="$1" repo="$2" rev="$3" gitdir="$4" format="$5" rc=0 ref
    local heads tags id len=40
    case "$rev" in
        refs/*)
            _swarm_target_git_net "$SWARM_TARGET_NET_SECS" "$gitdir" \
                ls-remote -- "$repo" "$rev" \
                > "$SWARM_TARGET_TMP/ls-remote" 2> "$SWARM_TARGET_TMP/err" \
                || rc=$? ;;
        *)
            _swarm_target_git_net "$SWARM_TARGET_NET_SECS" "$gitdir" \
                ls-remote -- "$repo" "refs/heads/$rev" "refs/tags/$rev" \
                > "$SWARM_TARGET_TMP/ls-remote" 2> "$SWARM_TARGET_TMP/err" \
                || rc=$? ;;
    esac
    if [ "$rc" -ne 0 ]; then
        _swarm_target_failed "$rc" "listing the refs of ${var}'s repository" \
            "$SWARM_TARGET_TMP/err" "$SWARM_TARGET_NET_SECS"
        return 1
    fi
    case "$rev" in
        refs/*) ref="$rev" ;;
        *)
            heads=$(_swarm_target_listed "refs/heads/$rev") || return 1
            tags=$(_swarm_target_listed "refs/tags/$rev") || return 1
            if [ -n "$heads" ] && [ -n "$tags" ]; then
                echo "ERROR: ${var} names both a branch and a tag (${rev});" \
                     "give refs/heads/${rev} or refs/tags/${rev}." >&2
                return 1
            elif [ -n "$heads" ]; then
                ref="refs/heads/$rev"
            elif [ -n "$tags" ]; then
                ref="refs/tags/$rev"
            else
                echo "ERROR: ${var} (${rev}) is no branch or tag of its" \
                     "repository; give a branch, a tag, a full ref or a full" \
                     "commit id." >&2
                return 1
            fi ;;
    esac
    id=$(_swarm_target_listed "$ref") || return 1
    if [ -z "$id" ]; then
        echo "ERROR: ${var} (${rev}) is no ref of its repository." >&2
        return 1
    fi
    [ "$format" = sha1 ] || len=64
    if ! swarm_target_full_id "$id" || [ "${#id}" -ne "$len" ]; then
        echo "ERROR: ${var}'s repository lists no ${format} id for ${ref}" \
             "(a repository of another object format?)." >&2
        return 1
    fi
    printf '%s %s\n' "$ref" "$id"
}

# Print the id the last ls-remote listed for exactly ref $1, or nothing.
_swarm_target_listed() {
    awk -v r="$1" '$2 == r { print $1; exit }' "$SWARM_TARGET_TMP/ls-remote"
}

# Fetch id $3 from repository $2 into scratch repository $4 as ref $5;
# $1 names the variable, $6 says what the id is for messages, and $7 is
# what to suggest when the server will not serve the id.
_swarm_target_fetch() {
    local var="$1" repo="$2" id="$3" dir="$4" ref="$5" what="$6" hint="$7"
    local rc=0
    _swarm_target_git_net "$SWARM_TARGET_NET_SECS" "$dir" fetch \
        --no-progress --no-tags --no-recurse-submodules \
        --no-write-fetch-head --quiet -- "$repo" "+${id}:${ref}" \
        > "$SWARM_TARGET_TMP/out" 2> "$SWARM_TARGET_TMP/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _swarm_target_failed "$rc" "fetching ${var} (${what})" \
            "$SWARM_TARGET_TMP/err" "$SWARM_TARGET_NET_SECS"
        [ "$rc" -eq 142 ] || echo "  (${hint})" >&2
        return 1
    fi
    # A fetch can succeed without the ref: from a shallow repository,
    # Git rejects it with a warning and still returns 0.
    if ! _swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" "" "$dir" \
            rev-parse --verify --quiet "$ref" > /dev/null 2>&1; then
        echo "ERROR: fetching ${var} (${what}) did not bring it:" >&2
        _swarm_target_show "$SWARM_TARGET_TMP/err"
        return 1
    fi
}

# Fetch revision $3 of variable $1 from repository $2 into scratch
# repository $4 as ref $5, for object format $6: a full id as it is; a
# name or a full ref through the id ls-remote lists for it.
_swarm_target_get() {
    local var="$1" repo="$2" rev="$3" dir="$4" ref="$5" format="$6" line
    local hint
    if swarm_target_full_id "$rev"; then
        hint="a server may refuse to serve a commit by id: give a branch"
        hint="${hint} or a tag that reaches it"
        _swarm_target_fetch "$var" "$repo" "$rev" "$dir" "$ref" "$rev" \
            "$hint"
        return
    fi
    line=$(_swarm_target_list "$var" "$repo" "$rev" "$dir" "$format") \
        || return 1
    _swarm_target_fetch "$var" "$repo" "${line#* }" "$dir" "$ref" \
        "${line% *} at ${line#* }" \
        "the ref may have moved since it was listed; try again"
}

# Make bare repository $1 with object format $2 and the files ref
# backend (named where Git knows the option, 2.45 and later: git init -h
# lists it, exiting with its usage status, 129).
_swarm_target_init() {
    local dir="$1" format="$2" rf="" rc=0
    _swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" "" "" init -h \
        > "$SWARM_TARGET_TMP/help" 2>&1 || rc=$?
    case "$rc" in
        0|129) ;;
        *)
            _swarm_target_failed "$rc" "asking git init for its options" \
                "$SWARM_TARGET_TMP/help" "$SWARM_TARGET_LOCAL_SECS"
            return 1 ;;
    esac
    if grep -q -e '--ref-format' "$SWARM_TARGET_TMP/help"; then
        rf="--ref-format=files"
    fi
    # shellcheck disable=SC2086  # rf is one option or nothing
    _swarm_target_local "creating ${dir}" "" init -q --bare --template= \
        --object-format="$format" $rf "$dir"
}

# Print the commit that ref $4 of repository $3 peels to, refusing
# anything else ($1 names the variable, $2 its value, $5 the format).
_swarm_target_peel() {
    local var="$1" rev="$2" dir="$3" ref="$4" format="$5" id rc=0 len=40
    id=$(_swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" "" "$dir" \
        rev-parse --verify --quiet "${ref}^{commit}" \
        2> "$SWARM_TARGET_TMP/err") || rc=$?
    case "$rc" in
        0) ;;
        1)
            echo "ERROR: ${var} (${rev}) is not a commit, nor a tag of" \
                 "one." >&2
            return 1 ;;
        *)
            _swarm_target_failed "$rc" "reading ${var}'s commit" \
                "$SWARM_TARGET_TMP/err" "$SWARM_TARGET_LOCAL_SECS"
            return 1 ;;
    esac
    [ "$format" = sha1 ] || len=64
    if ! swarm_target_full_id "$id" || [ "${#id}" -ne "$len" ]; then
        echo "ERROR: reading ${var}'s commit gave no ${format} id." >&2
        return 1
    fi
    printf '%s\n' "$id"
}

# Refuse revision $2 of variable $1 when it is a full id of the other
# object format than $3's: Git takes a string of the wrong length for a
# ref name, so a branch or tag of that name would stand in for it.
_swarm_target_id_fits() {
    local var="$1" rev="$2" format="$3" len=40
    swarm_target_full_id "$rev" || return 0
    [ "$format" = sha1 ] || len=64
    [ "${#rev}" -ne "$len" ] || return 0
    echo "ERROR: ${var} is a ${#rev}-digit commit id, but this" \
         "checkout's objects are ${format} (${len}-digit ids)." >&2
    return 1
}

# Delete every scratch directory an earlier run left in runtime
# directory $1, best effort (a helper of a killed run may still write
# into one; it is garbage either way), and name those that stay.  One
# with something mounted at or under it, or when the mount table cannot
# be read, stays (swarm_mounts_under and swarm_path_resolve, from
# lib/project.sh).
swarm_target_scratch_clean() {
    local dir="$1" d canon found
    for d in "$dir"/.target-fetch.* "$dir"/.target-prep.*; do
        [ -e "$d" ] || [ -L "$d" ] || continue
        if [ -L "$d" ] || [ ! -d "$d" ]; then
            echo "WARNING: ${d} is not a directory; left alone." >&2
            continue
        fi
        if ! canon=$(swarm_path_resolve "$d") \
                || ! found=$(swarm_mounts_under "$canon" at); then
            echo "WARNING: cannot read this host's mount table; ${d}" \
                 "left alone." >&2
            continue
        fi
        if [ -n "$found" ]; then
            echo "WARNING: something is mounted in ${d}; left alone." >&2
            continue
        fi
        rm -rf -- "$d" 2>/dev/null || true
        if [ -e "$d" ]; then
            echo "WARNING: cannot delete ${d} yet (a target fetch of an" \
                 "earlier run may still write into it); a later run" \
                 "tries again." >&2
        fi
    done
}

# Resolve the target (swarm_target_inputs_check first) into a new
# snapshot in runtime directory $1 for a checkout of object format $2
# (sha1 or sha256).  On success set
#   SWARM_TARGET_PREP                the snapshot, ready to be renamed
#   SWARM_TARGET_COMMIT              TARGET_REV's commit
#   SWARM_TARGET_BASE_COMMIT         TARGET_REV_BASE's commit, or empty
#   SWARM_TARGET_REPO_PHYSICAL       TARGET_REPO's physical path (a URL
#                                    as given)
#   SWARM_TARGET_BASE_REPO_PHYSICAL  the same for the base, or empty
# and return 0.  On failure nothing of the attempt is left (best effort)
# and it returns 1; a retry starts with new directories.
swarm_target_resolve() {
    local runtime="$1" format="$2" fetchdir="" prepdir="" rc=0
    SWARM_TARGET_PREP=""
    SWARM_TARGET_COMMIT=""
    SWARM_TARGET_BASE_COMMIT=""
    case "$runtime" in
        /*) ;;
        *)
            echo "ERROR: the runtime directory must be absolute:" \
                 "${runtime}" >&2
            return 1 ;;
    esac
    case "$format" in
        sha1|sha256) ;;
        *)
            echo "ERROR: unknown object format: ${format}" >&2
            return 1 ;;
    esac
    _swarm_target_id_fits TARGET_REV "$TARGET_REV" "$format" || return 1
    if [ -n "${SWARM_TARGET_BASE_REPO_EFFECTIVE:-}" ]; then
        _swarm_target_id_fits TARGET_REV_BASE "$TARGET_REV_BASE" "$format" \
            || return 1
    fi
    SWARM_TARGET_NET_SECS=$(swarm_target_seconds SWARM_TARGET_TIMEOUT \
        "${SWARM_TARGET_TIMEOUT:-300}") || return 1
    SWARM_TARGET_LOCAL_SECS=$(swarm_target_seconds \
        SWARM_TARGET_VERIFY_TIMEOUT "${SWARM_TARGET_VERIFY_TIMEOUT:-600}") \
        || return 1
    if ! command -v perl >/dev/null 2>&1; then
        echo "ERROR: perl is required to resolve a target (it bounds" \
             "each Git command); install it." >&2
        return 1
    fi
    SWARM_TARGET_REPO_PHYSICAL=$(swarm_target_physical "$TARGET_REPO") \
        || return 1
    SWARM_TARGET_BASE_REPO_PHYSICAL=""
    if [ -n "${SWARM_TARGET_BASE_REPO_EFFECTIVE:-}" ]; then
        SWARM_TARGET_BASE_REPO_PHYSICAL=$(swarm_target_physical \
            "$SWARM_TARGET_BASE_REPO_EFFECTIVE") || return 1
    fi
    SWARM_TARGET_TMP=$(mktemp -d "${TMPDIR:-/tmp}/swarm-target.XXXXXX") \
        || {
        echo "ERROR: cannot make a temporary directory." >&2
        return 1
    }
    if ! fetchdir=$(mktemp -d "$runtime/.target-fetch.XXXXXX" 2>/dev/null) \
            || ! prepdir=$(mktemp -d "$runtime/.target-prep.XXXXXX" \
                2>/dev/null); then
        echo "ERROR: cannot make a scratch directory in ${runtime}." >&2
        rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        _swarm_target_resolve_in "$fetchdir" "$prepdir" "$format" || rc=1
    fi
    rm -rf -- "$SWARM_TARGET_TMP" 2>/dev/null || true
    [ -z "$fetchdir" ] || rm -rf -- "$fetchdir" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        [ -z "$prepdir" ] || rm -rf -- "$prepdir" 2>/dev/null || true
        return 1
    fi
    # shellcheck disable=SC2034  # read by the caller
    SWARM_TARGET_PREP="$prepdir"
}

# The body of swarm_target_resolve: network fetch into scratch $1, local
# fetch into snapshot $2, object format $3.
_swarm_target_resolve_in() {
    local fetchdir="$1" prepdir="$2" format="$3" refspecs rc=0
    local pin=refs/swarm/fetch/target base_pin=refs/swarm/fetch/target-base
    _swarm_target_init "$fetchdir" "$format" || return 1
    _swarm_target_init "$prepdir" "$format" || return 1
    _swarm_target_get TARGET_REV "$SWARM_TARGET_REPO_PHYSICAL" \
        "$TARGET_REV" "$fetchdir" "$pin" "$format" || return 1
    refspecs="+${pin}:${pin}"
    if [ -n "${SWARM_TARGET_BASE_REPO_EFFECTIVE:-}" ]; then
        if [ "$SWARM_TARGET_BASE_REPO_PHYSICAL" = \
                "$SWARM_TARGET_REPO_PHYSICAL" ] \
                && [ "$TARGET_REV_BASE" = "$TARGET_REV" ]; then
            # The same repository and revision: one fetch serves both.
            refspecs="$refspecs +${pin}:${base_pin}"
        else
            _swarm_target_get TARGET_REV_BASE \
                "$SWARM_TARGET_BASE_REPO_PHYSICAL" "$TARGET_REV_BASE" \
                "$fetchdir" "$base_pin" "$format" || return 1
            refspecs="$refspecs +${base_pin}:${base_pin}"
        fi
    fi
    # The snapshot gets its objects through a local fetch of its own,
    # waited for to the end; the directory the network wrote to is never
    # published.
    # shellcheck disable=SC2086  # one or two refspecs
    _swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" file "$prepdir" \
        fetch --no-progress --no-tags --no-recurse-submodules \
        --no-write-fetch-head --quiet -- "$fetchdir" $refspecs \
        > "$SWARM_TARGET_TMP/out" 2> "$SWARM_TARGET_TMP/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _swarm_target_failed "$rc" "copying the target into its snapshot" \
            "$SWARM_TARGET_TMP/err" "$SWARM_TARGET_LOCAL_SECS"
        return 1
    fi
    SWARM_TARGET_COMMIT=$(_swarm_target_peel TARGET_REV "$TARGET_REV" \
        "$prepdir" "$pin" "$format") || return 1
    if [ -n "${SWARM_TARGET_BASE_REPO_EFFECTIVE:-}" ]; then
        SWARM_TARGET_BASE_COMMIT=$(_swarm_target_peel TARGET_REV_BASE \
            "$TARGET_REV_BASE" "$prepdir" "$base_pin" "$format") \
            || return 1
    fi
    _swarm_target_seal "$prepdir"
}

# Leave in snapshot $1 only refs/swarm/target (and refs/swarm/target-base)
# pointing directly at the commits, no fetch traces and no object
# storage outside it; check it with git fsck; make it readable by any
# container user.  Storage outside the snapshot is refused before any
# Git command reads it.
_swarm_target_seal() {
    local dir="$1" r rc=0
    for r in shallow commondir objects/info/alternates \
            objects/info/http-alternates; do
        if [ -e "$dir/$r" ] || [ -L "$dir/$r" ]; then
            echo "ERROR: the target's snapshot has ${r}; refused." >&2
            return 1
        fi
    done
    if ! find "$dir/objects/pack" -mindepth 1 -maxdepth 1 \
            -name '*.promisor' -print > "$SWARM_TARGET_TMP/promisor" \
            2>/dev/null; then
        echo "ERROR: cannot list the snapshot's packs." >&2
        return 1
    fi
    if [ -s "$SWARM_TARGET_TMP/promisor" ]; then
        echo "ERROR: the target's snapshot has a promisor pack (a partial" \
             "clone); refused." >&2
        return 1
    fi
    _swarm_target_git_local "$SWARM_TARGET_LOCAL_SECS" "" "$dir" config \
        --get-regexp '^(extensions\.partialclone|remote\..*)$' \
        > /dev/null 2> "$SWARM_TARGET_TMP/err" || rc=$?
    case "$rc" in
        1) ;;
        0)
            echo "ERROR: the target's snapshot has a remote or a partial" \
                 "clone setting; refused." >&2
            return 1 ;;
        *)
            _swarm_target_failed "$rc" "reading the snapshot's config" \
                "$SWARM_TARGET_TMP/err" "$SWARM_TARGET_LOCAL_SECS"
            return 1 ;;
    esac
    _swarm_target_local "pinning TARGET_REV" "$dir" update-ref --no-deref \
        refs/swarm/target "$SWARM_TARGET_COMMIT" || return 1
    if [ -n "$SWARM_TARGET_BASE_COMMIT" ]; then
        _swarm_target_local "pinning TARGET_REV_BASE" "$dir" update-ref \
            --no-deref refs/swarm/target-base "$SWARM_TARGET_BASE_COMMIT" \
            || return 1
    fi
    _swarm_target_local "listing the snapshot's refs" "$dir" for-each-ref \
        --format='%(refname)' || return 1
    cp "$SWARM_TARGET_TMP/out" "$SWARM_TARGET_TMP/refs" || return 1
    while IFS= read -r r; do
        case "$r" in
            refs/swarm/target) continue ;;
            refs/swarm/target-base)
                [ -z "$SWARM_TARGET_BASE_COMMIT" ] || continue ;;
        esac
        _swarm_target_local "deleting ${r} from the snapshot" "$dir" \
            update-ref --no-deref -d "$r" || return 1
    done < "$SWARM_TARGET_TMP/refs"
    rm -rf -- "$dir/FETCH_HEAD" "$dir/ORIG_HEAD" "$dir/logs" 2>/dev/null \
        || true
    for r in FETCH_HEAD ORIG_HEAD logs; do
        if [ -e "$dir/$r" ] || [ -L "$dir/$r" ]; then
            echo "ERROR: cannot delete ${dir}/${r}." >&2
            return 1
        fi
    done
    _swarm_target_local "checking the snapshot (git fsck)" "$dir" fsck \
        --full --no-progress --no-dangling || return 1
    if ! chmod -R a+rX "$dir" 2>/dev/null; then
        echo "ERROR: cannot make ${dir} readable." >&2
        return 1
    fi
}
