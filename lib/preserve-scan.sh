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
# Report lines:
#   empty                          ROOT has no files at all
#   gitdir <n> <path>              a git dir, relative to ROOT
#   block <what> <detail>          content the bundle cannot carry
#   uncommitted <what> <detail>    content outside Git's history that
#                                  only an explicit discard may drop
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
# core.worktree outside, a mismatched worktree, a common dir elsewhere;
# the scan then stops there, with no bundle); 3 when the scan cannot
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

report() {
    printf '%s\n' "$*" >> "$REPORT"
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
# referenced by refs/v/0/f/<k>, with the list "<k> <mode> <size> <path>"
# (NUL-terminated, paths relative to TOP) as refs/v/0/files.  A file
# over the size limits is reported as uncommitted instead, unless its
# path relative to TOP starts with ALWAYS/ (files mode keeps objects/
# whatever its size); such files do not count toward the total.  Any
# other kind of file fails the scan.
store_files() {
    local top="$1" always="$2" f rel target blob size mode files keep
    local k=0 total=0
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
            printf 'update refs/v/0/f/%s %s\n' "$k" "$blob" >> "$OUT/.fupd"
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
                    || [ $((total + size)) -gt "$TOTAL_LIMIT" ]; then
                report "uncommitted large-file ${f#"$ROOT"/} ${size}"
                continue
            fi
            total=$((total + size))
        fi
        k=$((k + 1))
        blob=$(git --git-dir="$SCRATCH" hash-object -w --no-filters --stdin \
            < "$f") || fail "cannot store ${f}"
        mode=100644
        [ ! -x "$f" ] || mode=100755
        printf 'update refs/v/0/f/%s %s\n' "$k" "$blob" >> "$OUT/.fupd"
        printf '%s %s %s %s\0' "$k" "$mode" "$size" "$rel" >> "$OUT/.files"
    done < "$OUT/.fkeep"
    git --git-dir="$SCRATCH" update-ref --stdin < "$OUT/.fupd" 2>"$ERR" \
        || fail "cannot record the files of ${top}: $(cat "$ERR")"
    files=$(git --git-dir="$SCRATCH" hash-object -w --stdin \
        < "$OUT/.files") || fail "cannot write the file list of ${top}"
    git --git-dir="$SCRATCH" update-ref refs/v/0/files "$files"
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
    store_files "$ROOT" objects
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
    # The files Git reads for its global and system settings, as the
    # git on this PATH names them: a git built with another prefix
    # reads its system file elsewhere than /etc/gitconfig.  A git that
    # cannot name them (older than 2.42, or stopped by a config file it
    # cannot parse) is refused, with its first message.
    if ! git var GIT_CONFIG_GLOBAL > "$OUT/.uf" 2>"$OUT/.ue" \
            || ! git var GIT_CONFIG_SYSTEM >> "$OUT/.uf" 2>>"$OUT/.ue" \
            || [ -s "$OUT/.ue" ]; then
        report "block config-paths-unknown $(oneline "$(head -n 1 "$OUT/.ue")")"
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
        git config -f "$r" --name-only --get-regexp \
            '^(lfs\.storage|core\.worktree|core\.hookspath|include\..*|includeif\..*)$' \
            > "$OUT/.uk" 2>"$OUT/.ue" || rc=$?
        if [ -s "$OUT/.ue" ]; then
            report "block config-unreadable $(oneline "$f")"
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
    # find prints one x per entry, whatever bytes the names hold.
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

# TOP as a find -path pattern: *, ?, [ and \ in it match only themselves.
TOP_PAT=$(printf '%s' "$TOP" | sed 's/[][*?\\]/\\&/g')

# Set when a git dir or a repository below ROOT cannot be checked (its
# path holds a newline): git status must not run then.
UNCHECKED_REPO=""
GITDIRS="$OUT/.gitdirs"
list_gitdirs "$TOP" > "$GITDIRS"
grep -qx "$TOP" "$GITDIRS" || printf '%s\n' "$TOP" >> "$GITDIRS"

# Git follows a config include wherever it points, and opening a FIFO
# there would hang the scan.  Before any git command reads a git dir's
# config, each of its config files must be a regular file that
# includes no other; one that is not stops the scan.
_cfg_stop=""
while IFS= read -r d; do
    rel="${d#"$ROOT"/}"
    for cf in "$d/config" "$d/config.worktree"; do
        [ -e "$cf" ] || [ -L "$cf" ] || continue
        if [ ! -f "$cf" ]; then
            report "block config-unreadable $(oneline "${cf#"$ROOT"/}")"
            _cfg_stop=yes
            continue
        fi
        rc=0
        git config -f "$cf" --name-only --get-regexp \
            '^(include|includeif)\.' > "$OUT/.inc" 2>/dev/null || rc=$?
        case "$rc" in
            0)
                report "block config-include ${rel}"
                _cfg_stop=yes ;;
            1) ;;
            *) fail "cannot parse ${cf}" ;;
        esac
    done
done < "$GITDIRS"
[ -z "$_cfg_stop" ] || exit 0

# Unsupported layouts that keep history outside these git dirs.
while IFS= read -r d; do
    [ ! -f "$d/shallow" ] || report "block shallow ${d#"$ROOT"/}"
    _lfs=$(git --git-dir="$d" -c safe.directory='*' config \
        --get lfs.storage 2>/dev/null || true)
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
            # Includes stopped the scan above.  A filter driver is a
            # command Git runs on work-tree files (git status can run a
            # clean filter): it would run inside this scan.  It blocks
            # rather than being switched off, which would make every
            # filtered file look modified.
            rc=0
            git config -f "$cf" --name-only --get-regexp '^filter\.' \
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
            git config -f "$cf" --get core.hooksPath >/dev/null 2>&1 \
                || rc=$?
            case "$rc" in
                0) report "block core-hookspath ${rel}" ;;
                1) ;;
                *) fail "cannot parse ${cf}" ;;
            esac
            # core.worktree is relative to the git dir; submodule git
            # dirs set it to their checkout inside ROOT.
            rc=0
            wtv=$(git config -f "$cf" --get core.worktree 2>/dev/null \
                && printf x) || rc=$?
            # git prints the value and a newline; any other newline is
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
                    # A work tree inside the git dir is out of sight of
                    # the search for repositories below ROOT (it skips
                    # the git dir), and status would go there.
                    case "$wtc" in
                        "$TOP"|"$TOP"/*)
                            report "block gitdir-worktree ${rel} ${wtv}" ;;
                        "$ROOT"|"$ROOT"/*) ;;
                        *) report "block core-worktree ${rel} ${wtv}" ;;
                    esac ;;
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

# Work-tree content outside Git's history, for the checkout at $1 with
# git dir $3 ($2 is its path in the report).  Both are passed
# explicitly, so a core.worktree setting cannot point status elsewhere.
# Status is read NUL-separated (-z), so paths come unquoted and whole.
check_checkout() {
    local wt="$1" rel="$2" gd="$3" rec xy path
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
        report "uncommitted dirty ${rel}: ${xy} $(oneline "$path")"
    done < "$OUT/.st"
    gw "$wt" --git-dir="$gd" --work-tree="$wt" status --porcelain=v1 -z \
        --no-renames --untracked-files=all --ignored=matching \
        --ignore-submodules=all > "$OUT/.st"
    while IFS= read -r -d '' rec; do
        [ "${rec:0:3}" = "!! " ] || continue
        path="${rec:3}"
        engine_entry "!!" "$rel" "$path" && continue
        engine_dir_only "$wt" "$rel" "$path" && continue
        report "uncommitted ignored ${rel}: $(oneline "$path")"
    done < "$OUT/.st"
    gw "$wt" --git-dir="$gd" --work-tree="$wt" ls-files -v -z > "$OUT/.ls"
    while IFS= read -r -d '' rec; do
        case "${rec:0:1}" in
            [a-z]|S) report "uncommitted hidden ${rel}: ${rec:0:1} $(oneline "${rec:2}")" ;;
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
        find "$wt/$path" -mindepth 1 ! -type d -print0 2>"$ERR" \
            > "$OUT/.glf" || fail "cannot list ${wt}/${path}"
        [ ! -s "$ERR" ] || fail "cannot list ${wt}/${path}: $(cat "$ERR")"
        while IFS= read -r -d '' f; do
            report "uncommitted dirty ${rel}: ?? $(oneline "${f#"$wt"/}")"
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
    printf '%s\0%s\0%s\0' "$1" "$2" "$3" >> "$OUT/.checkouts"
}

if [ "$MODE" = worktree ]; then
    : > "$OUT/.checkouts"
    # Every other .git below ROOT must be a submodule checkout whose git
    # dir lives in ROOT/.git; anything else is a repository the bundle
    # does not see.  This is checked before git status runs: status
    # looks into submodules (--ignore-submodules=none) with the config
    # of whatever git dir their .git names.
    find "$ROOT" -path "$TOP_PAT" -prune -o -name .git -print0 2>"$ERR" \
        > "$OUT/.embedded" || fail "cannot list ${ROOT}"
    [ ! -s "$ERR" ] || fail "cannot list ${ROOT}: $(cat "$ERR")"
    while IFS= read -r -d '' e; do
        wt="${e%/.git}"
        rel="${wt#"$ROOT"/}"
        case "$rel" in
            *$'\n'*)
                report "block newline-path $(printf '%s' "$rel" \
                    | awk 'BEGIN { ORS = "\\n" } { print }')"
                UNCHECKED_REPO=yes
                continue ;;
        esac
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
            case "$target" in
                "$TOP"/worktrees/*)
                    # A linked worktree's own admin dir (one level below
                    # worktrees/, with its gitdir back-pointer) is
                    # checked with the others below.  Anything deeper,
                    # such as a module repo of a linked worktree, is a
                    # submodule checkout and is checked here.
                    _rest="${target#"$TOP"/worktrees/}"
                    case "$_rest" in
                        */*) ;;
                        *)
                            if [ -f "$target/gitdir" ] \
                                    && grep -qxF "$target" "$GITDIRS"; then
                                # Only when its back-pointer names this
                                # checkout; a copied worktree dir points
                                # at another one and is not checked
                                # there.
                                if has_nul "$target/gitdir"; then
                                    report "block mismatched-worktree $(oneline "$rel")"
                                    continue
                                fi
                                bp=$(cat "$target/gitdir")
                                case "$bp" in
                                    /*) ;;
                                    *) bp="$target/$bp" ;;
                                esac
                                bpwt=$(canon "${bp%/.git}") || bpwt=""
                                wtc=$(canon "$wt") || wtc="-"
                                if [ "$bpwt" = "$wtc" ]; then
                                    continue
                                fi
                                report "block mismatched-worktree ${rel}"
                                continue
                            fi ;;
                    esac
                    case "$_rest" in
                        */*)
                            if grep -qxF "$target" "$GITDIRS"; then
                                queue_checkout "$wt" "$rel" "$target"
                                continue
                            fi ;;
                    esac ;;
                "$TOP"/*)
                    # Only a git dir this scan checked (in GITDIRS).
                    if grep -qxF "$target" "$GITDIRS"; then
                        queue_checkout "$wt" "$rel" "$target"
                        continue
                    fi ;;
            esac
        fi
        report "block embedded ${rel}"
    done < "$OUT/.embedded"
    # A repository directory anywhere else below ROOT (a bare clone, a
    # copied .git under another name) holds history the bundle does not
    # carry: it blocks, whatever filters would apply to its files.
    find "$ROOT" -path "$TOP_PAT" -prune -o \( -type f -o -type l \) \
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

    # Linked worktrees: inside ROOT they are checked like any checkout;
    # outside it (a container's /tmp) their files are not in the volume.
    while IFS= read -r d; do
        [ -f "$d/gitdir" ] || continue
        if has_nul "$d/gitdir"; then
            report "block missing-worktree $(oneline "${d#"$ROOT"/}") (unreadable or NUL byte)"
            continue
        fi
        wtgit=$(cat "$d/gitdir")
        # The back-pointer is relative to this admin dir when the
        # worktree was added with --relative-paths.
        case "$wtgit" in
            /*) ;;
            *) wtgit="$d/$wtgit" ;;
        esac
        wt="${wtgit%/.git}"
        if ! wt=$(canon_nm "$wt"); then
            report "block missing-worktree ${wtgit%/.git}"
            continue
        fi
        case "$wt" in
            "$TOP"|"$TOP"/*) report "block gitdir-worktree ${wt#"$ROOT"/}" ;;
            "$ROOT"/*) queue_checkout "$wt" "${wt#"$ROOT"/}" "$d" ;;
            *) report "block external ${wt}" ;;
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
    check_index_paths "$ROOT" "." "$TOP"
    while IFS= read -r -d '' wt && IFS= read -r -d '' rel \
            && IFS= read -r -d '' gd; do
        check_index_paths "$wt" "$rel" "$gd"
    done < "$OUT/.checkouts"
    if [ -n "$UNCHECKED_REPO" ] \
            || grep -qE '^block (filter-driver|config-include|embedded|core-worktree|gitdir-worktree|index-in-gitdir|mismatched-worktree|commondir) ' \
            "$REPORT"; then
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

list_files "$TOP" "$EXEMPT"
store_files "$TOP" ""

# ---- Bundle -------------------------------------------------------------

make_bundle
exit 0
