#!/bin/bash

# Project identity and the per-project runtime directory, shared by
# launch.sh, harvest.sh and the dashboard.  User-facing labels should
# keep the raw repository basename; internal Docker identifiers must be
# lowercase and separator-safe.

swarm_project_id() {
    local raw="${1:-}" lower out="" c last_sep=false i
    # The letters are spelled out: a range such as [a-z] follows the
    # locale and can match letters that Docker names do not allow.
    local alnum="abcdefghijklmnopqrstuvwxyz0123456789"
    lower="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    for ((i = 0; i < ${#lower}; i++)); do
        c="${lower:i:1}"
        case "$c" in
            ["$alnum"])
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
            ["$alnum"]) break ;;
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

# Project id for a checkout: SWARM_PROJECT when set, otherwise the
# sanitized basename of the repository root.  The runtime directory,
# the image and the container names all derive from it.
swarm_project_resolve() {
    local root="$1" id
    if [ -n "${SWARM_PROJECT:-}" ]; then
        id=$(swarm_project_id "$SWARM_PROJECT")
        if [ "$id" != "$SWARM_PROJECT" ]; then
            echo "ERROR: SWARM_PROJECT must be a project id: lowercase" \
                 "letters and digits, with '.', '_' or '-' between" \
                 "them (for example '${id}')." >&2
            return 1
        fi
        printf '%s' "$id"
        return 0
    fi
    swarm_project_id "$(basename "$root")"
}

# Physical path of a checkout, the form recorded as its owner.
swarm_checkout_path() {
    (cd -P "$1" && pwd -P)
}

# Apply a jq filter to the state file and replace it.  A missing file
# starts from an empty object; a file that is not valid state is an
# error.  Extra arguments go to jq (--arg name value, ...).
swarm_state_update() {
    local file="$1" filter="$2" state
    shift 2
    if [ -e "$file" ] || [ -L "$file" ]; then
        state=$(swarm_state_read "$file") || {
            echo "ERROR: not a ${SWARM_STATE_SCHEMA} state file: ${file}" >&2
            return 1
        }
    else
        state='{}'
    fi
    state=$(printf '%s' "$state" | jq -c \
        --arg schema "$SWARM_STATE_SCHEMA" "$@" \
        ".schema = \$schema | ${filter}") || return 1
    swarm_state_write "$file" "$state"
}

# The state file records which checkout owns a runtime directory, so
# two checkouts that resolve to the same project id never share its
# bare repo, image or containers.  Fail when the directory belongs to
# another checkout.  Callers run swarm_runtime_check first.
swarm_runtime_owner_check() {
    local dir="$1" root="$2" project="$3" file canonical state owner
    file="$dir/state.json"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        return 0
    fi
    canonical=$(swarm_checkout_path "$root") || return 1
    state=$(swarm_state_read "$file") || {
        echo "ERROR: not a ${SWARM_STATE_SCHEMA} state file: ${file}" >&2
        return 1
    }
    owner=$(printf '%s' "$state" | jq -r '.repo_root // empty') \
        || return 1
    if [ -n "$owner" ] && [ "$owner" != "$canonical" ]; then
        echo "ERROR: project id '${project}' belongs to another" \
             "checkout." >&2
        echo "  runtime:  ${dir}" >&2
        echo "  owner:    ${owner}" >&2
        echo "  this one: ${canonical}" >&2
        echo "Give this checkout its own id with SWARM_PROJECT. If it" \
             "is the same checkout at a new path, harvest from the old" \
             "path first, or remove the runtime directory once nothing" \
             "in it is needed." >&2
        return 1
    fi
}

# Record this checkout as the owner of the runtime directory, or fail
# when another checkout owns it.
swarm_runtime_claim() {
    local dir="$1" root="$2" project="$3" canonical
    swarm_runtime_owner_check "$dir" "$root" "$project" || return 1
    canonical=$(swarm_checkout_path "$root") || return 1
    swarm_state_update "$dir/state.json" \
        '.project = $project | .repo_root = $root' \
        --arg project "$project" --arg root "$canonical"
}

# Read-only commands run this: when the runtime directory exists it
# has to be private and owned by this checkout.  A missing directory
# is fine, and nothing is created.
swarm_runtime_verify() {
    local dir="$1" root="$2" project="$3"
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        return 0
    fi
    swarm_runtime_check "$dir" || return 1
    swarm_runtime_owner_check "$dir" "$root" "$project"
}

# Every container the engine creates carries its project id and the
# checkout that created it in these labels.
SWARM_PROJECT_LABEL="swarm-core.project"
SWARM_CHECKOUT_LABEL="swarm-core.checkout"

# docker ps format and jq definitions for the project's containers.  A
# container is the project's when its project label is the id,
# whatever its name; one without labels (from an older release) counts
# when its name is a numbered agent, post-process or interactive name of
# the id.  Names are matched literally, so a '.' in the id matches only
# itself.
SWARM_CONTAINER_FORMAT='{"id":{{json .ID}},"name":{{json .Names}},"project":'
SWARM_CONTAINER_FORMAT+='{{json (.Label "'"$SWARM_PROJECT_LABEL"'")}},'
SWARM_CONTAINER_FORMAT+='"owner":{{json (.Label "'"$SWARM_CHECKOUT_LABEL"'")}}'
SWARM_CONTAINER_FORMAT+='}'
SWARM_JQ_PROJECT_CONTAINER='def project_name($prefix):
    startswith($prefix)
    and (ltrimstr($prefix) as $rest
        | $rest == "post"
          or ($rest | startswith("interactive-"))
          or ($rest | test("^[0-9]+$")));
def project_container($project):
    .project == $project
    or (.project == "" and (.name | project_name($project + "-agent-")));'

# Print the project's containers as JSON lines (id, name, project,
# owner).
# Two listings: by project label, which finds a labeled container even
# after a rename, and by name, for unlabeled ones (Docker's name filter
# is a regular expression and only narrows that list).
swarm_project_containers() {
    local project="$1" by_label by_name
    by_label=$(docker ps -a \
        --filter "label=${SWARM_PROJECT_LABEL}=${project}" \
        --format "$SWARM_CONTAINER_FORMAT") || return 1
    by_name=$(docker ps -a --filter "name=${project}-agent-" \
        --format "$SWARM_CONTAINER_FORMAT") || return 1
    printf '%s\n%s\n' "$by_label" "$by_name" \
        | jq -cs --arg project "$project" "${SWARM_JQ_PROJECT_CONTAINER}"'
            map(select(project_container($project)))
            | unique_by(.name) | .[]'
}

# Print the names of the project's containers, one per line.
swarm_project_container_names() {
    local project="$1" containers
    containers=$(swarm_project_containers "$project") || return 1
    printf '%s\n' "$containers" | jq -r '.name'
}

# Print the names of the project's interactive containers.
swarm_interactive_container_names() {
    local project="$1" names
    names=$(swarm_project_container_names "$project") || return 1
    printf '%s\n' "$names" | while IFS= read -r name; do
        case "$name" in
            "${project}-agent-interactive-"*) printf '%s\n' "$name" ;;
        esac
    done
}

# Container names are shared by everything on the Docker host, while
# the runtime directory can live anywhere, so two checkouts with the
# same project id could still reach each other's containers.  Fail when
# one of the project's containers belongs to another checkout, or has
# no label because an older release created it.
swarm_containers_verify() {
    local project="$1" root="$2" canonical containers foreign
    local others unlabeled
    canonical=$(swarm_checkout_path "$root") || return 1
    containers=$(swarm_project_containers "$project") || {
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    }
    foreign=$(printf '%s\n' "$containers" | jq -r --arg root "$canonical" '
        select(.owner != $root)
        | "  \(.name) (\(if .owner == "" then "no owner label"
                         else "owner: " + .owner end))"') || {
        echo "ERROR: cannot read the Docker container list." >&2
        return 1
    }
    if [ -z "$foreign" ]; then
        return 0
    fi
    echo "ERROR: containers of project id '${project}' do not belong" \
         "to this checkout:" >&2
    printf '%s\n' "$foreign" >&2
    others=$(printf '%s\n' "$containers" | jq -rs --arg root "$canonical" \
        'map(select(.owner != "" and .owner != $root)) | length') \
        || others=1
    unlabeled=$(printf '%s\n' "$containers" \
        | jq -rs 'map(select(.owner == "") | .name) | join(" ")') \
        || unlabeled=""
    if [ "$others" != 0 ]; then
        echo "Give this checkout its own id with SWARM_PROJECT, or stop" \
             "those containers from the checkout that owns them and" \
             "remove them with docker rm once their work is harvested." >&2
    fi
    # An older release started these, and its agents push to the bare
    # repository in /tmp: stopping them without the grace period can
    # lose their last commits.
    if [ -n "$unlabeled" ]; then
        echo "Containers without an owner label come from an older" \
             "swarm-core. Stop them with the grace ./launch.sh stop" \
             "gives, so their agents can push their last commits:" >&2
        echo "  docker stop -t ${SWARM_STOP_TIMEOUT:-60} ${unlabeled}" >&2
        echo "Then fetch their work and remove them as \"Upgrading from" \
             "/tmp state\" in USAGE.md describes." >&2
    fi
    return 1
}

# Print the ID of container NAME when it carries this project id and
# this checkout, nothing when there is no such container, and fail
# (saying why) otherwise.  Callers act on the printed ID, so a
# container that takes the name later is not touched.
swarm_own_container_id() {
    local name="$1" checkout="$2" project="$3" info verdict
    info=$(docker container inspect --format \
        '{"id":{{json .Id}},"labels":{{json .Config.Labels}}}' \
        "$name" 2>/dev/null) || return 0
    verdict=$(printf '%s\n' "$info" | jq -r --arg me "$checkout" \
        --arg project "$project" --arg pkey "$SWARM_PROJECT_LABEL" \
        --arg ckey "$SWARM_CHECKOUT_LABEL" '
        (.labels // {}) as $l
        | ($l[$pkey] // "") as $p
        | ($l[$ckey] // "") as $owner
        | if $p != $project and $p != "" then "project: " + $p
          elif $owner == $me and $p == $project then "own " + .id
          elif $owner == "" then "no owner label"
          else "owner: " + $owner end') || {
        echo "ERROR: cannot read container ${name}." >&2
        return 1
    }
    case "$verdict" in
        "own "*)
            printf '%s' "${verdict#own }" ;;
        *)
            echo "ERROR: container ${name} does not belong to this" \
                 "checkout and project (${verdict})." >&2
            return 1 ;;
    esac
}

# Print "name id" lines for the project's containers that this checkout
# owns, so that callers can address each container by ID.
swarm_own_containers() {
    local project="$1" root="$2" canonical containers
    canonical=$(swarm_checkout_path "$root") || return 1
    containers=$(swarm_project_containers "$project") || return 1
    printf '%s\n' "$containers" | jq -r --arg root "$canonical" \
        'select(.owner == $root) | "\(.name) \(.id)"'
}

# An engagement is one life of the bare repo: it starts when the bare
# repo is created, and every later phase (post-process, interactive,
# harvest) belongs to it.  The id is SWARM_ENGAGEMENT_ID when the
# caller sets it, otherwise one the engine makes up.

# ASCII letters and digits, spelled out: bracket ranges such as
# [A-Za-z] follow the locale and can match other letters.
SWARM_ALNUM="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

# Succeed when the argument is a usable engagement id: 1 to 64 ASCII
# letters, digits, '.', '_' or '-', starting with a letter or digit.
swarm_engagement_id_valid() {
    local id="$1"
    case "$id" in
        ["$SWARM_ALNUM"]*) ;;
        *) return 1 ;;
    esac
    case "$id" in
        *[!"$SWARM_ALNUM"._-]*) return 1 ;;
    esac
    [ "${#id}" -le 64 ]
}

# Print the id for a new engagement.
swarm_engagement_new() {
    local rand
    if [ -n "${SWARM_ENGAGEMENT_ID+x}" ]; then
        printf '%s' "$SWARM_ENGAGEMENT_ID"
        return 0
    fi
    rand=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n') || return 1
    printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$rand"
}

# Fail when SWARM_ENGAGEMENT_ID is set and is not a usable id.  Set but
# empty counts as set: only an unset variable means "no engagement
# named".
swarm_engagement_env_check() {
    if [ -n "${SWARM_ENGAGEMENT_ID+x}" ] \
            && ! swarm_engagement_id_valid "$SWARM_ENGAGEMENT_ID"; then
        echo "ERROR: SWARM_ENGAGEMENT_ID must be 1-64 letters, digits," \
             "'.', '_' or '-', starting with a letter or digit." >&2
        return 1
    fi
}

# Print the engagement recorded in the state file (empty when none).
swarm_engagement_recorded() {
    local file="$1" state
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        return 0
    fi
    state=$(swarm_state_read "$file") || {
        echo "ERROR: not a ${SWARM_STATE_SCHEMA} state file: ${file}" >&2
        return 1
    }
    printf '%s' "$state" | jq -r '.engagement_id // empty'
}

# A later phase joins the recorded engagement.  Fail when the caller
# names a different one, or names one while none is recorded.
swarm_engagement_join() {
    local file="$1" recorded
    recorded=$(swarm_engagement_recorded "$file") || return 1
    if [ -z "${SWARM_ENGAGEMENT_ID+x}" ]; then
        return 0
    fi
    if [ -z "$recorded" ] || [ "$SWARM_ENGAGEMENT_ID" != "$recorded" ]; then
        echo "ERROR: SWARM_ENGAGEMENT_ID is ${SWARM_ENGAGEMENT_ID}, but" \
             "the bare repo belongs to engagement" \
             "'${recorded:-<none recorded>}'." >&2
        return 1
    fi
}

# Succeed when descriptor FD is open on FILE (same device and inode).
# Linux resolves /dev/fd/N to the open file, so the test builtin can
# compare them.  macOS reports /dev/fd/N on its own device, so there
# the descriptor is checked with fstat through the system perl.
swarm_fd_is_file() {
    local fd="$1" file="$2"
    if [ "$(uname -s)" = Darwin ]; then
        /usr/bin/perl -e '
            open(my $fh, ">&=", $ARGV[0]) or exit 1;
            my @a = stat($fh) or exit 1;
            my @b = stat($ARGV[1]) or exit 1;
            exit(($a[0] == $b[0] && $a[1] == $b[1]) ? 0 : 1);
        ' "$fd" "$file" 2>/dev/null
        return
    fi
    [ -e "/dev/fd/$fd" ] && [ "/dev/fd/$fd" -ef "$file" ]
}

# Take the engagement lock of runtime directory DIR, or fail at once
# when another operation holds it.  flock(1) keeps the lock for as long
# as the descriptor stays open, so children that inherit it share it.
# A caller that already holds the lock passes its descriptor in
# SWARM_LOCK_FD: the engine checks that the descriptor is this lock
# file and locks through it.
swarm_lock() {
    local dir="$1" lock fd
    lock="$dir/engagement.lock"
    if ! command -v flock >/dev/null 2>&1; then
        echo "ERROR: flock is required to lock ${lock}" \
             "(on macOS: brew install flock)." >&2
        return 1
    fi
    if [ -n "${SWARM_LOCK_FD:-}" ]; then
        fd="$SWARM_LOCK_FD"
        case "$fd" in
            *[!0123456789]*)
                echo "ERROR: SWARM_LOCK_FD must be a descriptor number." >&2
                return 1 ;;
        esac
        if [ "$fd" -lt 3 ] || ! swarm_fd_is_file "$fd" "$lock"; then
            echo "ERROR: SWARM_LOCK_FD ${fd} is not open on ${lock}." >&2
            return 1
        fi
    else
        if [ -L "$lock" ]; then
            echo "ERROR: lock file is a symlink: ${lock}" >&2
            return 1
        fi
        fd=9
        exec 9>>"$lock" || return 1
    fi
    if ! flock -n "$fd"; then
        echo "ERROR: another swarm-core operation holds ${lock}." >&2
        return 1
    fi
    SWARM_LOCK_FD="$fd"
    export SWARM_LOCK_FD
}

# Close this process's lock descriptor.  A lock that a caller passed in
# stays held by the caller.
swarm_unlock() {
    local fd="${SWARM_LOCK_FD:-}"
    case "$fd" in
        ''|*[!0123456789]*) return 0 ;;
    esac
    eval "exec ${fd}>&-"
    unset SWARM_LOCK_FD
}
