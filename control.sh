#!/bin/bash
# The control interface of swarm-core, swarm-core.control/v1, for a
# program that drives engagements (a CI job, a scheduler).  USAGE,
# CONTROL INTERFACE, documents it.
#
#   control.sh --interface swarm-core.control/v1 COMMAND [ARGS...]
#   control.sh version
#   control.sh --help
#
# Actions are the engine's own commands, run by exec before anything
# else (same process, arguments, descriptors, output and exit status).
# Queries (version, observe) change nothing: no file, directory, lock,
# container, volume, image, Git object or ref, Docker context or
# configuration; no temporary file either (no mktemp, here-document or
# here-string, each of which Bash 3.2 writes to a file); and their only
# Docker calls are context show, info, ps, container inspect, volume ls
# and volume inspect.
set -uo pipefail

# CDPATH off: with it, cd prints where it went.
SWARM_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CONTROL_INTERFACE="swarm-core.control/v1"

control_usage() {
    printf '%s\n' \
        "Usage: control.sh --interface ${CONTROL_INTERFACE} COMMAND [ARGS...]" \
        "       control.sh version" \
        "" \
        "Queries: version, observe." \
        "Actions: start, stop, wait, post-process, retire, cleanup," \
        "         interactive, chat, shell (launch.sh's), and harvest" \
        "         (harvest.sh)." \
        "" \
        "USAGE, CONTROL INTERFACE, documents each one."
}

# Print "swarm-core: REASON: MESSAGE" as one line on stderr (observe's
# own, CONTROL_ERR_FD, while it sends what the tools it runs print to
# /dev/null) and exit with STATUS.
control_fail() {
    local status="$1" reason="$2" msg
    shift 2
    msg="$*"
    msg="${msg//$'\n'/ }"
    msg="${msg//$'\r'/ }"
    printf 'swarm-core: %s: %s\n' "$reason" "$msg" >&"${CONTROL_ERR_FD:-2}"
    exit "$status"
}

# Print the first line of TEXT without an "ERROR: " prefix: a reason's
# message is one line.
control_first_line() {
    local line="${1%%$'\n'*}"
    printf '%s' "${line#ERROR: }"
}

# The engine's version, from VERSION.
control_engine_version() {
    local v=""
    IFS= read -r v 2>/dev/null < "$SWARM_DIR/VERSION" || [ -n "$v" ] \
        || control_fail 1 engine-unreadable "cannot read ${SWARM_DIR}/VERSION"
    case "$v" in
        ''|*[!0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-]*)
            control_fail 1 engine-unreadable \
                "${SWARM_DIR}/VERSION holds no version" ;;
    esac
    printf '%s' "$v"
}

# version: the engine's version and the interfaces it has, printed
# without jq (its characters were checked).
control_version() {
    local v
    v=$(control_engine_version) || exit 1
    printf '{"schema":"swarm-core.version/v1","engine":"%s","interfaces":["%s"]}\n' \
        "$v" "$CONTROL_INTERFACE"
}

case "${1:-}" in
    -h|--help)
        control_usage
        exit 0 ;;
    version)
        [ $# -eq 1 ] || control_fail 2 usage "version takes no arguments"
        control_version
        exit 0 ;;
    --interface)
        [ $# -ge 2 ] || control_fail 2 usage "--interface needs a value"
        if [ "$2" != "$CONTROL_INTERFACE" ]; then
            control_fail 2 unsupported-interface "this engine has" \
                "${CONTROL_INTERFACE} only (control.sh version lists them)"
        fi
        shift 2 ;;
    "")
        control_fail 2 usage "give --interface ${CONTROL_INTERFACE} and a" \
            "command (control.sh --help shows the grammar)" ;;
    *)
        control_fail 2 usage "give --interface ${CONTROL_INTERFACE}" \
            "before the command" ;;
esac
if [ $# -eq 0 ]; then
    control_fail 2 usage "no command after --interface" \
        "(control.sh --help shows the grammar)"
fi
CONTROL_CMD="$1"
shift

# Actions: the engine's commands, by exec, before anything is read.
case "$CONTROL_CMD" in
    start|stop|wait|post-process|retire|cleanup|interactive|chat|shell)
        exec "$SWARM_DIR/launch.sh" "$CONTROL_CMD" "$@" ;;
    harvest)
        exec "$SWARM_DIR/harvest.sh" "$@" ;;
    version)
        [ $# -eq 0 ] || control_fail 2 usage "version takes no arguments"
        control_version
        exit 0 ;;
    observe)
        [ $# -eq 0 ] || control_fail 2 usage "observe takes no arguments" ;;
    *)
        control_fail 2 usage "unknown command: ${CONTROL_CMD}" ;;
esac

# --- observe -------------------------------------------------------------
# Only read helpers of these files run below: sourcing them defines
# functions and constants, and runs nothing.
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh" 2>/dev/null \
    || control_fail 1 engine-unreadable "cannot read lib/project.sh"
# shellcheck source=lib/preserve.sh
source "$SWARM_DIR/lib/preserve.sh" 2>/dev/null \
    || control_fail 1 engine-unreadable "cannot read lib/preserve.sh"
# shellcheck source=lib/submodules.sh
source "$SWARM_DIR/lib/submodules.sh" 2>/dev/null \
    || control_fail 1 engine-unreadable "cannot read lib/submodules.sh"
# shellcheck source=lib/mirrors.sh
source "$SWARM_DIR/lib/mirrors.sh" 2>/dev/null \
    || control_fail 1 engine-unreadable "cannot read lib/mirrors.sh"
# shellcheck source=lib/target.sh
source "$SWARM_DIR/lib/target.sh" 2>/dev/null \
    || control_fail 1 engine-unreadable "cannot read lib/target.sh"

# Fail with reason internal: a tool failed where it should not (STEP
# says where).
control_internal() {
    control_fail 1 internal "$*"
}

# Fail with reason missing-tool unless each command is on PATH.
control_need() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 \
            || control_fail 1 missing-tool "${t} is not installed"
    done
}

# Apple's /usr/bin/git is a shim that runs the developer tools' git, and
# may first write a cache of where they are (xcrun_db) in a temporary
# directory.  On macOS, when the git on PATH is that shim (the same
# file), a query puts the developer tools' bin first on PATH, which
# holds no other tool it runs.
control_git_unshim() {
    local g dev
    [ "$(uname -s)" = Darwin ] || return 0
    g=$(command -v git) || return 0
    # The same file, however PATH reaches it (., .., a link to the file
    # or to a directory on the way).
    [ "$g" -ef /usr/bin/git ] || return 0
    if ! dev=$(/usr/bin/xcode-select -p 2>/dev/null) \
            || [ ! -x "$dev/usr/bin/git" ]
    then
        control_fail 1 missing-tool "git: /usr/bin/git runs the developer" \
            "tools' git, and xcode-select names no developer tools with one"
    fi
    PATH="$dev/usr/bin:$PATH"
    export PATH
}

# Git writes trace files where the environment or the configuration
# says (GIT_TRACE and the other trace1 variables, trace2.*Target): a
# query unsets the trace1 variables and sets trace2's to 0, which also
# turns off the targets of every configuration file.
control_git_quiet() {
    local v
    for v in "${!GIT_TRACE@}"; do
        unset "$v"
    done
    GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
    export GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
}

# Print the state file FILE as compact JSON (swarm_state_read), or
# nothing when there is none.  Fails with reason state-unreadable when
# it is there but not a regular file, or not one swarm-core.state/v1
# object.
control_state_read() {
    local file="$1" state
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        return 0
    fi
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        control_fail 1 state-unreadable "${file} is not a regular file"
    fi
    state=$(swarm_state_read "$file") \
        || control_fail 1 state-unreadable \
            "${file} is not one ${SWARM_STATE_SCHEMA} object"
    printf '%s' "$state"
}

# What observe reports of a state (compact JSON on stdin): the owner and
# project it records, whether a cleanup is pending, and the engagement
# (null when none is recorded), its fields typed as USAGE gives them.
# Fails on a field of the wrong type.
# shellcheck disable=SC2016
CONTROL_STATE_JQ='
def os: . == null or type == "string";
def txt: if . == null or . == "" then null else . end;
if ([.repo_root, .project, .engagement_id, .engagement_token,
        .engagement_started_at, .base_commit, .docker_daemon]
        | all(os)) | not
then error("a field is not a string")
elif has("cleanup") and ((.cleanup | type) != "object"
        or (.cleanup.started_at | type) != "string"
        or (.cleanup.runs | type) != "array")
then error("the cleanup checkpoint is malformed")
else
    {owner: (.repo_root // ""), project: (.project // ""),
     cleanup: has("cleanup"),
     engagement: (if (.engagement_id // "") == "" then null else
        {id: .engagement_id,
         token: (.engagement_token | txt),
         started_at: (.engagement_started_at | txt),
         base_commit: (.base_commit | txt),
         docker_daemon: (.docker_daemon | txt),
         target: (if has("target") | not then null else .target
            | {repo, rev, commit, format,
               base: (if .base_commit == null then null
                      else {repo: .base_repo, rev: .base_rev,
                            commit: .base_commit} end)} end),
         cleanup_checkpoint: (if has("cleanup") | not then null else
            {recorded_at: .cleanup.started_at,
             run_count: (.cleanup.runs | length)} end)} end)}
end'

# sha256 of standard input, hex only.
control_sha256() {
    local h
    if command -v sha256sum >/dev/null 2>&1; then
        h=$(sha256sum) || return 1
    else
        h=$(shasum -a 256) || return 1
    fi
    printf '%s' "${h%% *}"
}

# A container inspection (docker container inspect, on stdin) as an
# observe entry, or nothing when its labels are not the project's and
# the checkout's.
# shellcheck disable=SC2016
CONTROL_CONTAINER_JQ='
.[0] as $c | ($c.Config.Labels // {}) as $l
| def lab($k): ($l[$k] // "") | if . == "" then null else . end;
  def num: if . != null and test("^[1-9][0-9]{0,8}$") then tonumber
           else null end;
  def when: if . == null or . == "" or . == "0001-01-01T00:00:00Z"
            then null else . end;
  select($l[$pk] == $project and $l[$ck] == $checkout)
| {id: $c.Id, name: ($c.Name | ltrimstr("/")), role: lab($rk),
   profile_index: (lab($ik) | num), agent_number: (lab($nk) | num),
   engagement: lab($ek), engagement_token: lab($tk),
   state: $c.State.Status, error: ($c.State.Error | when),
   exit_code: (if $c.State.Status == "exited" or $c.State.Status == "dead"
               then $c.State.ExitCode else null end),
   oom_killed: ($c.State.OOMKilled == true),
   created_at: $c.Created, started_at: ($c.State.StartedAt | when),
   finished_at: ($c.State.FinishedAt | when)}'

# A volume inspection (docker volume inspect, on stdin) as an observe
# entry, or nothing when its labels are not the project's and the
# checkout's.
# shellcheck disable=SC2016
CONTROL_VOLUME_JQ='
.[0] as $v | ($v.Labels // {}) as $l
| def lab($k): ($l[$k] // "") | if . == "" then null else . end;
  select($l[$pk] == $project and $l[$ck] == $checkout)
| {volume: $v.Name, container: lab($wk), kind: lab($kk),
   engagement: lab($ek), engagement_token: lab($tk)}'

# Run jq FILTER ($1) on the inspection on stdin with the label keys,
# PROJECT ($2) and CHECKOUT ($3) as variables.  Fails, silently, unless
# stdin is exactly one inspection: one JSON array of one object (empty
# output, two documents or no JSON are no inspection).
control_jq_labels() {
    local filter="$1" project="$2" checkout="$3"
    jq -c -s 2>/dev/null \
        'if length == 1 and (.[0] | type == "array" and length == 1
                and (.[0] | type == "object"))
         then .[0] | '"$filter"' else error("not one inspection") end' \
        --arg project "$project" --arg checkout "$checkout" \
        --arg pk "$SWARM_PROJECT_LABEL" --arg ck "$SWARM_CHECKOUT_LABEL" \
        --arg ek "$SWARM_ENGAGEMENT_LABEL" --arg tk "$SWARM_TOKEN_LABEL" \
        --arg rk "$SWARM_ROLE_LABEL" --arg ik "$SWARM_PROFILE_INDEX_LABEL" \
        --arg nk "$SWARM_AGENT_NUMBER_LABEL" \
        --arg wk "$SWARM_CONTAINER_LABEL" --arg kk "$SWARM_KIND_LABEL"
}

# Fill CONTROL_CONTAINERS and CONTROL_WORKSPACES (JSON arrays) with the
# containers and the workspace volumes of project PROJECT and checkout
# CHECKOUT (canonical), and CONTROL_PROJECT_CONTAINERS with the
# project's containers as swarm_project_containers lists them; fails
# when Docker does not answer.  A container or volume gone between its
# listing and its inspection is left out; anything else that fails
# fails it all.
control_docker_inventory() {
    local project="$1" checkout="$2" ids vols rows
    ids=$(docker ps -a --no-trunc \
        --filter "label=${SWARM_PROJECT_LABEL}=${project}" \
        --filter "label=${SWARM_CHECKOUT_LABEL}=${checkout}" \
        --format '{{.ID}}' 2>/dev/null) || return 1
    # One entry per line; the loop runs in a subshell of the pipe, and
    # its exit status is the pipe's (pipefail).
    rows=$(printf '%s\n' "$ids" | while IFS= read -r id; do
        [ -n "$id" ] || continue
        if ! info=$(docker container inspect "$id" 2>/dev/null); then
            left=$(docker ps -aq --no-trunc --filter "id=${id}" \
                2>/dev/null) || exit 1
            [ -z "$left" ] || exit 1
            continue
        fi
        printf '%s' "$info" | control_jq_labels "$CONTROL_CONTAINER_JQ" \
            "$project" "$checkout" || exit 1
    done) || return 1
    CONTROL_CONTAINERS=$(printf '%s' "$rows" | jq -cs 'sort_by(.name)') \
        || return 1
    vols=$(docker volume ls -q \
        --filter "label=${SWARM_PROJECT_LABEL}=${project}" \
        --filter "label=${SWARM_CHECKOUT_LABEL}=${checkout}" \
        2>/dev/null) || return 1
    rows=$(printf '%s\n' "$vols" | while IFS= read -r v; do
        [ -n "$v" ] || continue
        if ! info=$(docker volume inspect "$v" 2>/dev/null); then
            left=$(docker volume ls -q \
                --filter "label=${SWARM_PROJECT_LABEL}=${project}" \
                --filter "label=${SWARM_CHECKOUT_LABEL}=${checkout}" \
                2>/dev/null) || exit 1
            # (pattern): Bash 3.2 takes a bare pattern's ")" inside
            # $(...) for the end of the substitution.
            case $'\n'"${left}"$'\n' in
                (*$'\n'"${v}"$'\n'*) exit 1 ;;
            esac
            continue
        fi
        printf '%s' "$info" | control_jq_labels "$CONTROL_VOLUME_JQ" \
            "$project" "$checkout" || exit 1
    done) || return 1
    CONTROL_WORKSPACES=$(printf '%s' "$rows" | jq -cs 'sort_by(.volume)') \
        || return 1
    CONTROL_PROJECT_CONTAINERS=$(swarm_project_containers "$project" \
        2>/dev/null) || return 1
}

# The mirrors' conditions in runtime directory RT for an engagement
# whose base is BASE (empty when unknown), one per line: legacy-mirrors;
# mirrors-incomplete (a manifest or a mirror cut off while it was
# written, a mirrors directory or manifest this release cannot use, a
# mirror whose refs/swarm/gitlink is not its commit); mirrors-missing (a
# mirror the manifest lists is gone); or nothing.  The checks of
# swarm_mirrors_state, swarm_mirrors_manifest_ok and swarm_mirrors_ready,
# read-only.  Without the base, the manifest's form is checked, not its
# entries.
control_mirrors_condition() {
    local -x LC_ALL=C
    local m="$1/mirrors" base="$2" e list
    if [ -L "$m" ] || { [ -e "$m" ] && [ ! -d "$m" ]; }; then
        echo mirrors-incomplete
        return 0
    fi
    [ -d "$m" ] || return 0
    if [ -e "$m/manifest.json.new" ] || [ -L "$m/manifest.json.new" ]; then
        echo mirrors-incomplete
        return 0
    fi
    if [ ! -e "$m/manifest.json" ] && [ ! -L "$m/manifest.json" ]; then
        for e in "$m"/* "$m"/.[!.]* "$m"/..?*; do
            if [ -e "$e" ] || [ -L "$e" ]; then
                echo legacy-mirrors
                return 0
            fi
        done
        return 0
    fi
    if [ -L "$m/manifest.json" ] || [ ! -f "$m/manifest.json" ]; then
        echo mirrors-incomplete
        return 0
    fi
    if [ -z "$base" ]; then
        jq -e -s --arg schema "$SWARM_MIRRORS_SCHEMA" 'length == 1
            and (.[0] | type == "object" and .schema == $schema
                 and (.mirrors | type == "array"))' "$m/manifest.json" \
            >/dev/null 2>&1 || echo mirrors-incomplete
        return 0
    fi
    if ! jq -e -s --arg schema "$SWARM_MIRRORS_SCHEMA" --arg base "$base" \
            "length == 1 and (.[0] | ${SWARM_MIRRORS_JQ_VALID})" \
            "$m/manifest.json" >/dev/null 2>&1 \
            || ! list=$(jq -r '.mirrors[] | "\(.id) \(.commit) \(.name) \(.path)"' \
                "$m/manifest.json" 2>/dev/null); then
        echo mirrors-incomplete
        return 0
    fi
    # Each entry: its name and path, then its mirror (the loop runs in a
    # subshell of the pipe, and says what it found once at its end).
    printf '%s\n' "$list" | {
        incomplete=false missing=false
        while read -r id commit name path; do
            [ -n "$id" ] || continue
            if ! swarm_mirrors_b64_ok "$name" \
                    || ! swarm_mirrors_b64_ok "$path" \
                    || [ -e "$m/$id.git.new" ] || [ -L "$m/$id.git.new" ]
            then
                incomplete=true
            elif [ ! -e "$m/$id.git" ] && [ ! -L "$m/$id.git" ]; then
                missing=true
            elif [ -L "$m/$id.git" ] || [ ! -d "$m/$id.git" ] \
                    || [ "$(_swarm_mirrors_git --git-dir="$m/$id.git" \
                        rev-parse -q --verify refs/swarm/gitlink \
                        2>/dev/null)" != "$commit" ]; then
                incomplete=true
            fi
        done
        ! $incomplete || echo mirrors-incomplete
        ! $missing || echo mirrors-missing
    }
}

# observe: print the observation document (USAGE, CONTROL
# INTERFACE).
control_observe() {
    local observed_at root canonical project rt out legacy
    local state="" again proj="" engagement=null complete revision=""
    local attempt=0 owner recorded base="" conditions="" ctx=null
    local daemon=null id engine
    CONTROL_CONTAINERS=null
    CONTROL_WORKSPACES=null
    CONTROL_PROJECT_CONTAINERS=""

    observed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || observed_at=""
    case "$observed_at" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) control_internal "cannot read the time" ;;
    esac
    control_need jq git perl
    control_git_unshim
    control_git_quiet
    root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ] \
        || control_fail 1 not-a-checkout \
            "$(pwd -P) is not in a Git working tree"
    canonical=$(swarm_checkout_path "$root") \
        || control_fail 1 not-a-checkout "cannot resolve ${root}"
    out=$(swarm_project_resolve "$root" 2>&1) \
        || control_fail 1 bad-environment "$(control_first_line "$out")"
    project="$out"
    out=$(swarm_runtime_dir "$project" 2>&1) \
        || control_fail 1 bad-environment "$(control_first_line "$out")"
    rt="$out"

    # An existing directory unsafe to use is runtime-unsafe; a place the
    # runtime directory cannot be, bad-environment (as start refuses it).
    if [ -e "$rt" ] || [ -L "$rt" ]; then
        out=$(swarm_runtime_check "$rt" 2>&1) \
            || control_fail 1 runtime-unsafe "$(control_first_line "$out")"
    fi
    out=$(swarm_runtime_location_ok "$rt" "$root" 2>&1) \
        || control_fail 1 bad-environment "$(control_first_line "$out")"

    # The state, read once: everything taken from it comes from that
    # read.  Whether its bare repo is published is checked between that
    # read and another one; when the two differ, it all starts again.
    if [ -e "$rt" ]; then
        while :; do
            attempt=$((attempt + 1))
            proj=""
            engagement=null
            state=$(control_state_read "$rt/state.json") || exit 1
            [ -n "$state" ] || break
            proj=$(printf '%s' "$state" | jq -c "$CONTROL_STATE_JQ" \
                2>/dev/null) \
                || control_fail 1 state-unreadable \
                    "$rt/state.json: a field has the wrong type"
            case "$(printf '%s' "$state" \
                    | jq -r "$_SWARM_TARGET_RECORD_JQ" 2>/dev/null)" in
                none|ok*) ;;
                *) control_fail 1 state-unreadable \
                    "$rt/state.json: its target record is malformed" ;;
            esac
            owner=$(printf '%s' "$proj" | jq -r '.owner') \
                || control_internal "cannot read the state's owner"
            if [ -n "$owner" ] && [ "$owner" != "$canonical" ]; then
                control_fail 1 runtime-foreign "${rt} belongs to the" \
                    "checkout ${owner}"
            fi
            recorded=$(printf '%s' "$proj" | jq -r '.project') \
                || control_internal "cannot read the state's project"
            if [ -n "$recorded" ] && [ "$recorded" != "$project" ]; then
                control_fail 1 runtime-foreign "${rt} belongs to project" \
                    "id ${recorded}"
            fi
            engagement=$(printf '%s' "$proj" | jq -c '.engagement') \
                || control_internal "cannot read the engagement"
            [ "$engagement" != null ] || break
            complete=false
            if swarm_bare_repo_ready "$rt/upstream.git" 2>/dev/null; then
                complete=true
            fi
            again=$(control_state_read "$rt/state.json") || exit 1
            [ "$again" != "$state" ] || break
            [ "$attempt" -lt 3 ] || control_fail 1 state-unstable \
                "$rt/state.json kept changing while it was read"
        done
    fi
    if [ "$engagement" != null ]; then
        command -v sha256sum >/dev/null 2>&1 \
            || command -v shasum >/dev/null 2>&1 \
            || control_fail 1 missing-tool "sha256sum or shasum is not" \
                "installed"
        revision=$(printf '%s' "$state" | control_sha256) \
            || control_internal "cannot digest the state"
        engagement=$(printf '%s' "$engagement" | jq -c \
            --argjson complete "$complete" --arg revision "$revision" \
            '{id, token, started_at, base_commit, docker_daemon,
              revision: $revision, complete: $complete, target,
              cleanup_checkpoint}') \
            || control_internal "cannot print the engagement"
        base=$(printf '%s' "$engagement" | jq -r '.base_commit // empty') \
            || control_internal "cannot read the engagement's base"
    fi

    # Conditions that the files tell.
    if [ -n "$proj" ]; then
        out=$(printf '%s' "$proj" | jq -r '.cleanup') \
            || control_internal "cannot read the cleanup checkpoint"
        [ "$out" != true ] || conditions+="cleanup-pending"$'\n'
    fi
    if [ "$engagement" != null ]; then
        out=$(printf '%s' "$engagement" | jq -r '.docker_daemon == null') \
            || control_internal "cannot read the engagement's daemon"
        [ "$out" != true ] || conditions+="legacy-engagement"$'\n'
    fi
    if [ -d "$rt" ]; then
        out=$(control_mirrors_condition "$rt" "$base")
        [ -z "$out" ] || conditions+="${out}"$'\n'
    fi
    legacy="/tmp/$(swarm_project_id "$(basename "$root")")-upstream.git"
    if [ ! -L "$legacy" ] && [ -d "$legacy" ] && [ -O "$legacy" ]; then
        conditions+="legacy-tmp-state"$'\n'
    fi

    # Docker: one context for every call; null where it did not answer.
    if command -v docker >/dev/null 2>&1 && swarm_docker_pin; then
        if [ -n "${DOCKER_CONTEXT:-}" ] && [ -z "${DOCKER_HOST:-}" ]; then
            ctx=$(jq -n --arg c "$DOCKER_CONTEXT" '$c') \
                || control_internal "cannot print the Docker context"
        fi
        if id=$(swarm_docker_daemon_id); then
            daemon=$(jq -n --arg d "$id" '$d') \
                || control_internal "cannot print the Docker daemon"
            if ! control_docker_inventory "$project" "$canonical"; then
                CONTROL_CONTAINERS=null
                CONTROL_WORKSPACES=null
                CONTROL_PROJECT_CONTAINERS=""
            fi
        fi
    fi
    if [ "$CONTROL_CONTAINERS" != null ]; then
        out=$(printf '%s\n' "$CONTROL_PROJECT_CONTAINERS" \
            | jq -rs --arg root "$canonical" '[.[] | select(.owner != $root)
                | if .owner == "" then "unlabeled-containers"
                  else "foreign-containers" end] | unique | .[]') \
            || control_internal "cannot read the project's containers"
        [ -z "$out" ] || conditions+="${out}"$'\n'
    fi
    if [ "$engagement" = null ]; then
        out=""
        [ ! -d "$rt" ] || out=$(swarm_runtime_leftover_files "$rt")
        if [ -n "$out" ] || { [ "$CONTROL_CONTAINERS" != null ] \
                && [ "$CONTROL_CONTAINERS" != "[]" ]; } \
                || { [ "$CONTROL_WORKSPACES" != null ] \
                && [ "$CONTROL_WORKSPACES" != "[]" ]; }; then
            conditions+="unrecorded-leftovers"$'\n'
        fi
    fi

    engine=$(control_engine_version) || exit 1
    out=$(printf '%s' "$conditions" | jq -R . | jq -s -c \
        --arg schema "swarm-core.observation/v1" \
        --arg interface "$CONTROL_INTERFACE" --arg engine "$engine" \
        --arg at "$observed_at" --arg project "$project" \
        --arg checkout "$canonical" --arg rt "$rt" \
        --argjson context "$ctx" --argjson daemon "$daemon" \
        --argjson engagement "$engagement" \
        --argjson containers "$CONTROL_CONTAINERS" \
        --argjson workspaces "$CONTROL_WORKSPACES" '
        {schema: $schema, interface: $interface, engine: $engine,
         observed_at: $at, project: $project, checkout: $checkout,
         runtime_dir: $rt, docker: {context: $context, daemon: $daemon},
         conditions: (map(select(length > 0)) | unique),
         engagement: $engagement, containers: $containers,
         workspaces: $workspaces}') \
        || control_internal "cannot make the observation"
    [ -n "$out" ] || control_internal "cannot make the observation"
    printf '%s\n' "$out"
}

# What the tools observe runs print on stderr goes to /dev/null, so
# that a reason is the first line there.
exec 9>&2
CONTROL_ERR_FD=9
control_observe 2>/dev/null
