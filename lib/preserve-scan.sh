#!/bin/bash
# Inventory one repository location and pack everything Git keeps there
# into a bundle, so cleanup can copy it into the checkout before it
# deletes the location.  Runs on the host for the bare repo and the
# mirrors, and inside a throwaway container (volume mounted read-only)
# for a workspace.  It only reads ROOT.
#
# Usage: preserve-scan.sh worktree ROOT CONTEXT OUT
#        preserve-scan.sh gitdir ROOT - OUT
#
# worktree: ROOT is a checkout (a workspace) whose repository is
#   ROOT/.git; CONTEXT (full, slim or none) says which deletions under
#   .claude the engine made itself.
# gitdir: ROOT is a repository directory (a bare repo or a mirror).
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
# Exit status: 0 when the report and bundle are complete, 3 when the
# scan cannot tell (message on stderr).  Compatible with Bash 3.2.

set -euo pipefail

# Git's own environment must not redirect anything this scan reads.
for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$_v"
done
# Replacement objects and grafts would make Git walk parents a commit
# does not have, so objects could look reached that the bundle lacks.
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
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
    worktree|gitdir) ;;
    *) fail "unknown mode: ${MODE}" ;;
esac
[ -d "$ROOT" ] || fail "not a directory: ${ROOT}"
[ -d "$OUT" ] || fail "not a directory: ${OUT}"
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

# Git records worktree paths resolved; compare against the same form.
ROOT=$(canon "$ROOT") || fail "cannot resolve ${2:-}, or it holds a newline"
_entries=$(ls -A "$OUT") || fail "cannot list ${OUT}"
[ -z "$_entries" ] || fail "output directory is not empty: ${OUT}"

ERR="$OUT/.err"
REPORT="$OUT/report"
SCRATCH="$OUT/scratch.git"
: > "$REPORT"

# Run git on git dir $1 with the settings every read here needs, and
# fail the scan on a non-zero exit or on anything it writes to stderr.
g() {
    local dir="$1"
    shift
    if ! git --git-dir="$dir" -c safe.directory='*' \
            -c core.fsmonitor=false -c core.untrackedCache=false \
            -c advice.graftFileDeprecated=false --no-optional-locks \
            "$@" 2>"$ERR"; then
        fail "git $* in ${dir} failed: $(cat "$ERR")"
    fi
    [ ! -s "$ERR" ] || fail "git $* in ${dir}: $(cat "$ERR")"
}

# The same for a work tree $1 whose git dir Git finds itself.
gw() {
    local dir="$1"
    shift
    if ! git -C "$dir" -c safe.directory='*' \
            -c core.fsmonitor=false -c core.untrackedCache=false \
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
        # the newlines as \n).
        case "$d" in
            *$'\n'*)
                report "block newline-path $(printf '%s' "${d#"$ROOT"/}" \
                    | awk 'BEGIN { ORS = "\\n" } { print }')"
                continue ;;
        esac
        printf '%s\n' "$d"
    done < "$OUT/.heads"
}

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
    if [ -L "$ROOT/.git" ] || [ ! -e "$ROOT/.git" ]; then
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

GITDIRS="$OUT/.gitdirs"
list_gitdirs "$TOP" > "$GITDIRS"
grep -qx "$TOP" "$GITDIRS" || printf '%s\n' "$TOP" >> "$GITDIRS"

# Unsupported layouts that keep history outside these git dirs.
while IFS= read -r d; do
    [ ! -f "$d/shallow" ] || report "block shallow ${d#"$ROOT"/}"
    _lfs=$(git --git-dir="$d" -c safe.directory='*' config \
        --get lfs.storage 2>/dev/null || true)
    [ -z "$_lfs" ] || report "block lfs-storage ${d#"$ROOT"/} ${_lfs}"
done < "$GITDIRS"

# Print path $1 on one line, newlines shown as \n.
oneline() {
    printf '%s' "$1" | awk 'BEGIN { ORS = "\\n" } { print }' \
        | sed 's/\\n$//'
}

# Engine files and the deletions the context mode makes: in the
# workspace's own checkout ($2 = "."), where the engine writes those
# paths, entry XY PATH ($1, $3) is not work.  In submodules and
# worktrees it is.
engine_entry() {
    local xy="$1" rel="$2" path="$3"
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

# Work-tree content outside Git's history, for the checkout at $1 with
# git dir $3 ($2 is its path in the report).  Both are passed
# explicitly, so a core.worktree setting cannot point status elsewhere.
# Status is read NUL-separated (-z), so paths come unquoted and whole.
check_checkout() {
    local wt="$1" rel="$2" gd="$3" rec xy path
    # No rename detection: a rename record would hide its new path from
    # the filters below.
    gw "$wt" --git-dir="$gd" --work-tree="$wt" status --porcelain=v1 -z \
        --no-renames --untracked-files=all --ignore-submodules=none \
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
        report "uncommitted ignored ${rel}: $(oneline "$path")"
    done < "$OUT/.st"
    gw "$wt" --git-dir="$gd" --work-tree="$wt" ls-files -v -z > "$OUT/.ls"
    while IFS= read -r -d '' rec; do
        case "${rec:0:1}" in
            [a-z]|S) report "uncommitted hidden ${rel}: ${rec:0:1} $(oneline "${rec:2}")" ;;
        esac
    done < "$OUT/.ls"
}

if [ "$MODE" = worktree ]; then
    check_checkout "$ROOT" "." "$TOP"
    # Every other .git below ROOT must be a submodule checkout whose git
    # dir lives in ROOT/.git; anything else is a repository the bundle
    # does not see.
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
                continue ;;
        esac
        if [ -f "$e" ] && [ ! -L "$e" ]; then
            target=$(sed -n 's/^gitdir: //p' "$e")
            case "$target" in
                /*) ;;
                *) target="$wt/$target" ;;
            esac
            target=$(canon "$target") || target=""
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
                                check_checkout "$wt" "$rel" "$target"
                                continue
                            fi ;;
                    esac ;;
                "$TOP"/*)
                    check_checkout "$wt" "$rel" "$target"
                    continue ;;
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
                    | awk 'BEGIN { ORS = "\\n" } { print }')" ;;
            *) report "block embedded ${rel}" ;;
        esac
    done < "$OUT/.otherheads"

    # Linked worktrees: inside ROOT they are checked like any checkout;
    # outside it (a container's /tmp) their files are not in the volume.
    while IFS= read -r d; do
        [ -f "$d/gitdir" ] || continue
        wtgit=$(cat "$d/gitdir")
        # The back-pointer is relative to this admin dir when the
        # worktree was added with --relative-paths.
        case "$wtgit" in
            /*) ;;
            *) wtgit="$d/$wtgit" ;;
        esac
        wt="${wtgit%/.git}"
        if ! wt=$(canon "$wt"); then
            report "block missing-worktree ${wtgit%/.git}"
            continue
        fi
        case "$wt" in
            "$ROOT"/*) check_checkout "$wt" "${wt#"$ROOT"/}" "$d" ;;
            *) report "block external ${wt}" ;;
        esac
    done < "$GITDIRS"
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
        common=$(cat "$d/commondir")
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

# Paths are read NUL-separated, so any byte in a name survives.  A path
# with a newline in it is never exempt (exempt names are hex).
: > "$OUT/.flist"
: > "$OUT/.fnl"
find "$TOP" ! -type d -print0 2>"$ERR" > "$OUT/.flist0" \
    || fail "cannot list ${TOP}"
[ ! -s "$ERR" ] || fail "cannot list ${TOP}: $(cat "$ERR")"
while IFS= read -r -d '' f; do
    case "$f" in
        *$'\n'*) printf '%s\0' "$f" >> "$OUT/.fnl" ;;
        *) printf '%s\n' "$f" >> "$OUT/.flist" ;;
    esac
done < "$OUT/.flist0"
sort "$OUT/.flist" -o "$OUT/.flist"
comm -23 "$OUT/.flist" "$EXEMPT" | tr '\n' '\0' > "$OUT/.fkeep"
cat "$OUT/.fnl" >> "$OUT/.fkeep"
: > "$OUT/.files"
: > "$OUT/.fupd"
k=0
total=0
while IFS= read -r -d '' f; do
    rel="${f#"$TOP"/}"
    if [ -L "$f" ]; then
        # readlink -n prints the target as is; the x keeps a trailing
        # newline of the target from command substitution.
        target=$(readlink -n "$f" && printf x) || fail "cannot read ${f}"
        target="${target%x}"
        k=$((k + 1))
        blob=$(printf '%s' "$target" \
            | git --git-dir="$SCRATCH" hash-object -w --stdin) \
            || fail "cannot store ${f}"
        printf 'update refs/v/0/f/%s %s\n' "$k" "$blob" >> "$OUT/.fupd"
        printf '%s 120000 0 %s\0' "$k" "$rel" >> "$OUT/.files"
        continue
    fi
    [ -f "$f" ] || fail "special file in a git dir: ${f}"
    size=$(fsize "$f") || fail "cannot read ${f}"
    if [ "$size" -gt "$FILE_LIMIT" ] \
            || [ $((total + size)) -gt "$TOTAL_LIMIT" ]; then
        report "uncommitted large-file ${f#"$ROOT"/} ${size}"
        continue
    fi
    total=$((total + size))
    k=$((k + 1))
    blob=$(git --git-dir="$SCRATCH" hash-object -w --no-filters --stdin \
        < "$f") || fail "cannot store ${f}"
    mode=100644
    [ ! -x "$f" ] || mode=100755
    printf 'update refs/v/0/f/%s %s\n' "$k" "$blob" >> "$OUT/.fupd"
    printf '%s %s %s %s\0' "$k" "$mode" "$size" "$rel" >> "$OUT/.files"
done < "$OUT/.fkeep"
git --git-dir="$SCRATCH" update-ref --stdin < "$OUT/.fupd" 2>"$ERR" \
    || fail "cannot record the files of ${TOP}: $(cat "$ERR")"
files=$(git --git-dir="$SCRATCH" hash-object -w --stdin < "$OUT/.files") \
    || fail "cannot write the file list of ${TOP}"
git --git-dir="$SCRATCH" update-ref refs/v/0/files "$files"

# ---- Bundle -------------------------------------------------------------

git --git-dir="$SCRATCH" -c safe.directory='*' bundle create \
    "$OUT/bundle" --all >/dev/null 2>"$ERR" \
    || fail "cannot create the bundle: $(cat "$ERR")"
exit 0
