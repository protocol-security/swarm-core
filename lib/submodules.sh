#!/bin/bash
# Submodules from the engagement's mirrors.  launch.sh lists, in
# mirrors/manifest.json, every submodule it mirrored for the containers
# (lib/mirrors.sh), parents first, and mounts mirrors/ read-only at
# /mirrors; swarm_submodules_init checks each out there, never from the
# network.  The .gitmodules reading both sides share is here too.
#
# Sourced by lib/harness.sh and lib/interactive.sh inside the container
# (/submodules.sh), by launch.sh through lib/mirrors.sh, and by
# tests/test_mirrors.sh.  Runs under Bash 3.2.  Names and paths are
# bytes: what handles them runs in the C locale, as under a UTF-8 one
# git config --get-regexp passes over a name that is not UTF-8 and tr
# refuses one.

SWARM_MIRRORS_SCHEMA="swarm-core.mirrors/v1"

# The checks every reader of a manifest makes before using any of it
# (jq on the one document the file holds, read with -s, with $schema
# and $base): ids 1..n in order, each parent an
# earlier id or 0 (the checkout), commit ids of the base's length, name
# and path non-empty base64, no path twice under one parent.
# shellcheck disable=SC2016
SWARM_MIRRORS_JQ_VALID='
    def oid: type == "string"
        and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
    def b64: type == "string" and length > 0 and length % 4 == 0
        and test("^[A-Za-z0-9+/]*={0,2}$");
    type == "object" and .schema == $schema and (.base | oid)
    and .base == $base and (.mirrors | type == "array")
    and ([.mirrors | to_entries[] | .key as $k | .value
          | type == "object"
            and (.id | type == "number") and (.id | tostring) == ($k + 1 | tostring)
            and (.parent | type == "number")
            and (.parent | tostring | test("^(0|[1-9][0-9]*)$"))
            and .parent <= $k
            and (.commit | oid) and (.commit | length) == ($base | length)
            and (.name | b64) and (.path | b64)] | all)
    and ([.mirrors[] | [.parent, .path]] | unique | length)
        == (.mirrors | length)'

# Succeed when Git would take NAME as a submodule's name: not empty, and
# no ".." component between "/" or "\" (check_submodule_name).
swarm_gitmodules_name_ok() {
    local name="$1"
    [ -n "$name" ] || return 1
    case "/${name//\\//}/" in
        */../*) return 1 ;;
    esac
    return 0
}

# Read, on stdin, what `git config -z --get-regexp
# '^submodule\..*\.path$'` prints for a .gitmodules, and fill
# SWARM_GM_NAME and SWARM_GM_PATH with its declarations, in order, each
# once, and SWARM_GM_AMBIG with yes for one whose path another
# declaration gives another name, or whose name another gives another
# path: which of them Git takes cannot be relied on.  As Git does, a
# declaration without a value, with a name check_submodule_name
# refuses or with a path that starts with "-" is ignored.
swarm_gitmodules_parse() {
    local -x LC_ALL=C
    local rec key name path i j seen ambig
    SWARM_GM_PATH=() SWARM_GM_NAME=() SWARM_GM_AMBIG=()
    while IFS= read -r -d '' rec; do
        case "$rec" in
            *$'\n'*) ;;
            *) continue ;;
        esac
        key=${rec%%$'\n'*}
        name=${key#submodule.}
        name=${name%.path}
        path=${rec#*$'\n'}
        swarm_gitmodules_name_ok "$name" || continue
        case "$path" in
            -*) continue ;;
        esac
        seen=no
        for (( i = 0; i < ${#SWARM_GM_NAME[@]}; i++ )); do
            if [ "${SWARM_GM_NAME[i]}" = "$name" ] \
                    && [ "${SWARM_GM_PATH[i]}" = "$path" ]; then
                seen=yes
                break
            fi
        done
        [ "$seen" = yes ] || { SWARM_GM_NAME+=("$name"); SWARM_GM_PATH+=("$path"); }
    done
    for (( i = 0; i < ${#SWARM_GM_PATH[@]}; i++ )); do
        ambig=no
        for (( j = 0; j < ${#SWARM_GM_PATH[@]}; j++ )); do
            [ "$j" -ne "$i" ] || continue
            if [ "${SWARM_GM_PATH[j]}" = "${SWARM_GM_PATH[i]}" ] \
                    || [ "${SWARM_GM_NAME[j]}" = "${SWARM_GM_NAME[i]}" ]
            then
                ambig=yes
                break
            fi
        done
        SWARM_GM_AMBIG+=("$ambig")
    done
}

# Print the name the parsed declarations give PATH, when exactly one
# gives it one and that is not ambiguous; fail otherwise.
swarm_gitmodules_name_of() {
    local i found=""
    for (( i = 0; i < ${#SWARM_GM_PATH[@]}; i++ )); do
        [ "${SWARM_GM_PATH[i]}" = "$1" ] || continue
        [ -z "$found" ] && [ "${SWARM_GM_AMBIG[i]}" = no ] || return 1
        found=$i
    done
    [ -n "$found" ] || return 1
    printf '%s' "${SWARM_GM_NAME[found]}"
}

# Print the path the parsed declarations give NAME, when exactly one
# gives it one and that is not ambiguous; fail otherwise.
swarm_gitmodules_path_of() {
    local i found=""
    for (( i = 0; i < ${#SWARM_GM_NAME[@]}; i++ )); do
        [ "${SWARM_GM_NAME[i]}" = "$1" ] || continue
        [ -z "$found" ] && [ "${SWARM_GM_AMBIG[i]}" = no ] || return 1
        found=$i
    done
    [ -n "$found" ] || return 1
    printf '%s' "${SWARM_GM_PATH[found]}"
}

# Succeed when B64 is the canonical base64 of bytes that are not empty
# and hold no NUL, tab or newline: a name or a path a manifest may
# carry (Bash cannot hold a NUL, and cleanup's lists hold no tab or
# newline).
swarm_mirrors_b64_ok() {
    local -x LC_ALL=C
    local b64="$1" raw all kept
    case "$b64" in
        ""|*[!A-Za-z0-9+/=]*) return 1 ;;
    esac
    all=$(printf '%s' "$b64" | base64 -d 2>/dev/null | wc -c) || return 1
    kept=$(printf '%s' "$b64" | base64 -d 2>/dev/null | tr -d '\000' \
        | wc -c) || return 1
    [ "$all" -gt 0 ] && [ "$all" -eq "$kept" ] || return 1
    raw=$(printf '%s' "$b64" | base64 -d 2>/dev/null; printf x)
    raw=${raw%x}
    case "$raw" in
        *$'\t'*|*$'\n'*) return 1 ;;
    esac
    [ "$(printf '%s' "$raw" | base64 | tr -d '\n')" = "$b64" ]
}

# The bytes of base64 text B64, on stdout, kept exactly (trailing
# newlines too) by the caller's x trick.
_swarm_b64d() {
    printf '%s' "$1" | base64 -d 2>/dev/null
}

# swarm_submodules_init MANIFEST ROOT LOG
#
# Check out, in the checkout whose work tree is ROOT, each submodule
# MANIFEST lists, in order, from its mirror beside MANIFEST
# (<id>.git): its URL in its superproject's config set to the mirror,
# then `git submodule update --init` of that one path, which checks out
# the commit its superproject's checkout records.  Never --recursive:
# what the manifest does not list stays uninitialized.  Only the file
# protocol is allowed.  LOG names a function that prints one message.
# The manifest must be valid for the engagement's base, which launch.sh
# passes in SWARM_MIRRORS_BASE, and only its first SWARM_MIRRORS_COUNT
# entries are checked out: those launch.sh found ready (a join may
# append more meanwhile, their mirrors not made yet).
#
# An entry that does not apply to this checkout is skipped, with a
# message, and configures nothing: its superproject entry was skipped;
# its superproject's directory is not that repository's work tree; the
# index there does not hold exactly one gitlink at its path; the
# .gitmodules there does not map its path to its name.  No manifest:
# nothing to do (the engagement maps no submodule).  Returns 1 when the
# manifest is not valid, a listed mirror is missing, or a submodule
# that applies is not checked out from its mirror, at its commit, with
# its git dir under ROOT.
swarm_submodules_init() {
    local -x LC_ALL=C
    local manifest="$1" root="$2" log="$3" mdir expect n i id parent
    local name path dir top full rec entry got mirror sub oid ok=0
    local skipped=0 b64 count
    local -a ids=() parents=() names=() paths=() full_path=() state=()
    [ -e "$manifest" ] || [ -L "$manifest" ] || return 0
    mdir=${manifest%/*}
    expect=${SWARM_MIRRORS_BASE:-}
    count=${SWARM_MIRRORS_COUNT:-}
    case "$count" in
        ""|*[!0-9]*|0?*) count="" ;;
    esac
    if [ -z "$expect" ] || [ -z "$count" ] || [ -L "$manifest" ] \
            || [ ! -f "$manifest" ] \
            || ! jq -e -s --arg schema "$SWARM_MIRRORS_SCHEMA" \
                --arg base "$expect" --argjson count "$count" \
                "length == 1 and (.[0] | ${SWARM_MIRRORS_JQ_VALID})
                 and (.[0].mirrors | length) >= \$count" \
                "$manifest" >/dev/null 2>&1; then
        "$log" "submodules: ${manifest} is not a valid manifest for this" \
            "engagement"
        return 1
    fi
    while IFS=$'\t' read -r id parent name path; do
        for b64 in "$name" "$path"; do
            if ! swarm_mirrors_b64_ok "$b64"; then
                "$log" "submodules: ${manifest} is not a valid manifest" \
                    "for this engagement"
                return 1
            fi
        done
        ids+=("$id") parents+=("$parent") names+=("$name") paths+=("$path")
    done < <(jq -r --argjson count "$count" '.mirrors[:$count][]
                    | [.id, .parent, .name, .path]
                    | map(tostring) | join("\t")' "$manifest")
    n=${#ids[@]}
    for (( i = 0; i < n; i++ )); do
        id=${ids[i]} parent=${parents[i]}
        name=$(_swarm_b64d "${names[i]}"; printf x)
        name=${name%x}
        path=$(_swarm_b64d "${paths[i]}"; printf x)
        path=${path%x}
        if [ "$parent" -eq 0 ]; then
            full=$path
            dir=$root
        else
            full="${full_path[parent - 1]}/${path}"
            dir="${root}/${full_path[parent - 1]}"
        fi
        full_path+=("$full")
        state+=(skipped)
        mirror="${mdir}/${id}.git"
        if [ ! -d "$mirror" ] || [ -L "$mirror" ]; then
            "$log" "submodules: ${full}: no mirror ${id}.git"
            return 1
        fi
        if [ "$parent" -ne 0 ] && [ "${state[parent - 1]}" != ok ]; then
            "$log" "submodules: ${full}: skipped, its superproject" \
                "is not checked out"
            skipped=$((skipped + 1))
            continue
        fi
        top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
        if [ "$top" != "$dir" ]; then
            "$log" "submodules: ${full}: skipped, not in its" \
                "superproject's work tree"
            skipped=$((skipped + 1))
            continue
        fi
        # Exactly one entry at that path in the index, a gitlink.
        got=0 entry=""
        while IFS= read -r -d '' rec; do
            got=$((got + 1))
            entry=$rec
        done < <(git --literal-pathspecs -C "$dir" ls-files -s -z \
            -- "$path" 2>/dev/null)
        if [ "$got" -ne 1 ] || [ "${entry#*$'\t'}" != "$path" ] \
                || [ "${entry%% *}" != 160000 ]; then
            "$log" "submodules: ${full}: skipped, not a gitlink in this" \
                "checkout"
            skipped=$((skipped + 1))
            continue
        fi
        oid=${entry#* }
        oid=${oid%% *}
        # The same name in the .gitmodules checked out there (in the C
        # locale, so that a name that is not UTF-8 is not passed over).
        swarm_gitmodules_parse < <(LC_ALL=C git -C "$dir" config \
            -f .gitmodules -z --get-regexp '^submodule\..*\.path$' \
            2>/dev/null)
        if [ "$(swarm_gitmodules_name_of "$path"; printf x)" != "${name}x" ]
        then
            "$log" "submodules: ${full}: skipped, its name in this" \
                "checkout's .gitmodules is another"
            skipped=$((skipped + 1))
            continue
        fi
        # update = none there: Git would leave it out, and so does this.
        if [ "$(git -C "$dir" config -f .gitmodules --get \
                "submodule.${name}.update" 2>/dev/null)" = none ]; then
            "$log" "submodules: ${full}: skipped, update = none in its" \
                "superproject's .gitmodules"
            skipped=$((skipped + 1))
            continue
        fi
        if ! git -C "$dir" config "submodule.${name}.url" "$mirror" \
                || ! env GIT_ALLOW_PROTOCOL=file git --literal-pathspecs \
                    -C "$dir" submodule update --init -q -- "$path"; then
            "$log" "submodules: ${full}: cannot be checked out from" \
                "${id}.git"
            return 1
        fi
        # Checked out where it should be, from that mirror, at that
        # commit.
        sub="${dir}/${path}"
        if ! _swarm_submodules_inside "$root" "$sub" \
                || [ "$(git -C "$sub" remote get-url origin 2>/dev/null)" \
                        != "$mirror" ] \
                || [ "$(git -C "$sub" rev-parse -q --verify HEAD \
                        2>/dev/null)" != "$oid" ]; then
            "$log" "submodules: ${full}: not checked out from ${id}.git" \
                "at ${oid} inside the workspace"
            return 1
        fi
        state[i]=ok
        ok=$((ok + 1))
    done
    if [ "$skipped" -gt 0 ]; then
        "$log" "submodules: ${ok} of ${n} checked out from mirrors," \
            "${skipped} skipped"
    elif [ "$n" -gt 0 ]; then
        "$log" "submodules: ${ok} of ${n} checked out from mirrors"
    fi
    return 0
}

# Git as the sync runs it: no transport, no lazy fetch, no hook, no
# fsmonitor, no recursion into submodules.
_swarm_sync_git() {
    GIT_ALLOW_PROTOCOL='' GIT_NO_LAZY_FETCH=1 git -c core.hooksPath=/dev/null \
        -c core.fsmonitor=false -c submodule.recurse=false "$@"
}

# Succeed when the repository whose work tree is SUB has its work tree,
# its git dir and its common dir under directory ROOT (physical paths).
_swarm_submodules_inside() {
    local root="$1" sub="$2" gd cd top
    top=$(_swarm_sync_git -C "$sub" rev-parse --show-toplevel 2>/dev/null) \
        || return 1
    [ "$top" = "$sub" ] || return 1
    gd=$(_swarm_sync_git -C "$sub" rev-parse --absolute-git-dir \
        2>/dev/null) || return 1
    cd=$(_swarm_sync_git -C "$sub" rev-parse --git-common-dir 2>/dev/null) \
        || return 1
    case "$cd" in
        /*) ;;
        *) cd="${sub}/${cd}" ;;
    esac
    gd=$(cd -P "$gd" 2>/dev/null && pwd -P) || return 1
    cd=$(cd -P "$cd" 2>/dev/null && pwd -P) || return 1
    case "${gd}/" in
        "${root}"/*) ;;
        *) return 1 ;;
    esac
    case "${cd}/" in
        "${root}"/*) ;;
        *) return 1 ;;
    esac
}

# swarm_submodules_sync ROOT LOG
#
# Put every submodule checked out under ROOT, at any depth, back at the
# commit its superproject's index records (git checkout -f), as the
# push path needs to clear pointer drift, which stash cannot reach; one
# whose gitlink is unmerged is left as it is.  Its
# Git runs no transport, lazy fetch, hook or fsmonitor and never
# recurses by itself, so it clones and fetches nothing; it touches only
# submodules whose work tree, git dir and common dir are under ROOT
# (what the files there lead to is the agent's, who can write there
# itself).  One it cannot put back is logged and left; the others go
# on.  Returns 0.
swarm_submodules_sync() {
    local -x LC_ALL=C
    _swarm_submodules_sync "$1" "$1" "$2"
    return 0
}

_swarm_submodules_sync() {
    local root="$1" dir="$2" log="$3" rec meta path oid sub unmerged=""
    while IFS= read -r -d '' rec; do
        meta=${rec%%$'\t'*}
        path=${rec#*$'\t'}
        [ "${meta%% *}" = 160000 ] || continue
        oid=${meta#* }
        oid=${oid%% *}
        sub="${dir}/${path}"
        # In a merge conflict (stages 1 to 3, listed together): no
        # gitlink to go back to, and what is there may be the agent's
        # resolution, as git submodule update leaves it.
        if [ "${meta##* }" != 0 ]; then
            if [ "$path" != "$unmerged" ]; then
                "$log" "submodules: ${sub}: left as it is, unmerged"
                unmerged=$path
            fi
            continue
        fi
        # Not checked out: nothing to put back.
        [ -e "${sub}/.git" ] || [ -L "${sub}/.git" ] || continue
        if [ -L "${sub}/.git" ] || ! _swarm_submodules_inside "$root" "$sub"
        then
            "$log" "submodules: ${sub}: left as it is, its git dir is" \
                "not its own under ${root}"
            continue
        fi
        if ! _swarm_sync_git -C "$sub" checkout -q -f \
                --no-recurse-submodules --detach "$oid" 2>/dev/null; then
            "$log" "submodules: ${sub}: cannot be put back at ${oid}"
            continue
        fi
        _swarm_submodules_sync "$root" "$sub" "$log"
    done < <(_swarm_sync_git -C "$dir" ls-files -s -z 2>/dev/null)
}
