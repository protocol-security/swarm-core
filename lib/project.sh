#!/bin/bash

# Project identity and the per-project runtime directory, shared by
# launch.sh, harvest.sh and the dashboard.  User-facing labels should
# keep the raw repository basename; internal Docker identifiers must be
# lowercase and separator-safe.

swarm_project_id() {
    local raw="${1:-}" lower out="" c last_sep=false i
    lower="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    for ((i = 0; i < ${#lower}; i++)); do
        c="${lower:i:1}"
        case "$c" in
            [a-z0-9])
                out+="$c"
                last_sep=false
                ;;
            .|_|-)
                if [ -n "$out" ] && [ "$last_sep" = false ]; then
                    out+="$c"
                    last_sep=true
                fi
                ;;
            *)
                if [ -n "$out" ] && [ "$last_sep" = false ]; then
                    out+="-"
                    last_sep=true
                fi
                ;;
        esac
    done

    while [ -n "$out" ]; do
        case "${out: -1}" in
            [a-z0-9]) break ;;
            *) out="${out%?}" ;;
        esac
    done

    printf '%s' "${out:-swarm}"
}

# Print the permission bits of a path as three octal digits.  GNU stat
# takes -c, BSD stat takes -f; special bits such as setgid are dropped.
swarm_file_mode() {
    local mode
    mode=$(stat -c '%a' "$1" 2>/dev/null) \
        || mode=$(stat -f '%Lp' "$1" 2>/dev/null) \
        || return 1
    mode="00${mode}"
    printf '%s' "${mode: -3}"
}

# Directory that holds a project's host-side state: the bare repository,
# the submodule mirrors and the state file.  SWARM_RUNTIME_DIR names it
# explicitly; otherwise it lives below the XDG state directory.
swarm_runtime_dir() {
    local project="$1" dir state_home
    if [ -n "${SWARM_RUNTIME_DIR:-}" ]; then
        dir="$SWARM_RUNTIME_DIR"
        case "$dir" in
            /*) ;;
            *)
                echo "ERROR: SWARM_RUNTIME_DIR must be an absolute path:" \
                     "${dir}" >&2
                return 1 ;;
        esac
    else
        state_home="${XDG_STATE_HOME:-}"
        # The XDG spec says to ignore a relative XDG_STATE_HOME.
        case "$state_home" in
            /*) ;;
            *)
                if [ -z "${HOME:-}" ]; then
                    echo "ERROR: HOME is not set; set SWARM_RUNTIME_DIR." >&2
                    return 1
                fi
                state_home="$HOME/.local/state" ;;
        esac
        dir="${state_home}/swarm-core/${project}"
    fi
    # The checks must see the path that the filesystem walks: [ -L ]
    # resolves a trailing "/", "." or "..", and ".." after a symlink
    # leads somewhere else than the spelled path suggests.  Drop
    # trailing slashes and refuse "." and ".." components.
    while [ "$dir" != / ] && [ "${dir%/}" != "$dir" ]; do
        dir="${dir%/}"
    done
    case "${dir}/" in
        */./*|*/../*)
            echo "ERROR: the runtime directory cannot contain '.' or '..'" \
                 "components: ${dir}" >&2
            return 1 ;;
    esac
    # Docker splits -v arguments on colons.
    case "$dir" in
        *:*)
            echo "ERROR: the runtime directory cannot contain ':': ${dir}" >&2
            echo "       Set SWARM_RUNTIME_DIR to a path without one." >&2
            return 1 ;;
    esac
    printf '%s' "$dir"
}

# Print the ACL entries of a path on macOS, where an ACL entry is
# checked before the mode bits and can open a mode 700 directory to
# other users.  Linux applies the group bits as the ACL mask, so the
# mode check already covers POSIX ACLs there.
swarm_acl_entries() {
    local out
    [ "$(uname -s)" = Darwin ] || return 0
    # The system ls prints ACLs with -e (GNU ls from coreutils does not
    # know the flag).  Only the lines after the file's own line are
    # read, so its name is never parsed.
    # shellcheck disable=SC2012
    out=$(/bin/ls -lde "$1" 2>/dev/null) || return 1
    printf '%s\n' "$out" | sed -n '2,$p'
}

# Succeed when an ACL listing has an "allow" entry, or with "inherit",
# an allow entry that new directories inherit.  Plain pattern matching:
# a `| grep -q` pipeline can fail on SIGPIPE under pipefail and read as
# "no match".
swarm_acl_allows() {
    local rest="$1" what="${2:-}" line nl=$'\n'
    # Split on newlines by parameter expansion: a here-string needs a
    # temporary file in Bash 3.2, and a failure there would read as
    # "no match".
    while [ -n "$rest" ]; do
        line="${rest%%"$nl"*}"
        if [ "$line" = "$rest" ]; then
            rest=""
        else
            rest="${rest#*"$nl"}"
        fi
        case "$line" in
            *" allow "*) ;;
            *) continue ;;
        esac
        if [ "$what" != inherit ]; then
            return 0
        fi
        case "$line" in
            *directory_inherit*) return 0 ;;
        esac
    done
    return 1
}

# Check that only the current user can reach the runtime directory.
# The bare repository inside stays writable for the container's agent
# user, whose UID can differ from the host user's, so this directory
# is what keeps other host users out.
swarm_runtime_check() {
    local dir="$1" mode acl
    if [ -L "$dir" ]; then
        echo "ERROR: runtime directory is a symlink: ${dir}" >&2
        return 1
    fi
    if [ ! -d "$dir" ]; then
        echo "ERROR: runtime directory not found: ${dir}" >&2
        return 1
    fi
    if [ ! -O "$dir" ]; then
        echo "ERROR: runtime directory is owned by another user: ${dir}" >&2
        return 1
    fi
    mode=$(swarm_file_mode "$dir") || {
        echo "ERROR: cannot read the mode of ${dir}" >&2
        return 1
    }
    if [ "$mode" != 700 ]; then
        echo "ERROR: runtime directory must be mode 700, not ${mode}:" \
             "${dir}" >&2
        echo "       chmod 700 $(printf '%q' "$dir")" >&2
        return 1
    fi
    acl=$(swarm_acl_entries "$dir") || {
        echo "ERROR: cannot read the ACL of ${dir}" >&2
        return 1
    }
    if swarm_acl_allows "$acl"; then
        echo "ERROR: runtime directory has an ACL that can let other" \
             "users in: ${dir}" >&2
        echo "       chmod -N $(printf '%q' "$dir")" >&2
        return 1
    fi
}

# Create the runtime directory (owner-only) when missing, then check it.
# The directory has to be private from the moment it exists, or another
# user could add entries before any check runs.  mkdir -m 700 gives that
# on Linux even below a default ACL, whose mask it clears.  macOS copies
# inheritable ACL entries into a new directory whatever the mode, so
# creation is refused below one that would let other users in.
swarm_runtime_init() {
    local dir="$1" parent acl
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        parent=$(dirname "$dir")
        while [ ! -e "$parent" ] && [ "$parent" != / ]; do
            parent=$(dirname "$parent")
        done
        # ls -e reads a symlink's own ACL, so look at the directory the
        # new path will actually be created in.
        parent=$(cd -P "$parent" && pwd -P) || return 1
        acl=$(swarm_acl_entries "$parent") || {
            echo "ERROR: cannot read the ACL of ${parent}" >&2
            return 1
        }
        if swarm_acl_allows "$acl" inherit; then
            echo "ERROR: ${parent} has an inheritable ACL entry that" \
                 "would let other users into a new runtime directory." >&2
            echo "       Remove that entry, or set SWARM_RUNTIME_DIR to" \
                 "a path below a directory without one." >&2
            return 1
        fi
        (umask 077 && mkdir -p "$(dirname "$dir")" \
            && mkdir -m 700 "$dir") || return 1
    fi
    swarm_runtime_check "$dir"
}

# Releases before the runtime directory kept the bare repository in
# /tmp with world-writable modes, so any local user could have changed
# its refs.  That state is never adopted; print how to recover it.
# Only a directory owned by the current user counts: anyone can create
# a path in /tmp, and only its owner could remove it.  Agents pushed to
# it as the container's user, whose files rm cannot always delete on
# Linux, so the old state goes through Docker as in rm_docker_dir.
swarm_refuse_legacy_state() {
    local project="$1" legacy quoted path remove=""
    local grace="${SWARM_STOP_TIMEOUT:-60}"
    legacy="/tmp/${project}-upstream.git"
    if [ -L "$legacy" ] || [ ! -d "$legacy" ] || [ ! -O "$legacy" ]; then
        return 0
    fi
    quoted=$(printf '%q' "$legacy")
    # List the paths that exist instead of printing a glob, which zsh
    # rejects when nothing matches.
    for path in "$legacy" "/tmp/${project}-mirror-"*.git \
            "/tmp/${project}-swarm.env"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            remove+=" $(printf '%q' "$path")"
        fi
    done
    cat >&2 <<EOF
ERROR: ${legacy} is left over from an older swarm-core.
This version keeps its state in a private runtime directory and does
not reuse the old one, since other local users could write to it.
Containers of the older release push to it.  Stop any that still run
with the grace ./launch.sh stop gives, so their agents can push their
last commits:
  docker stop -t ${grace} <container>...
To keep agent commits from it, fetch them and review them before you
merge anything:
  git fetch ${quoted} '+refs/heads/*:refs/remotes/legacy-swarm/*'
Then remove the old state.  The agents wrote part of it as the
container's user, so remove it through Docker:
  docker run --rm -v /tmp:/tmp alpine rm -rf${remove}
EOF
    return 1
}

# Print a command that removes the bare repository of runtime directory
# DIR.  The agents wrote files in it as the container's user, which rm
# run by the user cannot always delete on Linux, so rm runs as root in
# a container, as in rm_docker_dir.  Only DIR is mounted.
swarm_bare_rm_command() {
    printf 'docker run --rm -v %s:/runtime alpine' "$(printf '%q' "$1")"
    printf ' rm -rf /runtime/upstream.git'
}

SWARM_STATE_SCHEMA="swarm-core.state/v1"

# Print the state file as compact JSON when it holds exactly one
# swarm-core.state/v1 object; fail otherwise.
swarm_state_read() {
    jq -cse --arg schema "$SWARM_STATE_SCHEMA" \
        'select(length == 1) | .[0] | objects
         | select(.schema == $schema)' "$1" 2>/dev/null
}

# Replace the state file with one rename, so a reader never sees a
# partly written file.  mktemp creates the new file with mode 600.
swarm_state_write() {
    local file="$1" json="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if ! printf '%s\n' "$json" > "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}
