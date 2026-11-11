#!/bin/bash
# Submodule mirrors on the host: which submodules an engagement's
# containers get, at any depth, each cloned into a numbered mirror under
# the runtime directory's mirrors/, and mirrors/manifest.json listing
# them (lib/submodules.sh reads it in the containers).  Sourced by
# swarm after lib/project.sh, lib/preserve.sh and lib/submodules.sh;
# runs under Bash 3.2.

# The walk's result, one element per submodule, parents first: its id
# in the manifest and its superproject's (0 for the checkout), its name
# and path in that superproject, its path from the checkout, the commit
# the superproject's commit records there, the host's git dir for it
# ("" when its mirror is there already), and whether its mirror is to
# be made.
SWARM_MP_ID=() SWARM_MP_PID=() SWARM_MP_NAME=() SWARM_MP_SMPATH=()
SWARM_MP_DISPLAY=() SWARM_MP_COMMIT=() SWARM_MP_GITDIR=() SWARM_MP_BUILD=()
SWARM_MP_NEXT=1

# Git on the host's repositories, for reading: no system or global
# configuration (no URL rewriting or default of the user's applies), no
# environment redirection, hooks, fsmonitor, replace objects or grafts
# (swarm_recovery_git), and no fetch of any kind (swarm_no_fetch).  In
# the C locale: under a UTF-8 one, git config --get-regexp passes over
# a name that is not UTF-8.
_swarm_mirrors_git() {
    LC_ALL=C HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        swarm_no_fetch swarm_recovery_git "$@"
}

# The same for making a mirror: the file protocol only, and a repository
# every Git that reads it takes (files refs, no submodulePathConfig
# extension, whatever the defaults say).
_swarm_mirrors_git_clone() {
    (
        unset GIT_DEFAULT_REF_FORMAT
        LC_ALL=C HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent \
            GIT_CONFIG_NOSYSTEM=1 \
            GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 \
            GIT_ALLOW_PROTOCOL=file \
            swarm_recovery_git -c init.defaultRefFormat=files \
            -c init.defaultSubmodulePathConfig=false "$@"
    )
}

_swarm_mirrors_b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# Succeed when PATH is a plain relative path: not empty or absolute, no
# empty, "." or ".." component.
_swarm_mirrors_rel_ok() {
    local rest="$1" comp
    case "$rest" in
        ""|/*|*/) return 1 ;;
    esac
    while :; do
        comp=${rest%%/*}
        case "$comp" in
            ""|.|..) return 1 ;;
        esac
        [ "$rest" != "$comp" ] || return 0
        rest=${rest#*/}
    done
}

# Succeed when no leading part of PATH under directory DIR, nor PATH
# itself, is a symbolic link.
_swarm_mirrors_no_link() {
    local dir="$1" rest="$2" pre="" comp
    while :; do
        comp=${rest%%/*}
        pre=${pre:+${pre}/}${comp}
        [ ! -L "${dir}/${pre}" ] || return 1
        [ "$rest" != "$comp" ] || return 0
        rest=${rest#*/}
    done
}

# Succeed when the repository whose git dir is GITDIR is a partial
# clone (as swarm_checkout_storage_ok tells one).
_swarm_mirrors_partial() {
    local gd="$1" names name val
    if [ -n "$(_swarm_mirrors_git --git-dir="$gd" config --get \
            extensions.partialClone 2>/dev/null)" ]; then
        return 0
    fi
    names=$(_swarm_mirrors_git --git-dir="$gd" config --name-only \
        --get-regexp '^remote\..*\.promisor$' 2>/dev/null) || names=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        val=$(_swarm_mirrors_git --git-dir="$gd" config --type=bool --get \
            "$name" 2>/dev/null) || val=true
        [ "$val" = false ] || return 0
    done <<< "$names"
    return 1
}

# Succeed when FILE, the `ls-tree -z` entry of a .gitmodules in git dir
# GITDIR, names a blob that git dir can read.
_swarm_mirrors_gitmodules_blob() {
    local gd="$1" file="$2" entry="" meta
    [ -n "$gd" ] || return 1
    IFS= read -r -d '' entry < "$file" || [ -n "$entry" ] || return 1
    meta=${entry%%$'\t'*}
    [ "${entry#*$'\t'}" = .gitmodules ] || return 1
    case "$meta" in
        "100644 blob "*|"100755 blob "*) ;;
        *) return 1 ;;
    esac
    [ "$(_swarm_mirrors_git --git-dir="$gd" cat-file -t "${meta##* }" \
        2>/dev/null)" = blob ]
}

# Succeed when Git's own submodule code reads the .gitmodules of commit
# C (in git dir OBJDIR) without a fatal error (a value it refuses, a
# key without one), as `git submodule update` in a container would:
# tried with `git submodule status` in a scratch repository under
# SCRATCH that holds that file and the gitlink OID at PATH.  Prints
# Git's message on failure.
_swarm_mirrors_gitmodules_ok() {
    local scratch="$1" objdir="$2" c="$3" path="$4" oid="$5"
    local s="${1}/gmcheck" out format
    rm -rf "$s"
    format=$(_swarm_mirrors_git --git-dir="$objdir" rev-parse \
        --show-object-format 2>/dev/null) || return 1
    _swarm_mirrors_git init -q --object-format="$format" "$s" \
        >/dev/null 2>&1 || return 1
    _swarm_mirrors_git --git-dir="$objdir" cat-file blob "${c}:.gitmodules" \
        > "${s}/.gitmodules" 2>/dev/null || return 1
    _swarm_mirrors_git -C "$s" update-index --add --cacheinfo \
        "160000,${oid},${path}" >/dev/null 2>&1 || return 1
    if ! out=$(_swarm_mirrors_git -C "$s" submodule status 2>&1); then
        printf '%s' "$out"
        return 1
    fi
}

# Print NAME as the path Git builds a submodule's git dir from, under
# modules/: no empty or "." component.
_swarm_mirrors_name_path() {
    local rest="$1/" comp out=""
    while [ -n "$rest" ]; do
        comp=${rest%%/*}
        rest=${rest#*/}
        case "$comp" in
            ""|.) ;;
            *) out=${out:+${out}/}${comp} ;;
        esac
    done
    printf '%s' "$out"
}

# _swarm_mirrors_walk SCRATCH OBJDIR WORKTREE COMMIT DISPLAY ID OLD DIR
#
# Add to the walk the submodules repository R records at its commit
# COMMIT, read from git dir OBJDIR, that the containers will get, each
# followed by its own.  WORKTREE is R's work tree on the host ("" when
# the host has none, so nothing new is found under it), DISPLAY its
# path from the checkout ("" for the checkout), ID its id (0 for the
# checkout).  OLD is the manifest a join extends ("" for none) and DIR
# the mirrors' directory ("" for none): a submodule OLD lists keeps its
# id, and with its mirror in DIR needs nothing from the host.  Returns
# 1, with a message, on what the containers could not be given.
_swarm_mirrors_walk() {
    local scratch="$1" objdir="$2" wt="$3" c="$4" disp="$5" pid="$6"
    local old="$7" dir="$8"
    local rc i j n cnt rec entry meta mode oid path name sub hp hg g id
    local line lid lname lcommit checked=no build objsrc
    local subwt err npath hamb have_mirror holders
    local -a mpath=() mname=() mambig=() hpath=() hname=() hambig=()
    local -a listed=()
    # C's .gitmodules: none, no submodules; a tree or a blob that cannot
    # be read refuses, as nothing could be told of them.
    rc=0
    _swarm_mirrors_git --git-dir="$objdir" ls-tree -z "$c" -- .gitmodules \
        > "${scratch}/gmtree" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: cannot read the tree of ${disp:-the checkout} at" \
             "${c}." >&2
        return 1
    fi
    [ -s "${scratch}/gmtree" ] || return 0
    # git config --blob says 1 for a blob it cannot load or parse, as for
    # no match: the blob is checked first, whole (--list says 128).
    if ! _swarm_mirrors_gitmodules_blob "$objdir" "${scratch}/gmtree" \
            || ! _swarm_mirrors_git --git-dir="$objdir" config --blob \
                "${c}:.gitmodules" --list >/dev/null 2>&1; then
        echo "ERROR: cannot read the .gitmodules of" \
             "${disp:-the checkout} at ${c}." >&2
        return 1
    fi
    rc=0
    _swarm_mirrors_git --git-dir="$objdir" config --blob "${c}:.gitmodules" \
        -z --get-regexp '^submodule\..*\.path$' > "${scratch}/gm" \
        2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "ERROR: cannot read the .gitmodules of" \
             "${disp:-the checkout} at ${c}." >&2
        return 1
    fi
    swarm_gitmodules_parse < "${scratch}/gm"
    mpath=(${SWARM_GM_PATH[@]+"${SWARM_GM_PATH[@]}"})
    mname=(${SWARM_GM_NAME[@]+"${SWARM_GM_NAME[@]}"})
    mambig=(${SWARM_GM_AMBIG[@]+"${SWARM_GM_AMBIG[@]}"})
    # The host's own mapping, which says where each module is now.
    : > "${scratch}/gm"
    if [ -n "$wt" ] && [ -f "${wt}/.gitmodules" ] \
            && [ ! -L "${wt}/.gitmodules" ]; then
        rc=0
        _swarm_mirrors_git --git-dir="$objdir" config -f "${wt}/.gitmodules" -z \
            --get-regexp '^submodule\..*\.path$' > "${scratch}/gm" \
            2>/dev/null || rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
            echo "ERROR: cannot read ${wt}/.gitmodules." >&2
            return 1
        fi
    fi
    swarm_gitmodules_parse < "${scratch}/gm"
    hpath=(${SWARM_GM_PATH[@]+"${SWARM_GM_PATH[@]}"})
    hname=(${SWARM_GM_NAME[@]+"${SWARM_GM_NAME[@]}"})
    hambig=(${SWARM_GM_AMBIG[@]+"${SWARM_GM_AMBIG[@]}"})
    n=${#mpath[@]}
    for (( i = 0; i < n; i++ )); do
        path=${mpath[i]} name=${mname[i]}
        # Exactly one entry at that path in the commit, a gitlink; a
        # tree that cannot be read refuses.
        rc=0
        _swarm_mirrors_git --git-dir="$objdir" --literal-pathspecs \
            ls-tree -z "$c" -- "$path" > "${scratch}/lt" 2>/dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: cannot read the tree of ${disp:-the checkout} at" \
                 "${c}." >&2
            return 1
        fi
        cnt=0 entry=""
        while IFS= read -r -d '' rec; do
            cnt=$((cnt + 1))
            entry=$rec
        done < "${scratch}/lt"
        [ "$cnt" -eq 1 ] && [ "${entry#*$'\t'}" = "$path" ] || continue
        meta=${entry%%$'\t'*}
        mode=${meta%% *} oid=${meta##* }
        [ "$mode" = 160000 ] || continue
        sub="${disp:+${disp}/}${path}"
        # Where the host has the module now, by its name: its own
        # .gitmodules maps the name to a path, whose .git is there.  A
        # name the commit's or the host's .gitmodules declares
        # ambiguously refuses when anything of it is initialized there.
        hp="" hg="" hamb=$([ "${mambig[i]}" = yes ] && echo yes || echo no)
        holders=""
        for (( j = 0; j < ${#hname[@]}; j++ )); do
            [ "${hname[j]}" = "$name" ] || continue
            if [ "${hambig[j]}" = yes ]; then
                hamb=yes
            else
                hp=${hpath[j]}
            fi
        done
        if [ "$hamb" = yes ]; then
            hp=""
            for (( j = 0; j < ${#hname[@]}; j++ )); do
                [ "${hname[j]}" = "$name" ] || continue
                if [ -n "$wt" ] && _swarm_mirrors_rel_ok "${hpath[j]}" \
                        && { [ -e "${wt}/${hpath[j]}/.git" ] \
                             || [ -L "${wt}/${hpath[j]}/.git" ]; }; then
                    holders=yes
                fi
            done
            if [ -n "$wt" ] && _swarm_mirrors_rel_ok "$path" \
                    && { [ -e "${wt}/${path}/.git" ] \
                         || [ -L "${wt}/${path}/.git" ]; }; then
                holders=yes
            fi
            if [ -n "$holders" ]; then
                echo "ERROR: submodule ${sub}: a .gitmodules gives" \
                     "${name} two paths, or its path two names; which one" \
                     "Git takes cannot be relied on." >&2
                return 1
            fi
            continue
        fi
        # A join keeps what its manifest lists, under its id.
        id="" lname="" lcommit=""
        if [ -n "$old" ]; then
            line=$(jq -r --argjson pid "$pid" \
                --arg path "$(_swarm_mirrors_b64 "$path")" \
                '.mirrors[] | select(.parent == $pid and .path == $path)
                 | [.id, .name, .commit] | map(tostring) | join(" ")' \
                "$old") || return 1
            if [ -n "$line" ]; then
                read -r lid lname lcommit <<< "$line"
                id=$lid
            fi
        fi
        # A mirror a join's manifest lists and that is there needs
        # nothing of the host's git dir: what is under it is read from
        # it.
        have_mirror=no
        if [ -n "$id" ] && [ -n "$dir" ] && [ -d "${dir}/${id}.git" ] \
                && [ ! -L "${dir}/${id}.git" ]; then
            have_mirror=yes
        fi
        if [ -n "$hp" ]; then
            if ! _swarm_mirrors_rel_ok "$hp" \
                    || ! _swarm_mirrors_no_link "$wt" "$hp" \
                    || [ -L "${wt}/${hp}/.git" ]; then
                echo "ERROR: submodule ${sub}: the host has it at" \
                     "${wt}/${hp}, through a link or outside its" \
                     "superproject; swarm-core does not follow that." >&2
                return 1
            fi
            if [ "$have_mirror" = no ] && [ -e "${wt}/${hp}/.git" ]; then
                if ! g=$(_swarm_mirrors_git --git-dir="${wt}/${hp}/.git" \
                        rev-parse --absolute-git-dir 2>&1) \
                        || ! hg=$(cd -P "$g" 2>/dev/null && pwd -P); then
                    echo "ERROR: cannot find the Git directory of" \
                         "submodule ${sub} (${wt}/${hp}/.git): ${g}" >&2
                    return 1
                fi
            fi
        elif [ -n "$wt" ] && _swarm_mirrors_rel_ok "$path" \
                && _swarm_mirrors_no_link "$wt" "$path" \
                && { [ -e "${wt}/${path}/.git" ] \
                     || [ -L "${wt}/${path}/.git" ]; }; then
            # A repository at its path the host's mapping does not give
            # to it: another module's, named there without ambiguity, is
            # skipped; nobody's, or one declared ambiguously, refuses,
            # as what it is cannot be told.
            holders=""
            for (( j = 0; j < ${#hpath[@]}; j++ )); do
                [ "${hpath[j]}" = "$path" ] || continue
                if [ "${hambig[j]}" = yes ]; then
                    holders=ambiguous
                    break
                fi
                holders=other
            done
            if [ "$holders" != other ]; then
                echo "ERROR: submodule ${sub}: ${wt}/${path} holds a" \
                     "repository the host's .gitmodules does not give to" \
                     "${name}; move it away or name it there, then start" \
                     "again." >&2
                return 1
            fi
        fi
        build=no objsrc="" subwt=""
        if [ "$have_mirror" = yes ]; then
            # Listed and there: read under it from its mirror.
            objsrc="${dir}/${id}.git"
        elif [ -n "$hg" ]; then
            objsrc=$hg
            build=yes
        else
            # Not initialized on the host (deinit removes the gitfile;
            # removing the module removes its name): not mirrored,
            # nothing under it.  One a join lists and has lost refuses
            # below.
            continue
        fi
        [ -z "$hp" ] || subwt="${wt}/${hp}"
        if [ -n "$id" ] && { [ "$lname" != "$(_swarm_mirrors_b64 "$name")" ] \
                || [ "$lcommit" != "$oid" ]; }; then
            echo "ERROR: the manifest lists ${sub} with another name or" \
                 "commit than the base records." >&2
            return 1
        fi
        case "$name$path" in
            *$'\t'*|*$'\n'*)
                echo "ERROR: submodule ${sub}: a tab or a newline in its" \
                     "name or path, which cleanup's lists cannot carry;" \
                     "rename it or deinit it, then start again." >&2
                return 1 ;;
        esac
        # Git keeps a submodule's git dir under modules/<name>: a name
        # that leaves no such directory of its own (".", "foo/.", a
        # trailing "/") cannot be initialized, nor two whose names make
        # one such path the other's, or inside it.
        npath=$(_swarm_mirrors_name_path "$name")
        case "$name" in
            .|*/|*/.) npath="" ;;
        esac
        if [ -z "$npath" ]; then
            echo "ERROR: submodule ${sub}: its name ${name} gives the" \
                 "containers' Git no directory of its own under" \
                 "modules/; rename it or deinit it, then start again." >&2
            return 1
        fi
        for (( j = 0; j < ${#listed[@]}; j++ )); do
            case "${listed[j]}/" in
                "$npath"/*) ;;
                *)
                    case "$npath/" in
                        "${listed[j]}"/*) ;;
                        *) continue ;;
                    esac ;;
            esac
            echo "ERROR: ${disp:-the checkout} has submodules whose" \
                 "names give the git dirs modules/${listed[j]} and" \
                 "modules/${npath}, one inside the other, which the" \
                 "containers' Git cannot both initialize." >&2
            return 1
        done
        listed+=("$npath")
        if [ "$checked" = no ]; then
            if ! err=$(_swarm_mirrors_gitmodules_ok "$scratch" "$objdir" \
                    "$c" "$path" "$oid"); then
                echo "ERROR: Git cannot read the .gitmodules of" \
                     "${disp:-the checkout} at ${c}: ${err}" >&2
                return 1
            fi
            checked=yes
        fi
        if [ "$build" = yes ]; then
            if [ "$(_swarm_mirrors_git --git-dir="$hg" rev-parse \
                    --is-shallow-repository 2>/dev/null)" != false ]; then
                echo "ERROR: submodule ${sub} is a shallow clone (${hg});" \
                     "cleanup could not keep a mirror of it.  Fetch its" \
                     "full history (git fetch --unshallow there) or deinit" \
                     "it, then start again." >&2
                return 1
            fi
            if _swarm_mirrors_partial "$hg"; then
                echo "ERROR: submodule ${sub} is a partial clone (${hg});" \
                     "cleanup could not keep a mirror of it.  Fetch every" \
                     "object there or deinit it, then start again." >&2
                return 1
            fi
            if [ "$(_swarm_mirrors_git --git-dir="$hg" cat-file -t \
                    "$oid" 2>/dev/null)" != commit ]; then
                echo "ERROR: submodule ${sub}: ${hg} has no commit ${oid}," \
                     "which ${disp:-the checkout} at ${c} records for it," \
                     "so the containers could not check it out.  Fetch it" \
                     "there (git submodule update) or deinit the submodule," \
                     "then start again." >&2
                return 1
            fi
        fi
        if [ -z "$id" ]; then
            id=$SWARM_MP_NEXT
            SWARM_MP_NEXT=$((SWARM_MP_NEXT + 1))
        fi
        SWARM_MP_ID+=("$id") SWARM_MP_PID+=("$pid") SWARM_MP_NAME+=("$name")
        SWARM_MP_SMPATH+=("$path") SWARM_MP_DISPLAY+=("$sub")
        SWARM_MP_COMMIT+=("$oid") SWARM_MP_BUILD+=("$build")
        if [ "$build" = yes ]; then
            SWARM_MP_GITDIR+=("$hg")
        else
            SWARM_MP_GITDIR+=("")
        fi
        _swarm_mirrors_walk "$scratch" "$objsrc" "$subwt" "$oid" "$sub" \
            "$id" "$old" "$dir" || return 1
    done
    return 0
}

# swarm_mirrors_walk ROOT BASE SCRATCH [OLD DIR]
#
# Fill the SWARM_MP_* arrays with the submodules the containers will
# check out from mirrors: those the checkout ROOT records at commit
# BASE, at any depth, that are initialized on the host (or, for a join,
# listed in the manifest OLD with their mirror in DIR).  SCRATCH is a
# directory for temporary files.  Fails, with a message, as
# _swarm_mirrors_walk does.
swarm_mirrors_walk() {
    local -x LC_ALL=C
    local root="$1" base="$2" scratch="$3" old="${4:-}" dir="${5:-}" gd
    SWARM_MP_ID=() SWARM_MP_PID=() SWARM_MP_NAME=() SWARM_MP_SMPATH=()
    SWARM_MP_DISPLAY=() SWARM_MP_COMMIT=() SWARM_MP_GITDIR=()
    SWARM_MP_BUILD=()
    SWARM_MP_NEXT=1
    if [ -n "$old" ]; then
        SWARM_MP_NEXT=$(jq '.mirrors | length + 1' "$old") || return 1
    fi
    if ! gd=$(_swarm_mirrors_git -C "$root" rev-parse --absolute-git-dir) \
            || ! gd=$(cd -P "$gd" && pwd -P); then
        echo "ERROR: cannot read the git dir of ${root}." >&2
        return 1
    fi
    _swarm_mirrors_git --git-dir="$gd" cat-file -e "${base}^{commit}" \
        2>/dev/null || {
        echo "ERROR: ${root} has no commit ${base}." >&2
        return 1
    }
    _swarm_mirrors_walk "$scratch" "$gd" "$root" "$base" "" 0 "$old" "$dir"
}

# swarm_mirrors_preflight ROOT
#
# The walk on ROOT's HEAD, before an engagement is created, so that
# whatever it refuses is refused before anything exists.
swarm_mirrors_preflight() {
    local -x LC_ALL=C
    local root="$1" head scratch rc=0
    head=$(_swarm_mirrors_git -C "$root" rev-parse --verify --quiet \
        'HEAD^{commit}') || {
        echo "ERROR: ${root} has no commit to start from." >&2
        return 1
    }
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/swarm-mirrors.XXXXXX") || return 1
    swarm_mirrors_walk "$root" "$head" "$scratch" || rc=$?
    rm -rf "$scratch"
    return "$rc"
}

# Succeed when FILE is a valid manifest for an engagement whose base is
# BASE (SWARM_MIRRORS_JQ_VALID, and swarm_mirrors_names_ok on what it
# lists).
swarm_mirrors_manifest_ok() {
    local -x LC_ALL=C
    local file="$1" base="$2" b64
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    jq -e -s --arg schema "$SWARM_MIRRORS_SCHEMA" --arg base "$base" \
        "length == 1 and (.[0] | ${SWARM_MIRRORS_JQ_VALID})" "$file" \
        >/dev/null 2>&1 || return 1
    while IFS= read -r b64; do
        swarm_mirrors_b64_ok "$b64" || return 1
    done < <(jq -r '.mirrors[] | .name, .path' "$file")
}

# Return 0 when the base's own .gitmodules, in checkout ROOT, maps a
# path to a gitlink of the base (an engagement starting there has
# something to mirror), 1 when it maps none, 2 when the base, its tree
# or its .gitmodules cannot be read.
_swarm_mirrors_base_maps() {
    local root="$1" base="$2" scratch="$3" i cnt rec entry rc=0
    _swarm_mirrors_git -C "$root" ls-tree -z "$base" -- .gitmodules \
        > "${scratch}/gmtree" 2>/dev/null || return 2
    [ -s "${scratch}/gmtree" ] || return 1
    _swarm_mirrors_gitmodules_blob "$(_swarm_mirrors_git -C "$root" \
        rev-parse --absolute-git-dir 2>/dev/null)" "${scratch}/gmtree" \
        || return 2
    _swarm_mirrors_git -C "$root" config --blob "${base}:.gitmodules" \
        --list >/dev/null 2>&1 || return 2
    _swarm_mirrors_git -C "$root" config --blob "${base}:.gitmodules" -z \
        --get-regexp '^submodule\..*\.path$' > "${scratch}/gm" 2>/dev/null \
        || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return 2
    swarm_gitmodules_parse < "${scratch}/gm"
    for (( i = 0; i < ${#SWARM_GM_PATH[@]}; i++ )); do
        _swarm_mirrors_git -C "$root" --literal-pathspecs ls-tree -z \
            "$base" -- "${SWARM_GM_PATH[i]}" > "${scratch}/lt" 2>/dev/null \
            || return 2
        cnt=0 entry=""
        while IFS= read -r -d '' rec; do
            cnt=$((cnt + 1))
            entry=$rec
        done < "${scratch}/lt"
        if [ "$cnt" -eq 1 ] && [ "${entry%% *}" = 160000 ] \
                && [ "${entry#*$'\t'}" = "${SWARM_GM_PATH[i]}" ]; then
            return 0
        fi
    done
    return 1
}

# swarm_mirrors_state DIR BASE
#
# Print what DIR (the runtime directory's mirrors/) holds: "manifest"
# (a manifest.json, valid for BASE), "empty" (DIR missing, or nothing in
# it), "legacy" (anything else and no manifest: mirrors an earlier
# release named after the submodules).  A link, a manifest that is not
# valid for BASE, or a manifest.json.new fails, with a message.
swarm_mirrors_state() {
    local -x LC_ALL=C
    local dir="$1" base="$2" e
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
        echo "ERROR: ${dir} is not a directory." >&2
        return 1
    fi
    if [ ! -e "$dir" ]; then
        echo empty
        return 0
    fi
    if [ -e "${dir}/manifest.json.new" ] \
            || [ -L "${dir}/manifest.json.new" ]; then
        echo "ERROR: ${dir}/manifest.json.new is left from a run stopped" \
             "half way; swarm cleanup removes it." >&2
        return 1
    fi
    if [ -e "${dir}/manifest.json" ] || [ -L "${dir}/manifest.json" ]; then
        if ! swarm_mirrors_manifest_ok "${dir}/manifest.json" "$base"; then
            echo "ERROR: ${dir}/manifest.json is not a manifest of this" \
                 "engagement's mirrors." >&2
            return 1
        fi
        echo manifest
        return 0
    fi
    for e in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        if [ -e "$e" ] || [ -L "$e" ]; then
            echo legacy
            return 0
        fi
    done
    echo empty
}

_swarm_mirrors_legacy_explain() {
    echo "ERROR: $1 holds mirrors without a manifest, which an earlier" \
         "release of swarm-core made; this release does not take them" \
         "over.  Finish the engagement with that release, or end it:" \
         "stop the agents, run swarm harvest, then swarm cleanup." >&2
}

# swarm_mirrors_ready ROOT DIR BASE
#
# Before a container starts: print "manifest" when DIR's manifest is
# valid for BASE and every mirror it lists is there with its commit
# pinned, "none" when it lists none, or when there is no manifest and
# the base maps no submodule (nothing to mirror).  Anything else fails,
# with what to do.
swarm_mirrors_ready() {
    local -x LC_ALL=C
    local root="$1" dir="$2" base="$3" state id commit pin scratch rc=0
    state=$(swarm_mirrors_state "$dir" "$base") || return 1
    case "$state" in
        legacy)
            _swarm_mirrors_legacy_explain "$dir"
            return 1 ;;
        empty)
            scratch=$(mktemp -d "${TMPDIR:-/tmp}/swarm-mirrors.XXXXXX") \
                || return 1
            _swarm_mirrors_base_maps "$root" "$base" "$scratch" || rc=$?
            rm -rf "$scratch"
            case "$rc" in
                0)
                    echo "ERROR: this engagement's submodule mirrors were" \
                         "never made (a run stopped half way).  An" \
                         "interactive session that joins makes them;" \
                         "swarm cleanup ends the engagement." >&2
                    return 1 ;;
                1)
                    echo none
                    return 0 ;;
                *)
                    echo "ERROR: cannot read the engagement's base ${base}" \
                         "or its .gitmodules in ${root}." >&2
                    return 1 ;;
            esac ;;
    esac
    while read -r id commit; do
        if [ -e "${dir}/${id}.git.new" ] || [ -L "${dir}/${id}.git.new" ]
        then
            echo "ERROR: ${dir}/${id}.git.new is left from a run stopped" \
                 "half way; swarm cleanup removes it." >&2
            return 1
        fi
        if [ ! -e "${dir}/${id}.git" ] && [ ! -L "${dir}/${id}.git" ]; then
            echo "ERROR: ${dir}/${id}.git is missing (a run stopped half" \
                 "way).  An interactive session that joins makes it" \
                 "again; swarm cleanup ends the engagement." >&2
            return 1
        fi
        _swarm_mirrors_complete "${dir}/${id}.git" "$commit" || return 1
    done < <(jq -r '.mirrors[] | "\(.id) \(.commit)"' "${dir}/manifest.json")
    # An empty list mounts nothing, as no submodule ever did.
    if [ "$(jq '.mirrors | length' "${dir}/manifest.json")" = 0 ]; then
        echo none
    else
        echo manifest
    fi
}

# Succeed when MIRROR is a mirror (a directory, not a link) whose
# refs/swarm/gitlink is COMMIT; else say it is incomplete, which only
# cleanup can deal with.
_swarm_mirrors_complete() {
    local mirror="$1" commit="$2" pin=""
    if [ -d "$mirror" ] && [ ! -L "$mirror" ]; then
        pin=$(_swarm_mirrors_git --git-dir="$mirror" rev-parse -q --verify \
            refs/swarm/gitlink 2>/dev/null) || pin=""
    fi
    if [ "$pin" != "$commit" ]; then
        echo "ERROR: ${mirror} is not a complete mirror (its" \
             "refs/swarm/gitlink is not ${commit}).  swarm cleanup" \
             "ends the engagement and keeps what it holds." >&2
        return 1
    fi
}

# swarm_mirrors_mount_args ROOT DIR BASE
#
# Set SWARM_MIRROR_ARGS, once DIR is ready (swarm_mirrors_ready), to its
# read-only mount at /mirrors, the base the containers check the
# manifest against and how many of its entries were found ready; to
# nothing when there is nothing to mirror.  Fails as swarm_mirrors_ready
# does.
swarm_mirrors_mount_args() {
    local -x LC_ALL=C
    local root="$1" dir="$2" base="$3" ready count
    SWARM_MIRROR_ARGS=()
    ready=$(swarm_mirrors_ready "$root" "$dir" "$base") || return 1
    [ "$ready" = manifest ] || return 0
    case "$dir" in
        *[,\"]*|*$'\n'*|*$'\r'*)
            echo "ERROR: ${dir} holds a comma, a quote or a line break;" \
                 "it cannot be a --mount source." >&2
            return 1 ;;
    esac
    # The manifest only grows (a join appends), so the entries this
    # check found ready stay as they are: the container checks out those
    # (SWARM_MIRRORS_COUNT), whatever a join appends meanwhile.
    count=$(jq '.mirrors | length' "${dir}/manifest.json") || return 1
    # shellcheck disable=SC2034  # read by the caller
    SWARM_MIRROR_ARGS=(
        --mount "type=bind,src=${dir},dst=/mirrors,readonly"
        -e "SWARM_MIRRORS_BASE=${base}"
        -e "SWARM_MIRRORS_COUNT=${count}"
    )
}

# _swarm_mirrors_build GITDIR MIRROR COMMIT
#
# Clone the submodule's git dir GITDIR into MIRROR, COMMIT kept under
# refs/swarm/gitlink.  Cloned as MIRROR.new and renamed once ready, so a
# run stopped half way leaves only a .new, which cleanup preserves and
# removes.
_swarm_mirrors_build() {
    local gitdir="$1" mirror="$2" oid="$3"
    if [ -e "${mirror}.new" ] || [ -L "${mirror}.new" ]; then
        echo "ERROR: ${mirror}.new is left from a run stopped half" \
             "way; swarm cleanup removes it." >&2
        return 1
    fi
    # Through Git's transport, as create_bare_repo does: new files, so
    # the chmod below cannot reach the submodule's git dir through
    # hardlinks, holding what the submodule's branches, tags and HEAD
    # reach.
    if ! _swarm_mirrors_git_clone clone --bare --no-local "$gitdir" \
            "${mirror}.new"; then
        echo "ERROR: cannot clone ${gitdir}." >&2
        return 1
    fi
    # The commit the base records stays in the mirror under
    # refs/swarm/gitlink, fetched by id when none of those reaches it
    # (the submodule's checkout moved on).
    [ "$(_swarm_mirrors_git --git-dir="${mirror}.new" cat-file -t \
            "$oid" 2>/dev/null)" = commit ] \
        || _swarm_mirrors_git_clone --git-dir="${mirror}.new" \
            -c protocol.version=2 fetch -q --no-tags --no-write-fetch-head \
            "$gitdir" "$oid" 2>/dev/null \
        || true
    if [ "$(_swarm_mirrors_git --git-dir="${mirror}.new" cat-file -t \
            "$oid" 2>/dev/null)" != commit ] \
            || ! _swarm_mirrors_git --git-dir="${mirror}.new" update-ref \
                refs/swarm/gitlink "$oid" 2>/dev/null; then
        echo "ERROR: cannot copy commit ${oid} from ${gitdir}." >&2
        return 1
    fi
    chmod -R a+rwX "${mirror}.new" || return 1
    mv "${mirror}.new" "$mirror" || return 1
}

# swarm_mirrors_make ROOT DIR BASE [missing]
#
# Mirror into DIR the submodules of checkout ROOT that an engagement
# starting at BASE gives its containers (swarm_mirrors_walk): the
# manifest first, then each mirror it lists.  A new engagement finds DIR
# missing or empty.  With "missing" (an interactive session that joins):
# the mirrors listed stay; one gone is made again under its id; a
# submodule initialized on the host since is appended under the next
# id, the manifest rewritten before it is made.
swarm_mirrors_make() {
    local -x LC_ALL=C
    local scratch rc=0
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/swarm-mirrors.XXXXXX") || return 1
    _swarm_mirrors_make "$scratch" "$@" || rc=$?
    rm -rf "$scratch"
    return "$rc"
}

_swarm_mirrors_make() {
    local scratch="$1" root="$2" dir="$3" base="$4" mode="${5:-}"
    local state k n old="" id commit added=0 known=0
    state=$(swarm_mirrors_state "$dir" "$base") || return 1
    case "$state:$mode" in
        legacy:*)
            _swarm_mirrors_legacy_explain "$dir"
            return 1 ;;
        manifest:missing) old="${dir}/manifest.json" ;;
        manifest:*)
            echo "ERROR: ${dir}/manifest.json is there already." >&2
            return 1 ;;
    esac
    swarm_mirrors_walk "$root" "$base" "$scratch" "$old" "$dir" || return 1
    if [ -n "$old" ]; then
        known=$(jq '.mirrors | length' "$old") || return 1
    fi
    : > "${scratch}/added" || return 1
    n=${#SWARM_MP_ID[@]}
    for (( k = 0; k < n; k++ )); do
        # The ones the manifest lists are there already.
        [ "${SWARM_MP_ID[k]}" -gt "$known" ] || continue
        jq -nc --argjson id "${SWARM_MP_ID[k]}" \
            --argjson pid "${SWARM_MP_PID[k]}" \
            --arg name "$(_swarm_mirrors_b64 "${SWARM_MP_NAME[k]}")" \
            --arg path "$(_swarm_mirrors_b64 "${SWARM_MP_SMPATH[k]}")" \
            --arg commit "${SWARM_MP_COMMIT[k]}" \
            '{id: $id, parent: $pid, name: $name, path: $path,
              commit: $commit}' >> "${scratch}/added" || return 1
        added=$((added + 1))
    done
    if ! mkdir -p "$dir" || ! chmod 755 "$dir"; then
        echo "ERROR: cannot make ${dir}." >&2
        return 1
    fi
    # The manifest first: what is listed and not there yet is what a run
    # stopped half way left to make.
    if [ -z "$old" ] || [ "$added" -gt 0 ]; then
        if [ -z "$old" ]; then
            old="${scratch}/empty.json"
            jq -n --arg schema "$SWARM_MIRRORS_SCHEMA" --arg base "$base" \
                '{schema: $schema, base: $base, mirrors: []}' > "$old" \
                || return 1
        fi
        if ! jq --slurpfile added "${scratch}/added" \
                '.mirrors += ($added | sort_by(.id))' "$old" \
                > "${dir}/manifest.json.new" \
                || ! chmod 644 "${dir}/manifest.json.new" \
                || ! swarm_mirrors_manifest_ok "${dir}/manifest.json.new" \
                    "$base" \
                || ! mv "${dir}/manifest.json.new" "${dir}/manifest.json"
        then
            echo "ERROR: cannot write ${dir}/manifest.json." >&2
            return 1
        fi
    fi
    for (( k = 0; k < n; k++ )); do
        [ "${SWARM_MP_BUILD[k]}" = yes ] || continue
        id=${SWARM_MP_ID[k]}
        if [ -d "${dir}/${id}.git" ] && [ ! -L "${dir}/${id}.git" ]; then
            continue
        fi
        if [ -e "${dir}/${id}.git" ] || [ -L "${dir}/${id}.git" ]; then
            echo "ERROR: ${dir}/${id}.git is not a mirror." >&2
            return 1
        fi
        echo "--- Mirroring submodule: ${SWARM_MP_DISPLAY[k]} ---"
        _swarm_mirrors_build "${SWARM_MP_GITDIR[k]}" "${dir}/${id}.git" \
            "${SWARM_MP_COMMIT[k]}" || return 1
    done
    # A listed mirror that is gone, and that the host cannot give again,
    # leaves the engagement without it; one there must be complete.
    while read -r id commit; do
        if [ ! -e "${dir}/${id}.git" ] && [ ! -L "${dir}/${id}.git" ]; then
            echo "ERROR: ${dir}/${id}.git is gone, and the host no longer" \
                 "has that submodule initialized to make it again." >&2
            return 1
        fi
        _swarm_mirrors_complete "${dir}/${id}.git" "$commit" || return 1
    done < <(jq -r '.mirrors[] | "\(.id) \(.commit)"' "${dir}/manifest.json")
    return 0
}
