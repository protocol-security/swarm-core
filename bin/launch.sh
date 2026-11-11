#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./bin/launch.sh {start|stop|logs N|status|wait|post-process|interactive}

SWARM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0 [COMMAND] [OPTIONS]

Orchestrate coding agents in Docker containers.
Default command is 'start' when none is specified.

Commands:
  start [OPTIONS]      Build image, create bare repo, launch agents.
  stop                 Stop all running agent containers.
  logs N               Tail logs for agent N (default: 1).
  status               Show running/stopped state for each agent.
  wait                 Wait for already-started numbered agents,
                       then post-process and harvest. Does not
                       start agents.
  post-process         Run only the post-processing agent, then
                       harvest.
  interactive PROFILE  Start an interactive driver session from a
                       named agent profile.
  chat PROFILE         Alias for interactive PROFILE.
  shell PROFILE        Start an interactive shell from a named
                       agent profile.
  retire [--post-process] [--discard-uncommitted]
                       Remove stopped containers whose files all live
                       in their workspace volumes, after copying the
                       Git checkouts they have outside them into the
                       checkout.
  cleanup [--discard-uncommitted]
                       Delete the engagement (containers, workspace
                       volumes, bare repo, mirrors) after copying what
                       Git keeps there into the checkout.

Start options:
  --dashboard          Open the TUI dashboard after launch.

Interactive options:
  --agent NAME         Select agents[].name explicitly.
  --agent-index N      Select the Nth agents[] entry.
  --shell              Open a shell instead of the driver UI.
  --chat               Open the driver UI (default).

Environment:
  ANTHROPIC_API_KEY         API key (required unless OAuth).
  CLAUDE_CODE_OAUTH_TOKEN   OAuth token for subscription auth.
  SWARM_CONFIG              Path to swarmfile (or place swarm.json in repo root).
  SWARM_TITLE               Dashboard title override.
  SWARM_SKIP_DEP_CHECK      Set to 1 to silence version warnings.
  SWARM_RUNTIME_DIR         Runtime directory (bare repo, mirrors, state);
                            default ~/.local/state/swarm-core/<project>.
  SWARM_PROJECT             Project id for the runtime directory, image
                            and containers (default: the repo name).
  SWARM_ENGAGEMENT_ID       Engagement id for a new bare repo, or the one
                            later commands expect (default: generated).
  SWARM_LOCK_FD             Descriptor of an engagement lock the caller
                            already holds.
HELP
    exit 0
fi

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker perl
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"
# shellcheck source=lib/preserve.sh
source "$SWARM_DIR/lib/preserve.sh"
# shellcheck source=lib/submodules.sh
source "$SWARM_DIR/lib/submodules.sh"
# shellcheck source=lib/mirrors.sh
source "$SWARM_DIR/lib/mirrors.sh"
# shellcheck source=lib/target.sh
source "$SWARM_DIR/lib/target.sh"
# shellcheck source=lib/docker-args.sh
source "$SWARM_DIR/lib/docker-args.sh"

# retire and cleanup read and write Git data: none of the caller's GIT_*
# variables may point them at another repository or inject settings
# (only the choice of config files stays).  Before the repository is
# looked up below.
case "${1:-}" in
    retire|cleanup)
        for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
            case "$_v" in
                GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_NOSYSTEM) ;;
                *) unset "$_v" ;;
            esac
        done ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT_RAW="$(basename "$REPO_ROOT")"
PROJECT="$(swarm_project_resolve "$REPO_ROOT")" || exit 1
SWARM_RUN_HASH="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_CONTEXT="${PROJECT_RAW}@${SWARM_RUN_HASH} (${SWARM_RUN_BRANCH})"
RUNTIME_DIR="$(swarm_runtime_dir "$PROJECT")" || exit 1
BARE_REPO="${RUNTIME_DIR}/upstream.git"
MIRROR_DIR="${RUNTIME_DIR}/mirrors"
STATE_FILE="${RUNTIME_DIR}/state.json"
IMAGE_NAME="${PROJECT}-agent"

# Every command acts on this project's containers or runtime directory,
# so none runs when the directory belongs to another checkout.
swarm_runtime_verify "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || exit 1
# Every Docker call of this run, from this first listing on, goes to one
# daemon, even if another terminal switches the context meanwhile.
if ! swarm_docker_pin; then
    echo "ERROR: cannot read the current Docker context." >&2
    exit 1
fi
swarm_containers_verify "$PROJECT" "$REPO_ROOT" || exit 1
CHECKOUT_PATH="$(swarm_checkout_path "$REPO_ROOT")"
CHECKOUT_LABEL="${SWARM_CHECKOUT_LABEL}=${CHECKOUT_PATH}"
PROJECT_LABEL="${SWARM_PROJECT_LABEL}=${PROJECT}"
swarm_engagement_env_check || exit 1

# Expand a single $VAR reference from the host environment.
# Supports "$VAR" (entire value is a reference) only -- not inline
# interpolation.  Returns the original string if no match.
expand_env_ref() {
    local val="$1"
    if [[ "$val" =~ ^\$([A-Za-z_][A-Za-z_0-9]*)$ ]]; then
        local varname="${BASH_REMATCH[1]}"
        printf '%s' "${!varname:-}"
    else
        printf '%s' "$val"
    fi
}

# Compute the comma-separated SWARM_AGENTS build-arg from a config:
# the union of every agent group's driver and, when post_process is
# present and not null, the post-process driver.
# Used as a Dockerfile build-arg to gate per-CLI install layers; missing
# a driver here is what produces "command not found" inside the agent.
compute_swarm_agents() {
    local cfg="$1"
    local default_drv seen=" " out="" drv
    default_drv=$(jq -r '.driver // "claude-code"' "$cfg")
    while IFS= read -r drv; do
        [ -z "$drv" ] && drv="$default_drv"
        [[ "$seen" == *" $drv "* ]] && continue
        seen+="$drv "
        out="${out:+${out},}${drv}"
    done < <(jq -r '.agents[]? | (.driver // "")' "$cfg")
    local pp_drv
    pp_drv=$(jq -r '
        if .post_process == null then ""
        else (.post_process.driver // .driver // "claude-code")
        end' "$cfg")
    if [ -n "$pp_drv" ] && [[ "$seen" != *" $pp_drv "* ]]; then
        out="${out:+${out},}${pp_drv}"
    fi
    printf '%s' "$out"
}

# Build (or rebuild) the agent image with build-args derived from the current
# config.  Docker's layer cache makes this a no-op when the args and Dockerfile
# haven't changed; when the driver set or pinned CLI versions change the cache
# invalidates correctly and the right install layer re-runs.  Called by
# cmd_start *and* cmd_post_process so a standalone post-process invocation
# never reuses an image built for a different driver set (which silently
# produces exit-127 on first session -- see harness's `agent exited with code
# 127` retry path).
build_image() {
    local swarm_agents cc_version codex_version pi_version
    swarm_agents=$(compute_swarm_agents "$CONFIG_FILE")
    cc_version=$(jq -r '.claude_code_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    codex_version=$(jq -r '.codex_cli_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    pi_version=$(jq -r '.pi_version // empty' "$CONFIG_FILE" \
        2>/dev/null || true)
    echo "--- Building agent image (agents: ${swarm_agents}) ---"
    docker build -t "$IMAGE_NAME" \
        --build-arg "SWARM_AGENTS=${swarm_agents}" \
        ${cc_version:+--build-arg "CLAUDE_CODE_VERSION=${cc_version}"} \
        ${codex_version:+--build-arg "CODEX_CLI_VERSION=${codex_version}"} \
        ${pi_version:+--build-arg "PI_VERSION=${pi_version}"} \
        -f "$SWARM_DIR/Dockerfile" "$SWARM_DIR"
}

# Print the state of this checkout's container NAME: its Docker status,
# "not found" when there is none, or "not ours" when a container of
# another checkout or project holds the name.
own_container_state() {
    local id
    if ! id=$(swarm_own_container_id "$1" "$CHECKOUT_PATH" "$PROJECT" \
            2>/dev/null); then
        printf 'not ours'
        return 0
    fi
    if [ -z "$id" ]; then
        printf 'not found'
        return 0
    fi
    # A created container whose start failed reads "failed": nothing
    # runs, and retire takes it.
    if swarm_start_failed "$id"; then
        printf 'failed'
        return 0
    fi
    docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null \
        || printf 'not found'
}

# Lifecycle commands call this before they touch the bare repo or the
# mirrors: stop on state that older releases left in /tmp (named after
# the directory, as they did), create or check the private runtime
# directory, take its engagement lock, and record this checkout as its
# owner.  The lock stays held until the command exits, except that
# interactive releases it once its session is recorded, before docker
# run, and start --dashboard before the dashboard opens; children such
# as harvest.sh inherit it.
prepare_runtime() {
    swarm_refuse_legacy_state "$(swarm_project_id "$PROJECT_RAW")" \
        || exit 1
    # Only where cleanup can work later; checked before anything is made.
    swarm_runtime_location_ok "$RUNTIME_DIR" "$REPO_ROOT" || exit 1
    swarm_runtime_init "$RUNTIME_DIR" || exit 1
    swarm_lock "$RUNTIME_DIR" || exit 1
    swarm_cleanup_pending_check "$STATE_FILE" || exit 1
    swarm_legacy_refuse "$RUNTIME_DIR" "$STATE_FILE" || exit 1
    swarm_engagement_token_check "$STATE_FILE" || exit 1
    swarm_runtime_claim "$RUNTIME_DIR" "$REPO_ROOT" "$PROJECT" || exit 1
}

# Stop unless the runtime directory holds nothing of an engagement and
# the state file records none: no bare repo, no upstream.git.new, no
# mirrors/, no remnant of a cleanup, no container or workspace volume of
# this checkout, no interactive session open or starting.  A new
# engagement starts only there, after ./bin/launch.sh cleanup has preserved
# and removed the last one.  Called under the lock and the pin, by
# start, and by post-process and interactive when they would create the
# engagement.
require_clean_runtime() {
    local left live engaged rc=0 tmp
    left=$(swarm_runtime_leftovers "$RUNTIME_DIR" "$PROJECT" "$REPO_ROOT" \
        "$CHECKOUT_PATH") || exit 1
    live=$(swarm_pending_live "$RUNTIME_DIR") || exit 1
    if [ -n "$live" ]; then
        left="${left:+${left}$'\n'}  interactive sessions: $(printf '%s\n' \
            "$live" | tr '\n' ' ')"
    fi
    engaged=$(swarm_engagement_recorded "$STATE_FILE") || exit 1
    if [ -z "$left" ]; then
        [ -n "$engaged" ] || return 0
        # A run cut off right after recording its engagement leaves the
        # record alone; it still stands for that engagement.
        echo "ERROR: ${STATE_FILE} still records engagement ${engaged}," \
             "with nothing of it left in ${RUNTIME_DIR}.  Run" \
             "./bin/launch.sh cleanup to finish it before a new one" \
             "starts." >&2
        exit 1
    fi
    if [ -z "$engaged" ]; then
        swarm_legacy_explain "$RUNTIME_DIR" \
            "what is left of an engagement it never recorded"
        printf '%s\n' "$left" >&2
        exit 1
    fi
    echo "ERROR: a new engagement starts only on a clean runtime" \
         "directory; ${RUNTIME_DIR} still holds engagement" \
         "${engaged}:" >&2
    printf '%s\n' "$left" >&2
    if [ -d "$BARE_REPO" ] && swarm_tmp_file tmp e3; then
        swarm_preservation_check "$BARE_REPO" "$REPO_ROOT" > "$tmp" || rc=$?
        if [ "$rc" -eq 1 ]; then
            swarm_preservation_explain "$BARE_REPO" < "$tmp"
        fi
        rm -f "$tmp"
    fi
    echo "Stop the agents (./bin/launch.sh stop), run harvest.sh, then" \
         "./bin/launch.sh cleanup: it keeps everything Git had there as" \
         "recovery refs before it deletes anything." >&2
    exit 1
}

# Record the run in the state file, so a standalone dashboard can show
# its title, swarmfile and agent summary.  The file is JSON that
# readers parse with jq; nothing sources it.
write_state_file() {
    local model_summary config_title
    model_summary=$(jq -r \
        '(.prompt // "") as $dp | ($dp | split("/") | .[-1] // "" | rtrimstr(".md")) as $dp_stem |
        [.agents[] | (.count // 0) as $count | select($count > 0) |
          "\($count)x \(.model | split("/") | .[-1])" +
          (if .context == "none" then " ctx:bare"
           elif .context == "slim" then " ctx:slim"
           else "" end) +
          (if .prompt and .prompt != $dp then
            ":" + (.prompt | split("/") | .[-1] | rtrimstr(".md") |
              if startswith($dp_stem + "-") then .[$dp_stem | length + 1:] else . end)
           else "" end)] | join(", ")' \
        "$CONFIG_FILE")
    config_title=$(jq -r '.title // empty' "$CONFIG_FILE" 2>/dev/null || true)
    # prepare_runtime has recorded the owner; keep it.
    swarm_state_update "$STATE_FILE" \
        '.title = $title | .config = $config
         | .num_agents = $num_agents | .model_summary = $model_summary
         | .config_label = $config_label' \
        --arg title "${SWARM_TITLE:-${config_title}}" \
        --arg config "$CONFIG_FILE" \
        --argjson num_agents "$NUM_AGENTS" \
        --arg model_summary "$model_summary" \
        --arg config_label "$(basename "$CONFIG_FILE")"
}

create_bare_repo() {
    local label="${1:-bare repo}" base daemon new="${BARE_REPO}.new"
    local format=""
    echo "--- Creating ${label} ---"
    # The engagement starts from the commit the checkout has now.
    base=$(git -C "$REPO_ROOT" rev-parse --verify --quiet 'HEAD^{commit}') \
        || { echo "ERROR: ${REPO_ROOT} has no commit to start from." >&2
             exit 1; }
    # The clean-runtime check came first; nothing is ever replaced.
    if [ -e "$BARE_REPO" ] || [ -L "$BARE_REPO" ] \
            || [ -e "$new" ] || [ -L "$new" ]; then
        echo "ERROR: ${BARE_REPO} or ${new} is there already." >&2
        exit 1
    fi
    if ! daemon=$(swarm_docker_daemon_id); then
        echo "ERROR: cannot read the Docker daemon id." >&2
        exit 1
    fi
    # Remove scratch left by an interrupted resolution first.  The
    # target is resolved before the engagement is recorded: a failure up
    # to the record leaves no engagement, only scratch.  Its snapshot has
    # the checkout's object format (swarm_target_resolve refuses any
    # other than sha1 and sha256).
    swarm_target_scratch_clean "$RUNTIME_DIR"
    if swarm_target_requested; then
        if ! format=$(git -C "$REPO_ROOT" rev-parse --show-object-format)
        then
            echo "ERROR: cannot read the object format of ${REPO_ROOT}." >&2
            exit 1
        fi
        echo "--- Resolving the target ---"
        swarm_target_resolve "$RUNTIME_DIR" "$format" || exit 1
    fi
    # The engagement is recorded first, with its target: a run stopped
    # from here on leaves an incomplete engagement (target.git or the
    # bare repo missing, at most upstream.git.new and target scratch),
    # which cleanup preserves and removes.
    begin_engagement "$base" "$daemon" "$format" || {
        echo "ERROR: cannot record the engagement in ${STATE_FILE}." >&2
        exit 1
    }
    # The clean-runtime check came first: target.git is not there.
    if [ -n "$format" ] \
            && ! mv "$SWARM_TARGET_PREP" "$RUNTIME_DIR/target.git"; then
        echo "ERROR: cannot publish the target's snapshot as" \
             "${RUNTIME_DIR}/target.git.  Run ./bin/launch.sh cleanup to" \
             "finish this engagement." >&2
        exit 1
    fi
    # Through Git's transport (--no-local), not a copy of the object
    # store: the bare repo gets new files, so the chmod below cannot
    # reach the checkout's own through hardlinks; it borrows nothing
    # through alternates; and it holds what the checkout's branches,
    # tags and HEAD reach, without the objects only other refs
    # (recovery refs among them), the reflogs or nothing reach, which
    # each cleanup would otherwise keep again.  Later commands join any
    # bare repo they find, so the clone gets its name only once it is
    # ready.
    if ! git clone --bare --no-local "$REPO_ROOT" "$new" \
            || ! prepare_bare_repo "$new" "$base" \
            || ! mv "$new" "$BARE_REPO"; then
        echo "ERROR: cannot prepare ${BARE_REPO}." >&2
        # This user's files, which no container has seen yet.
        rm -rf "$new"
        exit 1
    fi
}

# Set up the fresh clone DIR for an engagement that starts at BASE.
# Returns 1 at the first failure.
prepare_bare_repo() {
    local dir="$1" base="$2" ref refs
    # The clone copies every local branch.  Branches that harvest or
    # the preservation checks treat as agent work start empty, so an
    # old local agent-work, interactive or parked branch is never
    # taken for work of this engagement.
    refs=$(git -C "$dir" for-each-ref --format='%(refname)' \
        refs/heads/swarm/ refs/heads/agent-parked/ refs/swarm-runs/) \
        || return 1
    # Ref names cannot contain whitespace or glob characters, so word
    # splitting yields one name per word.
    for ref in $refs; do
        git -C "$dir" update-ref -d "$ref" || return 1
    done
    git -C "$dir" update-ref refs/heads/agent-work "$base" || return 1
    git -C "$dir" update-ref refs/swarm/base "$base" || return 1
    git -C "$dir" symbolic-ref HEAD refs/heads/agent-work || return 1
    # The container's agent user can have a different UID from the host
    # user, so the repo stays writable for everyone.  The owner-only
    # runtime directory around it keeps other host users out.
    git -C "$dir" config core.sharedRepository world || return 1
    chmod -R a+rwX "$dir" || return 1
}

# A new bare repo starts a new engagement: record its id, which every
# later phase checks against SWARM_ENGAGEMENT_ID, and the commit it
# starts from (BASE).  Agents can write to the bare repo, including its
# refs/swarm/base, so the state file keeps the copy that later checks
# of the agents' branches can trust.  With object format FORMAT (a
# target was resolved: swarm_target_resolve's results), the same write
# records the target, its four base fields null without a base;
# without, it records none.  Returns 1 if either fails.
begin_engagement() {
    local base="$1" daemon="$2" format="${3:-}" id token target
    id=$(swarm_engagement_new) || return 1
    token=$(swarm_random_hex 8) || return 1
    target='del(.target)'
    if [ -n "$format" ]; then
        target='def n: if . == "" then null else . end;
            .target = {repo: $repo, repo_physical: $repo_physical,
                rev: $rev, commit: $commit,
                base_repo: ($base_repo | n),
                base_repo_physical: ($base_repo_physical | n),
                base_rev: ($base_rev | n), base_commit: ($base_commit | n),
                format: $format}'
    fi
    # What harvests of an earlier engagement merged means nothing for
    # this one (cleanup drops it too).
    swarm_state_update "$STATE_FILE" \
        "${target} | .engagement_id = \$id | .engagement_started_at = \$at
         | .base_commit = \$base | .docker_daemon = \$daemon
         | .engagement_token = \$token
         | del(.harvested, .harvest_pending)" \
        --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg base "$base" --arg daemon "$daemon" --arg token "$token" \
        --arg repo "${TARGET_REPO:-}" \
        --arg repo_physical "${SWARM_TARGET_REPO_PHYSICAL:-}" \
        --arg rev "${TARGET_REV:-}" --arg commit "${SWARM_TARGET_COMMIT:-}" \
        --arg base_repo "${SWARM_TARGET_BASE_REPO_EFFECTIVE:-}" \
        --arg base_repo_physical "${SWARM_TARGET_BASE_REPO_PHYSICAL:-}" \
        --arg base_rev "${SWARM_TARGET_BASE_COMMIT:+${TARGET_REV_BASE:-}}" \
        --arg base_commit "${SWARM_TARGET_BASE_COMMIT:-}" \
        --arg format "$format" \
        || return 1
    echo "Engagement: ${id}"
}

# Fill TARGET_ARGS from the engagement's target record, under the lock,
# once the engagement was created or joined (the join validator checked
# it; swarm_target_args).
target_args_load() {
    swarm_target_record_read "$STATE_FILE" || exit 1
    swarm_target_args "$RUNTIME_DIR" || exit 1
    TARGET_ARGS=("${SWARM_TARGET_ARGS[@]}")
}

# Fill WORKSPACE_ARGS with a new workspace volume for container NAME
# (kind KIND, context CONTEXT) and the run arguments every engine
# container gets after docker_args, so that an entry there cannot
# replace them: the engagement, its token, the container's ROLE, its
# PROFILE index and its agent NUMBER (the last two empty where they do
# not apply) as labels, no restart policy and no auto-remove (retire and
# cleanup refuse both).  Needs the engagement recorded, so it runs once
# the bare repo was created or joined.
workspace_args() {
    local name="$1" kind="$2" context="$3" role="$4" profile="$5"
    local number="$6" engagement token vol
    engagement=$(swarm_engagement_recorded "$STATE_FILE") || exit 1
    token=$(swarm_engagement_token "$STATE_FILE") || exit 1
    if [ -z "$engagement" ] || [ -z "$token" ]; then
        echo "ERROR: ${STATE_FILE} records no engagement." >&2
        exit 1
    fi
    vol=$(swarm_workspace_volume_create "$name" "$PROJECT" \
        "$CHECKOUT_PATH" "$engagement" "$token" "$kind" "$context") \
        || exit 1
    WORKSPACE_ARGS=(
        --mount "type=volume,src=${vol},dst=/workspace"
        --label "${SWARM_ENGAGEMENT_LABEL}=${engagement}"
        --label "${SWARM_TOKEN_LABEL}=${token}"
        --label "${SWARM_ROLE_LABEL}=${role}"
        --label "${SWARM_PROFILE_INDEX_LABEL}=${profile}"
        --label "${SWARM_AGENT_NUMBER_LABEL}=${number}"
        --restart no --rm=false
    )
}

# A session that creates the bare repo mirrors the submodules too; one
# that joins keeps the mirrors the engagement has, which other sessions
# may be about to mount, and only adds the ones that are missing.  The
# image is built once the checks passed, and before an engagement is
# created, so a failed build leaves the runtime directory clean.
ensure_bare_repo_for_interactive() {
    local engaged
    # The state decides: a recorded engagement is joined, never made
    # again, and only a complete one is joined.
    engaged=$(swarm_engagement_recorded "$STATE_FILE") || exit 1
    if [ -z "$engaged" ]; then
        # A token names an engagement to join, never a new one.
        if [ -n "${SWARM_ENGAGEMENT_TOKEN:-}" ]; then
            echo "ERROR: the engagement this session was started for" \
                 "is not recorded any more." >&2
            exit 1
        fi
        if swarm_target_requested; then
            swarm_target_inputs_check || exit 1
        fi
        require_clean_runtime
        mirror_preflight
        build_image
        create_bare_repo "bare repo for interactive session"
        mirror_submodules
        return
    fi
    swarm_engagement_join "$STATE_FILE" || exit 1
    swarm_engagement_daemon_check "$STATE_FILE" || exit 1
    swarm_engagement_complete "$engaged" "$BARE_REPO" || exit 1
    swarm_target_join_check "$STATE_FILE" "$RUNTIME_DIR" || exit 1

    local bare_head local_head
    bare_head=$(swarm_no_fetch git -C "$BARE_REPO" rev-parse --verify \
        --quiet refs/heads/agent-work 2>/dev/null || true)
    local_head=$(git rev-parse HEAD 2>/dev/null || true)
    if [ -n "$bare_head" ] && [ "$bare_head" != "$local_head" ] \
            && git merge-base --is-ancestor "$bare_head" HEAD 2>/dev/null; then
        echo "ERROR: ${BARE_REPO} is stale (agent-work" \
             "${bare_head:0:7} behind local HEAD" \
             "${local_head:0:7})." >&2
        echo "       To start from the current HEAD, end this" \
             "engagement: stop the agents, run harvest.sh, then" \
             "./bin/launch.sh cleanup, which keeps everything as recovery" \
             "refs." >&2
        exit 1
    fi
    build_image
    mirror_submodules missing
}

# Print the commit the engagement started from, as begin_engagement
# recorded it in the state file (the bare repo's refs/swarm/base is the
# agents' to write).  Fails unless it is a SHA-1 or SHA-256 commit id.
engagement_base() {
    local state base
    state=$(swarm_state_read "$STATE_FILE") || return 1
    base=$(printf '%s' "$state" | jq -r '.base_commit // empty') \
        || return 1
    case "${#base}:${base}" in
        40:*[!0123456789abcdef]*|64:*[!0123456789abcdef]*) return 1 ;;
        40:*|64:*) printf '%s' "$base" ;;
        *) return 1 ;;
    esac
}

# Refuse, before an engagement is created, what the submodule mirrors
# could not give the containers (swarm_mirrors_preflight), so that the
# advice "then start again" works.
mirror_preflight() {
    swarm_mirrors_preflight "$REPO_ROOT" || exit 1
}

# Mirror into MIRROR_DIR the submodules the containers check out, at
# any depth, with mirrors/manifest.json listing them (lib/mirrors.sh).
# A new engagement makes them all.  With "missing", a session that joins
# keeps the mirrors there, which other sessions may be about to mount,
# makes again the ones gone and adds the ones initialized on the host
# since.
mirror_submodules() {
    local base
    # The containers check out the submodule commits the engagement's
    # base records.
    base=$(engagement_base) || {
        echo "ERROR: ${STATE_FILE} records no base commit." >&2
        exit 1
    }
    cd "$REPO_ROOT"
    swarm_mirrors_make "$REPO_ROOT" "$MIRROR_DIR" "$base" "${1:-}" \
        || exit 1
}

# Fill MIRROR_ARGS with the read-only mount of MIRROR_DIR at /mirrors,
# once every mirror its manifest lists is there (swarm_mirrors_ready);
# none when the engagement has nothing to mirror.
mirror_volume_args() {
    local base
    base=$(engagement_base) || {
        echo "ERROR: ${STATE_FILE} records no base commit." >&2
        return 1
    }
    swarm_mirrors_mount_args "$REPO_ROOT" "$MIRROR_DIR" "$base" || return 1
    MIRROR_ARGS=(${SWARM_MIRROR_ARGS[@]+"${SWARM_MIRROR_ARGS[@]}"})
}

available_drivers() {
    find "$SWARM_DIR/lib/drivers" -type f -name '*.sh' \
        -exec basename {} .sh \; | tr '\n' ' '
}

# retire needs no swarmfile: it acts on what the runtime directory and
# Docker already hold.
case "${1:-}" in
    retire)
        shift
        # shellcheck source=lib/preserve.sh
        source "$SWARM_DIR/lib/preserve.sh"
        # shellcheck source=lib/retire.sh
        source "$SWARM_DIR/lib/retire.sh"
        rc=0
        cmd_retire "$@" || rc=$?
        exit "$rc"
        ;;
    cleanup)
        shift
        # shellcheck source=lib/preserve.sh
        source "$SWARM_DIR/lib/preserve.sh"
        # shellcheck source=lib/retire.sh
        source "$SWARM_DIR/lib/retire.sh"
        # shellcheck source=lib/cleanup.sh
        source "$SWARM_DIR/lib/cleanup.sh"
        rc=0
        cmd_cleanup "$@" || rc=$?
        exit "$rc"
        ;;
esac

# Temporary files this run makes, removed when it exits, however it
# does: Bash runs the EXIT trap on exit, under set -e, and when HUP,
# INT or TERM end the script (retire and cleanup, above, make none and
# set their own traps).
SWARM_TMP_FILES=()
# Set when the run gets to an end it means: its last line, or an exit
# with status 0 it makes on purpose.
SWARM_EXIT_OK=false
swarm_tmp_cleanup() {
    if [ "${#SWARM_TMP_FILES[@]}" -gt 0 ]; then
        rm -f "${SWARM_TMP_FILES[@]}"
    fi
}
# The EXIT trap: remove the temporary files, and where Bash needs it
# (swarm_stop_guard_needed), never let a run that stopped short end with
# status 0.  Bash can also run this trap with $? at 0 when a signal ends
# the script, so the check is only made where Bash can end a stopped run
# with 0 itself; there a signal can print the line too.  Any other
# status stays, a signal's too.
swarm_exit_trap() {
    local rc=$?
    swarm_tmp_cleanup
    if [ "$rc" -eq 0 ] && ! $SWARM_EXIT_OK \
            && swarm_stop_guard_needed "${BASH_VERSINFO[0]}" \
                "${BASH_VERSINFO[1]}"; then
        echo "ERROR: launch.sh stopped before the end of its run." >&2
        exit 1
    fi
}
trap swarm_exit_trap EXIT

# Make a temporary file swarm-NAME.XXXXXX in TMPDIR, removed when this
# run exits, and set the variable VAR to its absolute path (the run
# may change directory before it exits).
swarm_tmp_file() {
    local _dir="${TMPDIR:-/tmp}" _tmp
    case "$_dir" in
        /*) ;;
        *)
            # As for the swarmfile's directory: CDPATH cleared, links
            # resolved, trailing newlines kept.
            _dir=$(CDPATH='' cd -P -- "$_dir" && pwd -P && echo x) \
                || return 1
            _dir="${_dir%x}"
            _dir="${_dir%$'\n'}" ;;
    esac
    _tmp=$(mktemp "${_dir%/}/swarm-$2.XXXXXX") || return 1
    SWARM_TMP_FILES+=("$_tmp")
    printf -v "$1" '%s' "$_tmp"
}

# Copy the state file to a temporary file and set the variable VAR to
# its path, for stop and wait, which hold no lock: every check they make
# then reads one version of it, whatever another terminal does
# meanwhile (the state file is replaced by a rename, so a copy holds one
# whole version).  With no state file, VAR names a file that does not
# exist.
state_snapshot() {
    local _snap
    swarm_tmp_file _snap state || return 1
    if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
        cp "$STATE_FILE" "$_snap" || return 1
    else
        rm -f "$_snap" || return 1
    fi
    printf -v "$1" '%s' "$_snap"
}

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: No swarmfile found.  Create swarm.json in your repo root or set SWARM_CONFIG." >&2
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Swarmfile ${CONFIG_FILE} not found." >&2
    exit 1
fi
# Keep an absolute path: start changes into the repository root before
# it reads the swarmfile again, and the state file records the path for
# a dashboard started elsewhere.  Parameter expansion and the "x"
# sentinel keep trailing newlines in directory names, which dirname and
# command substitution would drop.
case "$CONFIG_FILE" in
    */*) _config_dir="${CONFIG_FILE%/*}" ;;
    *) _config_dir="." ;;
esac
_config_dir=$(CDPATH='' cd -P -- "${_config_dir:-/}" && pwd -P && echo x) \
    || { echo "ERROR: cannot resolve ${CONFIG_FILE}." >&2; exit 1; }
_config_dir="${_config_dir%x}"
_config_dir="${_config_dir%$'\n'}"
CONFIG_FILE="${_config_dir%/}/${CONFIG_FILE##*/}"

SWARM_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
SWARM_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@swarm.local"' "$CONFIG_FILE")
GIT_SIGNING_KEY=$(jq -r '.git_user.signing_key // empty' "$CONFIG_FILE")
GIT_SIGNING_KEY="$(expand_env_ref "$GIT_SIGNING_KEY")"

# Resolve signing key path and build volume mount.
SIGNING_KEY_ARGS=()
if [ -n "$GIT_SIGNING_KEY" ]; then
    # shellcheck disable=SC2031  # lib/target.sh sets HOME in subshells only
    GIT_SIGNING_KEY="${GIT_SIGNING_KEY/#\~/$HOME}"
    if [ ! -f "$GIT_SIGNING_KEY" ]; then
        echo "ERROR: signing key not found: $GIT_SIGNING_KEY" >&2
        exit 1
    fi
    SIGNING_KEY_ARGS=(-v "${GIT_SIGNING_KEY}:/etc/swarm/signing_key:ro")
fi
NUM_AGENTS=$(jq '[.agents[]? | (.count // 0)] | add // 0' "$CONFIG_FILE")
SWARM_DRIVER_DEFAULT=$(jq -r '.driver // "claude-code"' "$CONFIG_FILE")
MAX_RETRY_WAIT=$(jq -r '.max_retry_wait // 0' "$CONFIG_FILE")

# docker_args, read and checked by the commands that launch containers
# (docker_args_load), before they prepare anything.
DOCKER_EXTRA_ARGS=()
# What every container gets of the engagement's target (target_args_load).
TARGET_ARGS=()
docker_args_load() {
    swarm_docker_args_read "$CONFIG_FILE" || exit 1
    swarm_docker_args_check || exit 1
    DOCKER_EXTRA_ARGS=("${SWARM_DOCKER_ARGS[@]+"${SWARM_DOCKER_ARGS[@]}"}")
}

parse_start_args() {
    OPEN_DASHBOARD=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dashboard)
                OPEN_DASHBOARD=true
                shift ;;
            *)
                echo "Unknown start option: $1" >&2
                echo "Try '$0 --help' for more." >&2
                exit 1 ;;
        esac
    done
}

print_interactive_profiles() {
    jq -r '.driver as $dd | .agents | to_entries[] |
        "\(.key + 1)|\(.value.name // "")|\(.value.model // "")|" +
        "\(.value.driver // $dd // "claude-code")"' \
        "$CONFIG_FILE" | while IFS='|' read -r idx name model driver; do
        if [ -n "$name" ]; then
            printf '  - %s (index %s, %s, %s)\n' \
                "$name" "$idx" "${model:-model unset}" "$driver"
        else
            printf '  - --agent-index %s (%s, %s)\n' \
                "$idx" "${model:-model unset}" "$driver"
        fi
    done >&2
}

# Write the agents[] profile an interactive session uses to OUTPUT_FILE:
# the one named SELECTOR, the one at SELECTOR_INDEX (from 1), or with
# neither, the only named one or the only one.  INTERACTIVE_PROFILE_INDEX
# gets the index (from 1) of the profile written, for its container's
# label.
select_interactive_profile() {
    local selector="$1" selector_index="$2" output_file="$3"
    local selected count idx

    if [ -n "$selector_index" ]; then
        if ! [[ "$selector_index" =~ ^[0-9]+$ ]] \
                || [ "$((10#$selector_index))" -lt 1 ]; then
            echo "ERROR: --agent-index must be a positive integer." >&2
            exit 1
        fi
        # Decimal, whatever leading zeros it has.
        idx=$((10#$selector_index))
        selected=$(jq -c --argjson idx "$((idx - 1))" \
            '.agents[$idx] // empty' "$CONFIG_FILE")
        if [ -z "$selected" ] || [ "$selected" = "null" ]; then
            echo "ERROR: no agent at index ${selector_index}." >&2
            print_interactive_profiles
            exit 1
        fi
        printf '%s\n' "$selected" > "$output_file"
        INTERACTIVE_PROFILE_INDEX="$idx"
        return
    fi

    if [ -z "$selector" ]; then
        local named_count agent_count
        named_count=$(jq '[.agents[] | select(.name? and (.name | length > 0))] | length' \
            "$CONFIG_FILE")
        agent_count=$(jq '.agents | length' "$CONFIG_FILE")
        if [ "$named_count" -eq 1 ]; then
            selector=$(jq -r '.agents[] | select(.name? and (.name | length > 0)) | .name' \
                "$CONFIG_FILE")
        elif [ "$agent_count" -eq 1 ]; then
            selector_index=1
            select_interactive_profile "$selector" "$selector_index" "$output_file"
            return
        else
            echo "ERROR: choose an interactive profile." >&2
            echo "Use '$0 interactive NAME' or '$0 interactive --agent-index N'." >&2
            echo "Available profiles:" >&2
            print_interactive_profiles
            exit 1
        fi
    fi

    count=$(jq --arg name "$selector" \
        '[.agents[] | select((.name // "") == $name)] | length' \
        "$CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        echo "ERROR: no agent profile named '${selector}'." >&2
        echo "Available profiles:" >&2
        print_interactive_profiles
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "ERROR: agent profile name '${selector}' is not unique." >&2
        exit 1
    fi

    jq -c --arg name "$selector" \
        '.agents[] | select((.name // "") == $name)' \
        "$CONFIG_FILE" > "$output_file"
    idx=$(jq --arg name "$selector" '[.agents | to_entries[]
        | select((.value.name // "") == $name) | .key + 1]
        | if length == 1 then .[0] else error("not one") end' \
        "$CONFIG_FILE") || exit 1
    INTERACTIVE_PROFILE_INDEX="$idx"
}

cmd_interactive() {
    local mode="$1"; shift
    local selector="" selector_index=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --agent)
                selector="${2:-}"
                if [ -z "$selector" ]; then
                    echo "ERROR: --agent requires a name." >&2
                    exit 1
                fi
                shift 2 ;;
            --agent-index)
                selector_index="${2:-}"
                if [ -z "$selector_index" ]; then
                    echo "ERROR: --agent-index requires a number." >&2
                    exit 1
                fi
                shift 2 ;;
            --shell)
                mode="shell"
                shift ;;
            --chat)
                mode="chat"
                shift ;;
            -h|--help)
                cat <<HELP
Usage: $0 interactive [--agent NAME | --agent-index N] [--shell]
       $0 chat        [--agent NAME | --agent-index N]
       $0 shell       [--agent NAME | --agent-index N]

Start one human-guided container from an agents[] profile.
HELP
                SWARM_EXIT_OK=true
                exit 0 ;;
            *)
                if [ -n "$selector" ]; then
                    echo "ERROR: multiple interactive profiles supplied." >&2
                    exit 1
                fi
                selector="$1"
                shift ;;
        esac
    done

    local profile_file
    swarm_tmp_file profile_file profile || exit 1
    select_interactive_profile "$selector" "$selector_index" "$profile_file"

    local profile_name profile_label safe_profile short_id branch name
    local agent_model agent_base_url agent_api_key agent_effort agent_auth
    local agent_context agent_prompt agent_auth_token agent_tag agent_driver

    profile_name=$(jq -r '.name // empty' "$profile_file")
    profile_label="$profile_name"
    if [ -z "$profile_label" ]; then
        profile_label="agent-${selector_index:-1}"
    fi
    safe_profile="$(swarm_project_id "$profile_label")"
    safe_profile="${safe_profile:0:32}"
    # Random enough that two sessions never meet (a record is never
    # written over another; see swarm_pending_write).
    short_id="$(date -u +%Y%m%d%H%M%S)-$(swarm_random_hex 4)" || exit 1
    branch="swarm/${SWARM_RUN_HASH}/interactive-${safe_profile}-${short_id}"
    name="${IMAGE_NAME}-interactive-${safe_profile}-${short_id}"

    if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        echo "ERROR: invalid interactive branch name: ${branch}" >&2
        exit 1
    fi

    agent_model=$(jq -r '.model // empty' "$profile_file")
    agent_base_url=$(jq -r '.base_url // empty' "$profile_file")
    agent_api_key=$(jq -r '.api_key // empty' "$profile_file")
    agent_api_key="$(expand_env_ref "$agent_api_key")"
    agent_effort=$(jq -r '.effort // empty' "$profile_file")
    agent_auth=$(jq -r '.auth // empty' "$profile_file")
    agent_context=$(jq -r '.context // empty' "$profile_file")
    agent_context="${agent_context:-full}"
    case "$agent_context" in
        full|slim|none) ;;
        *)
            echo "ERROR: unknown context mode: ${agent_context}" \
                 "(full, slim or none)." >&2
            exit 1 ;;
    esac
    agent_prompt=$(jq -r '.prompt // empty' "$profile_file")
    agent_auth_token=$(jq -r '.auth_token // empty' "$profile_file")
    agent_auth_token="$(expand_env_ref "$agent_auth_token")"
    agent_tag=$(jq -r '.tag // empty' "$profile_file")
    if [ -z "$agent_tag" ]; then
        agent_tag=$(jq -r '.tag // empty' "$CONFIG_FILE")
    fi
    agent_tag="$(expand_env_ref "$agent_tag")"
    agent_driver=$(jq -r --arg dd "$SWARM_DRIVER_DEFAULT" \
        '.driver // $dd // "claude-code"' "$profile_file")
    agent_driver="${agent_driver:-$SWARM_DRIVER_DEFAULT}"

    if [ ! -f "$SWARM_DIR/lib/drivers/${agent_driver}.sh" ]; then
        echo "ERROR: unknown driver: ${agent_driver}" >&2
        echo "Available drivers: $(available_drivers)" >&2
        exit 1
    fi

    # shellcheck source=lib/drivers/claude-code.sh
    source "$SWARM_DIR/lib/drivers/${agent_driver}.sh"
    agent_model="${agent_model:-$(agent_default_model)}"

    local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"
    if [ -n "$effective_prompt" ] && [ ! -f "$REPO_ROOT/$effective_prompt" ]; then
        echo "ERROR: prompt '${effective_prompt}' not found." >&2
        exit 1
    fi

    swarm_target_vars_check || exit 1
    docker_args_load
    prepare_runtime
    ensure_bare_repo_for_interactive
    target_args_load

    MIRROR_ARGS=()
    mirror_volume_args
    rm -f "$profile_file"

    local EXTRA_ENV=()
    while IFS= read -r _ae; do
        [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
    done < <(agent_docker_auth "$agent_api_key" "$agent_auth_token" \
        "$agent_auth" "$agent_base_url")

    if [ -n "$agent_effort" ]; then
        while IFS= read -r _de; do
            [ -n "$_de" ] && EXTRA_ENV+=("$_de")
        done < <(agent_docker_env "$agent_effort")
    fi

    # Forward Pi settings overrides from the host environment.
    for _pv in PI_HTTP_IDLE_TIMEOUT_MS PI_MAX_RETRIES \
            PI_COMPACTION_RESERVE_TOKENS; do
        [ -n "${!_pv:-}" ] && EXTRA_ENV+=(-e "${_pv}=${!_pv}")
    done

    # Its workspace volume, made under the lock before the session is
    # recorded.  The role follows the mode it opens in: shell, or the
    # driver's UI (interactive and chat).
    local role=interactive
    [ "$mode" != shell ] || role=shell
    workspace_args "$name" interactive "$agent_context" "$role" \
        "$INTERACTIVE_PROFILE_INDEX" ""

    # The session can last hours and only pushes through git, so it runs
    # without the lock.  It is recorded under the lock with this
    # process's pid; then the lock goes and exec keeps that pid for
    # docker run, which makes the container and its mounts.  Until this
    # process ends, or its container after a detach, start and
    # post-process leave the bare repo and the mirrors alone
    # (require_clean_runtime).  One Docker context serves
    # the daemon id and docker run, even if another terminal switches
    # it meanwhile.
    local daemon
    if ! swarm_docker_pin || ! daemon=$(swarm_docker_daemon_id); then
        echo "ERROR: cannot read the Docker daemon id." >&2
        exit 1
    fi
    if ! swarm_pending_write "$RUNTIME_DIR" "$name" "$$" "$daemon"; then
        echo "ERROR: cannot record the interactive session." >&2
        exit 1
    fi
    swarm_unlock
    echo "--- Starting interactive ${profile_label} (${agent_model}) ---"
    echo "Branch: ${branch}"
    # docker_args come first: everything the engine sets comes after
    # them, so the last value of an option is the engine's (-it, the
    # name and the session label the record must find, the entrypoint).
    exec docker run \
        "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
        -it \
        --mount "type=bind,src=${BARE_REPO},dst=/upstream" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
        "${TARGET_ARGS[@]}" \
        "${WORKSPACE_ARGS[@]}" \
        --name "$name" \
        --label "${SWARM_SESSION_LABEL}=${name}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        --label "$CHECKOUT_LABEL" \
        --label "$PROJECT_LABEL" \
        -e "SWARM_MODEL=${agent_model}" \
        -e "SWARM_EFFORT=${agent_effort}" \
        -e "CLAUDE_MODEL=${agent_model}" \
        -e "SWARM_PROMPT=${effective_prompt}" \
        -e "SWARM_SETUP=${SWARM_SETUP}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=interactive-${safe_profile}" \
        -e "SWARM_TAG=${agent_tag}" \
        -e "SWARM_CONTEXT=${agent_context}" \
        -e "SWARM_DRIVER=${agent_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${effective_prompt}" \
        -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
        -e "SWARM_INTERACTIVE_BRANCH=${branch}" \
        -e "SWARM_INTERACTIVE_PROFILE=${profile_label}" \
        -e "SWARM_INTERACTIVE_MODE=${mode}" \
        --entrypoint /interactive.sh \
        "$IMAGE_NAME"
}

cmd_start() {
    # A token names an engagement to join, and start makes a new one:
    # with the token of one whose bare repo was never made, it would
    # replace that engagement.  Refused before anything is prepared.
    if [ -n "${SWARM_ENGAGEMENT_TOKEN+x}" ]; then
        echo "ERROR: SWARM_ENGAGEMENT_TOKEN names an engagement to" \
             "join; start makes a new one.  Unset it to start one." >&2
        exit 1
    fi

    # Top-level prompt is optional when every agent group defines its own.
    local all_groups_have_prompt
    all_groups_have_prompt=$(jq \
        '[.agents[] | has("prompt") and (.prompt | length > 0)] | all' \
        "$CONFIG_FILE")

    if [ -z "$SWARM_PROMPT" ] && [ "$all_groups_have_prompt" != "true" ]; then
        echo "ERROR: 'prompt' is missing in ${CONFIG_FILE} (required when not every agent group specifies its own)." >&2
        exit 1
    fi

    if [ -n "$SWARM_PROMPT" ] && [ ! -f "$REPO_ROOT/$SWARM_PROMPT" ]; then
        echo "ERROR: prompt '${SWARM_PROMPT}' not found." >&2
        exit 1
    fi

    # Validate per-group prompt overrides.
    local group_prompts
    group_prompts=$(jq -r '[.agents[].prompt // empty] | unique[]' \
        "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r gp; do
        [ -z "$gp" ] && continue
        if [ ! -f "$REPO_ROOT/$gp" ]; then
            echo "ERROR: per-group prompt ${gp} not found." >&2
            exit 1
        fi
    done <<< "$group_prompts"

    # Build per-agent config (profile|model|base_url|api_key|effort|auth|context|prompt|auth_token|tag|driver per line),
    # profile being the agents[] entry (from 1) the agent comes from.
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    swarm_tmp_file AGENTS_CFG agents || exit 1
    jq -r '.tag as $dt | .driver as $dd |
        .agents | to_entries[] | (.key + 1 | tostring) as $p | .value |
        range(.count // 0) as $i |
        [$p, .model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")' \
        "$CONFIG_FILE" > "$AGENTS_CFG"

    # Preflight: validate all referenced drivers and context modes
    # before anything is created, so that a mistake in the swarmfile
    # leaves the runtime directory clean.
    local _bad_drivers="" _checked_drivers=" " _ctx _bad_contexts=""
    while IFS='|' read -r _ _ _ _ _ _ _ctx _ _ _ _drv; do
        case "${_ctx:-full}" in
            full|slim|none) ;;
            *) _bad_contexts+="  - ${_ctx}\n" ;;
        esac
        _drv="${_drv:-${SWARM_DRIVER_DEFAULT}}"
        [[ "$_checked_drivers" == *" $_drv "* ]] && continue
        _checked_drivers+="$_drv "
        if [ ! -f "$SWARM_DIR/lib/drivers/${_drv}.sh" ]; then
            _bad_drivers+="  - ${_drv}\n"
        fi
    done < "$AGENTS_CFG"
    if [ -n "$_bad_drivers" ]; then
        printf "ERROR: unknown driver(s):\n%b" "$_bad_drivers" >&2
        echo "Available drivers: $(available_drivers)" >&2
        exit 1
    fi
    if [ -n "$_bad_contexts" ]; then
        printf "ERROR: unknown context mode(s):\n%b" "$_bad_contexts" >&2
        echo "Context modes: full, slim, none." >&2
        exit 1
    fi

    # A target's inputs, checked before anything is prepared.
    if swarm_target_requested; then
        swarm_target_inputs_check || exit 1
    fi
    docker_args_load
    prepare_runtime

    # A new engagement, only once the last one was cleaned up.  The
    # image is built before it is created, so a failed build leaves the
    # runtime directory clean.
    require_clean_runtime
    mirror_preflight
    build_image
    create_bare_repo "bare repo"

    # Mirror each submodule so containers can init without network.
    mirror_submodules
    target_args_load

    # Mirror volume mounts, shared across all containers.
    MIRROR_ARGS=()
    mirror_volume_args

    AGENT_IDX=0
    while IFS='|' read -r agent_profile agent_model agent_base_url agent_api_key agent_effort agent_auth agent_context agent_prompt agent_auth_token agent_tag agent_driver; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        agent_api_key="$(expand_env_ref "$agent_api_key")"
        agent_auth_token="$(expand_env_ref "$agent_auth_token")"
        agent_tag="$(expand_env_ref "$agent_tag")"
        agent_context="${agent_context:-full}"
        workspace_args "$NAME" agent "$agent_context" agent "$agent_profile" \
            "$AGENT_IDX"
        agent_driver="${agent_driver:-${SWARM_DRIVER_DEFAULT}}"

        # Source the driver to access agent_docker_env.
        # shellcheck source=lib/drivers/claude-code.sh
        source "$SWARM_DIR/lib/drivers/${agent_driver}.sh"
        local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"

        local ctx_label="" prompt_label="" driver_label=""
        [ "$agent_context" != "full" ] && ctx_label=" context=${agent_context}"
        [ -n "$agent_prompt" ] && prompt_label=" prompt=${agent_prompt}"
        [ "$agent_driver" != "claude-code" ] && driver_label=" driver=${agent_driver}"
        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}}${ctx_label}${prompt_label}${driver_label}) ---"
        EXTRA_ENV=()

        # Delegate auth credential resolution to the driver.
        while IFS= read -r _ae; do
            [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
        done < <(agent_docker_auth "$agent_api_key" "$agent_auth_token" "$agent_auth" "$agent_base_url")

        local eff="${agent_effort:-}"
        if [ -n "$eff" ]; then
            while IFS= read -r _de; do
                [ -n "$_de" ] && EXTRA_ENV+=("$_de")
            done < <(agent_docker_env "$eff")
        fi

        # Forward Pi settings overrides from the host environment.
        for _pv in PI_HTTP_IDLE_TIMEOUT_MS PI_MAX_RETRIES \
                PI_COMPACTION_RESERVE_TOKENS; do
            [ -n "${!_pv:-}" ] && EXTRA_ENV+=(-e "${_pv}=${!_pv}")
        done

        local price_input="" price_output="" price_cached=""
        local _price
        _price=$(jq -r --arg m "$agent_model" \
            '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
            "$CONFIG_FILE" 2>/dev/null || true)
        if [ -n "$_price" ]; then
            read -r price_input price_output price_cached <<< "$_price"
        fi

        # docker_args come first: -d, the workspace, its labels, no
        # restart policy, no auto-remove and the name come after them,
        # so the last value of each is the engine's.
        docker run \
            "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
            -d \
            --mount "type=bind,src=${BARE_REPO},dst=/upstream" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
            "${TARGET_ARGS[@]}" \
            "${WORKSPACE_ARGS[@]}" \
            --name "$NAME" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            --label "$CHECKOUT_LABEL" \
            --label "$PROJECT_LABEL" \
            -e "SWARM_MODEL=${agent_model}" \
            -e "SWARM_EFFORT=${eff}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "SWARM_PROMPT=${effective_prompt}" \
            -e "SWARM_SETUP=${SWARM_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            -e "SWARM_TAG=${agent_tag}" \
            -e "SWARM_CONTEXT=${agent_context}" \
            -e "SWARM_DRIVER=${agent_driver}" \
            -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
            -e "SWARM_CFG_PROMPT=${effective_prompt}" \
            -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
            -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
            -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
            -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
            ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
            ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
            ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f "$AGENTS_CFG"

    write_state_file

    echo ""
    echo "--- ${NUM_AGENTS} agents launched ---"
    echo ""
    echo "Monitor:"
    echo "  $0 status"
    echo "  $0 logs 1"
    echo ""
    echo "Stop:"
    echo "  $0 stop"
    echo ""
    echo "Runtime:   ${RUNTIME_DIR}"
    echo "Bare repo: ${BARE_REPO}"
}

cmd_stop() {
    # Default to a 60s grace so the harness's SIGTERM trap has
    # time to ship any in-flight local commits via
    # `_session_end_push` before docker forces SIGKILL.  The 10s
    # default that docker ships with cuts the emergency push
    # mid-rebase on a busy bare repo.  Override via env:
    #   SWARM_STOP_TIMEOUT=120 ./bin/launch.sh stop
    local stop_timeout="${SWARM_STOP_TIMEOUT:-60}" numbered=false
    local snap token list id info name rest state failed=0 pass=0 found
    local labels phase locked=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --numbered) numbered=true; shift ;;
            *) echo "ERROR: unknown stop option: $1" >&2; exit 1 ;;
        esac
    done
    # Whole seconds for docker stop -t and for the wait for the lock.
    case "$stop_timeout" in
        ''|*[!0123456789]*|???????*)
            echo "ERROR: SWARM_STOP_TIMEOUT must be a whole number of" \
                 "seconds below 1000000." >&2
            exit 1 ;;
    esac
    stop_timeout=$((10#$stop_timeout))
    # stop acts on the engagement the state file records now, through
    # its token: every check reads the same copy of the state, and a
    # container of a later engagement, under a reused name or engagement
    # id, is never stopped.
    while :; do
        state_snapshot snap || exit 1
        swarm_cleanup_pending_check "$snap" || exit 1
        swarm_legacy_refuse "$RUNTIME_DIR" "$snap" || exit 1
        swarm_engagement_join "$snap" || exit 1
        # A token names an engagement: one that is gone, or replaced,
        # refuses (also when none is recorded any more).
        swarm_engagement_token_check "$snap" || exit 1
        token=$(swarm_engagement_token "$snap") || exit 1
        [ -z "$token" ] || break
        if $locked; then
            swarm_unlock
            echo "No engagement recorded; nothing to stop."
            return 0
        fi
        # Nothing at all at the runtime path: no engagement was started
        # here, and a start makes the directory before it takes the lock,
        # so none is building its image either.  A path stop cannot look
        # into goes on to the lock.
        if swarm_path_absent "$RUNTIME_DIR"; then
            echo "No engagement recorded; nothing to stop."
            return 0
        fi
        # A start holds the lock while it builds the image, before it
        # records its token: no token says nothing until it is done.
        if ! swarm_lock "$RUNTIME_DIR" "$stop_timeout"; then
            echo "ERROR: without the engagement lock, stop cannot tell" \
                 "that no engagement is about to start; run stop" \
                 "again." >&2
            exit 1
        fi
        locked=true
    done
    swarm_engagement_daemon_check "$snap" || exit 1
    echo "--- Stopping agents (grace ${stop_timeout}s) ---"
    # What a container's labels must read before it is stopped.
    labels="{{.Name}}|{{index .Config.Labels \"${SWARM_PROJECT_LABEL}\"}}"
    labels+="|{{index .Config.Labels \"${SWARM_CHECKOUT_LABEL}\"}}"
    labels+="|{{index .Config.Labels \"${SWARM_TOKEN_LABEL}\"}}"
    # Two phases.  The first runs without the engagement lock, which a
    # post-process holds for its whole run (stop must be able to stop
    # it): the listing is taken again after each pass, until one finds
    # nothing more to stop, up to three passes that stop.  A start that
    # recorded the engagement can still be launching its agents then,
    # and holds the lock until it is done, so an empty listing does not
    # settle it.  The second phase waits for the lock, up to the grace,
    # and under it, where neither a start nor a post-process can launch
    # anything, stops what came meanwhile: up to three passes that stop,
    # then one that only checks.  An interactive session holds the lock
    # only while it prepares: a container it is starting is not waited
    # for.  Nor is what a wait already running does once it sees the
    # agents stopped: it goes on to its post-process or harvest, as when
    # they finish.
    for phase in 1 2; do
        if [ "$phase" = 2 ] \
                && ! swarm_lock "$RUNTIME_DIR" "$stop_timeout"; then
            echo "ERROR: without the engagement lock, stop cannot tell" \
                 "that nothing of this engagement runs or is about to" \
                 "start; run stop again." >&2
            exit 1
        fi
        pass=0
        while :; do
            pass=$((pass + 1))
            if ! list=$(docker ps -q \
                    --filter "label=${SWARM_TOKEN_LABEL}=${token}" \
                    --filter "label=${SWARM_PROJECT_LABEL}=${PROJECT}" \
                    2>/dev/null); then
                echo "ERROR: cannot list Docker containers." >&2
                exit 1
            fi
            found=false
            for id in $list; do
                # Its labels again, right before it is stopped by ID.  One gone
                # since the listing needs nothing; one Docker cannot describe
                # fails the stop.
                if ! info=$(docker container inspect -f "$labels" "$id" \
                        2>/dev/null); then
                    if ! swarm_container_gone "$id"; then
                        echo "ERROR: cannot inspect container ${id}." >&2
                        failed=1
                    fi
                    continue
                fi
                name="${info%%|*}"
                name="${name#/}"
                if [ "$info" \
                        != "/${name}|${PROJECT}|${CHECKOUT_PATH}|${token}" ]
                then
                    echo "  ${name} skipped: not this engagement's container"
                    continue
                fi
                if $numbered; then
                    rest="${name#"${IMAGE_NAME}"-}"
                    if [ "$rest" = "$name" ] || [ -z "$rest" ] \
                            || [ -n "${rest//[0-9]/}" ]; then
                        continue
                    fi
                fi
                if [ "$pass" -gt 3 ]; then
                    # Without the lock, the second phase settles it.
                    [ "$phase" = 2 ] || break 2
                    echo "ERROR: containers of this engagement keep" \
                         "starting, even under the engagement lock." >&2
                    exit 1
                fi
                found=true
                if docker stop -t "$stop_timeout" "$id" >/dev/null 2>&1; then
                    echo "  stopped ${name}"
                    continue
                fi
                # docker stop fails too for one that stopped or went meanwhile;
                # one that still runs, or that Docker cannot tell, fails the
                # stop, so that callers (the dashboard's p) do not go on.
                if ! state=$(docker container inspect -f '{{.State.Running}}' \
                        "$id" 2>/dev/null); then
                    state=unknown
                    swarm_container_gone "$id" && state=gone
                fi
                case "$state" in
                    false|gone) echo "  ${name} not running" ;;
                    *)
                        echo "ERROR: cannot stop ${name}." >&2
                        failed=1 ;;
                esac
            done
            if ! $found || [ "$failed" -ne 0 ]; then
                break
            fi
        done
        [ "$failed" -eq 0 ] || exit 1
    done
    swarm_unlock
    # The state file stays: it records which checkout owns the runtime
    # directory, and later phases read it.
}

cmd_logs() {
    local n="${1:-1}" name id
    name="${IMAGE_NAME}-${n}"
    id=$(swarm_own_container_id "$name" "$CHECKOUT_PATH" "$PROJECT") \
        || exit 1
    if [ -z "$id" ]; then
        echo "ERROR: no container ${name}." >&2
        exit 1
    fi
    docker logs -f "$id"
}

cmd_status() {
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        printf "%-30s %s\n" "${NAME}:" "$(own_container_state "$NAME")"
    done

    while read -r NAME; do
        [ -n "$NAME" ] || continue
        local env_dump branch profile state id
        id=$(swarm_own_container_id "$NAME" "$CHECKOUT_PATH" "$PROJECT" \
            2>/dev/null) || continue
        [ -n "$id" ] || continue
        env_dump=$(docker inspect -f \
            '{{range .Config.Env}}{{println .}}{{end}}' \
            "$id" 2>/dev/null || true)
        branch=$(printf '%s' "$env_dump" \
            | grep '^SWARM_INTERACTIVE_BRANCH=' \
            | head -1 | cut -d= -f2- || true)
        profile=$(printf '%s' "$env_dump" \
            | grep '^SWARM_INTERACTIVE_PROFILE=' \
            | head -1 | cut -d= -f2- || true)
        state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null \
            || echo "not found")
        printf "%-30s " "${NAME}:"
        printf "%s" "$state"
        [ -n "$profile" ] && printf "  profile=%s" "$profile"
        [ -n "$branch" ] && printf "  branch=%s" "$branch"
        printf "\n"
    done < <(swarm_interactive_container_names "$PROJECT" 2>/dev/null \
        | sort || true)
}

# Print "<running> <exited>" for the numbered agents in LISTING, docker
# ps lines "<name> <state>".  No read loop over a here-string: Bash 3.2
# makes a temporary file for it, which can fail to be made, and a read
# that fails ends a loop like the end of the list; either would count
# running agents as done.  Names and states hold no glob characters.
wait_count() {
    local line name state rest running=0 exited=0 IFS=$'\n'
    for line in $1; do
        name="${line%% *}"
        state="${line##* }"
        # The numbered agents only.
        rest="${name#"${IMAGE_NAME}"-}"
        if [ "$rest" = "$name" ] || [ -z "$rest" ] \
                || [ -n "${rest//[0-9]/}" ]; then
            continue
        fi
        case "$state" in
            running|restarting|created|paused) running=$((running + 1)) ;;
            *) exited=$((exited + 1)) ;;
        esac
    done
    printf '%s %s\n' "$running" "$exited"
}

# Print "<running> <exited>" for the numbered agents of the engagement
# with token TOKEN, as Docker lists them now.  A created agent whose
# start failed counts as exited: it never runs.
wait_agents() {
    local states name state listing=""
    if ! states=$(docker ps -a \
            --filter "label=${SWARM_TOKEN_LABEL}=${1}" \
            --filter "label=${SWARM_PROJECT_LABEL}=${PROJECT}" \
            --format '{{.Names}} {{.State}}' 2>/dev/null); then
        echo "" >&2
        echo "ERROR: cannot list Docker containers." >&2
        return 1
    fi
    # Pairs of words: names and states hold no blanks or glob
    # characters.
    # shellcheck disable=SC2086
    set -- $states
    while [ $# -ge 2 ]; do
        name="$1"
        state="$2"
        shift 2
        if [ "$state" = created ] && swarm_start_failed "$name"; then
            state=failed
        fi
        listing+="${name} ${state}"$'\n'
    done
    wait_count "$listing"
}

cmd_wait() {
    local snap token own_lock=true
    # wait holds no lock while it polls: every check reads the same copy
    # of the state, and the engagement waited for is the one its token
    # names there.
    state_snapshot snap || exit 1
    swarm_cleanup_pending_check "$snap" || exit 1
    swarm_legacy_refuse "$RUNTIME_DIR" "$snap" || exit 1
    swarm_engagement_join "$snap" || exit 1
    swarm_engagement_token_check "$snap" || exit 1
    token=$(swarm_engagement_token "$snap") || exit 1
    if [ -z "$token" ]; then
        echo "ERROR: ${STATE_FILE} records no engagement to wait for." >&2
        exit 1
    fi
    swarm_engagement_daemon_check "$snap" || exit 1
    # The target too, snapshot included, before the hours of polling.
    swarm_target_join_check "$snap" "$RUNTIME_DIR" || exit 1
    # A lock the caller holds stays held throughout.
    [ -z "${SWARM_LOCK_FD:-}" ] || own_lock=false
    echo "--- Waiting for all agents to finish ---"

    local counts running exited
    while true; do
        sleep "${SWARM_WAIT_POLL:-10}"
        counts=$(wait_agents "$token") || exit 1
        running="${counts% *}"
        exited="${counts#* }"
        printf "\r  %d running, %d exited " "$running" "$exited"
        [ "$running" -eq 0 ] || continue

        # What comes next acts on the engagement waited for, and on
        # nothing else: under the lock, the state file must still record
        # its token (a cleanup and a new start in another terminal
        # meanwhile would have changed it), and none of its agents may
        # run.  A start records the engagement before it launches the
        # agents, and holds the lock until they run: agents it launched
        # meanwhile are waited for too.  A stop takes the lock for a
        # moment once it has stopped the agents, to check that no more
        # are starting: wait up to a minute for it rather than give up.
        # Agents a stop ended count as done, as those that finish.
        swarm_lock "$RUNTIME_DIR" 60 || exit 1
        swarm_cleanup_pending_check "$STATE_FILE" || exit 1
        if [ "$(swarm_engagement_token "$STATE_FILE")" != "$token" ]; then
            echo "" >&2
            echo "ERROR: the engagement changed while waiting (cleaned" \
                 "up, or started again); nothing more is done." >&2
            exit 1
        fi
        counts=$(wait_agents "$token") || exit 1
        if [ "${counts% *}" -eq 0 ]; then
            echo ""
            echo "All agents finished."
            break
        fi
        if $own_lock; then
            swarm_unlock
        fi
    done
    # What comes next needs the engagement complete (under the lock).
    local engaged
    engaged=$(swarm_engagement_recorded "$STATE_FILE") || exit 1
    swarm_engagement_complete "$engaged" "$BARE_REPO" || exit 1
    # The token shows it is the same engagement: its target record and
    # the input variables are checked again here, the snapshot where it
    # is mounted (post-process's join, below); harvest never mounts it.
    swarm_target_record_check "$STATE_FILE" || exit 1
    SWARM_ENGAGEMENT_TOKEN="$token"
    export SWARM_ENGAGEMENT_TOKEN

    local pp_prompt
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    if [ -n "$pp_prompt" ]; then
        echo ""
        cmd_post_process
        return
    fi

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/bin/harvest.sh"
}

cmd_post_process() {
    local pp_prompt pp_model pp_base_url pp_api_key pp_effort pp_auth pp_auth_token pp_tag pp_driver pp_max_idle pp_setup
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_max_idle=$(jq -r '.post_process.max_idle // .max_idle // 3' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_base_url=$(jq -r '.post_process.base_url // empty' "$CONFIG_FILE")
    pp_api_key=$(jq -r '.post_process.api_key // empty' "$CONFIG_FILE")
    pp_api_key="$(expand_env_ref "$pp_api_key")"
    pp_auth_token=$(jq -r '.post_process.auth_token // empty' "$CONFIG_FILE")
    pp_auth_token="$(expand_env_ref "$pp_auth_token")"
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")
    pp_auth=$(jq -r '.post_process.auth // empty' "$CONFIG_FILE")
    pp_tag=$(jq -r '.post_process.tag // .tag // empty' "$CONFIG_FILE")
    pp_tag="$(expand_env_ref "$pp_tag")"
    pp_driver=$(jq -r '.post_process.driver // .driver // "claude-code"' "$CONFIG_FILE")

    # Resolve the post-process setup script.  An explicit
    # post_process.setup wins (a path runs it, false/empty skips it so a
    # heavy top-level setup is not redone); omitting the key inherits
    # the top-level setup.
    if jq -e '(.post_process // {}) | has("setup")' "$CONFIG_FILE" \
            >/dev/null 2>&1; then
        pp_setup=$(jq -r '.post_process.setup // ""' "$CONFIG_FILE")
        [ "$pp_setup" = "false" ] && pp_setup=""
    else
        pp_setup="${SWARM_SETUP:-}"
    fi

    if [ -z "$pp_prompt" ]; then
        echo "ERROR: post_process.prompt is not set in ${CONFIG_FILE}." >&2
        exit 1
    fi
    if [ ! -f "$SWARM_DIR/lib/drivers/${pp_driver}.sh" ]; then
        echo "ERROR: unknown driver: ${pp_driver}" >&2
        echo "Available drivers: $(available_drivers)" >&2
        exit 1
    fi

    swarm_target_vars_check || exit 1
    docker_args_load
    prepare_runtime
    local NAME="${IMAGE_NAME}-post" pp_state pp_engaged
    # The state decides: a recorded engagement is joined, never made
    # again, and only a complete one is joined.
    pp_engaged=$(swarm_engagement_recorded "$STATE_FILE") || exit 1
    if [ -z "$pp_engaged" ]; then
        # A token names an engagement to join, never a new one.
        if [ -n "${SWARM_ENGAGEMENT_TOKEN:-}" ]; then
            echo "ERROR: the engagement post-process was started for" \
                 "is not recorded any more." >&2
            exit 1
        fi
        # The image is built before the engagement is created, so a
        # failed build leaves the runtime directory clean.
        if swarm_target_requested; then
            swarm_target_inputs_check || exit 1
        fi
        require_clean_runtime
        mirror_preflight
        build_image
        create_bare_repo "bare repo for post-process"
        mirror_submodules
    else
        swarm_engagement_join "$STATE_FILE" || exit 1
        swarm_engagement_daemon_check "$STATE_FILE" || exit 1
        swarm_engagement_complete "$pp_engaged" "$BARE_REPO" || exit 1
        swarm_target_join_check "$STATE_FILE" "$RUNTIME_DIR" || exit 1
        # The numbered agents must be done: post-process works on what
        # they pushed, and under the lock no start can be launching more
        # of them (the dashboard's p stops them first, without the lock).
        local pp_token pp_counts
        pp_token=$(swarm_engagement_token "$STATE_FILE") || exit 1
        pp_counts=$(wait_agents "$pp_token") || exit 1
        if [ "${pp_counts% *}" -ne 0 ]; then
            echo "ERROR: numbered agents of this engagement still run;" \
                 "stop them (./bin/launch.sh stop --numbered) or wait for" \
                 "them (./bin/launch.sh wait) first." >&2
            exit 1
        fi
        # An earlier post-process container is never replaced: its
        # files stay until retire takes it (they are in its volume).
        # On a clean runtime there is none of this checkout's.
        pp_state=$(own_container_state "$NAME")
        case "$pp_state" in
            "not found") ;;
            running|restarting|paused|created)
                echo "ERROR: ${NAME} is ${pp_state}; stop it first" \
                     "(./bin/launch.sh stop)." >&2
                exit 1 ;;
            "not ours")
                echo "ERROR: ${NAME} is not this checkout's container." >&2
                exit 1 ;;
            *)
                echo "ERROR: ${NAME} is there (${pp_state}); retire it" \
                     "first: ./bin/launch.sh retire --post-process." >&2
                exit 1 ;;
        esac
        build_image
    fi

    target_args_load
    workspace_args "$NAME" agent full post-process "" ""

    # Build mirror volume args from existing mirrors.
    local MIRROR_ARGS=()
    mirror_volume_args

    # Source the driver to access agent_docker_auth / agent_docker_env.
    # shellcheck source=lib/drivers/claude-code.sh
    source "$SWARM_DIR/lib/drivers/${pp_driver}.sh"

    local EXTRA_ENV=()
    while IFS= read -r _ae; do
        [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
    done < <(agent_docker_auth "$pp_api_key" "$pp_auth_token" "$pp_auth" "$pp_base_url")

    if [ -n "$pp_effort" ]; then
        while IFS= read -r _de; do
            [ -n "$_de" ] && EXTRA_ENV+=("$_de")
        done < <(agent_docker_env "$pp_effort")
    fi

    # Forward Pi settings overrides from the host environment.
    for _pv in PI_HTTP_IDLE_TIMEOUT_MS PI_MAX_RETRIES \
            PI_COMPACTION_RESERVE_TOKENS; do
        [ -n "${!_pv:-}" ] && EXTRA_ENV+=(-e "${_pv}=${!_pv}")
    done

    local price_input="" price_output="" price_cached=""
    local _price
    _price=$(jq -r --arg m "$pp_model" \
        '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
        "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$_price" ]; then
        read -r price_input price_output price_cached <<< "$_price"
    fi

    echo "--- Starting post-processing (${pp_model}) ---"
    local pp_id
    # As for the agents: docker_args first, then -d, the workspace, its
    # labels, the policies and the name.
    pp_id=$(docker run \
        "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
        -d \
        --mount "type=bind,src=${BARE_REPO},dst=/upstream" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
        "${TARGET_ARGS[@]}" \
        "${WORKSPACE_ARGS[@]}" \
        --name "$NAME" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        --label "$CHECKOUT_LABEL" \
        --label "$PROJECT_LABEL" \
        -e "SWARM_MODEL=${pp_model}" \
        -e "SWARM_EFFORT=${pp_effort}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "SWARM_PROMPT=${pp_prompt}" \
        -e "SWARM_SETUP=${pp_setup}" \
        -e "MAX_IDLE=${pp_max_idle}" \
        -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
        -e "SWARM_TAG=${pp_tag}" \
        -e "SWARM_DRIVER=${pp_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${pp_prompt}" \
        -e "SWARM_CFG_SETUP=${pp_setup}" \
        -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
        -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
        -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
        ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
        ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
        ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
        "$IMAGE_NAME")

    echo "Post-processing agent launched: ${NAME}"
    echo "Waiting for completion..."

    while true; do
        sleep 10
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$pp_id" \
            2>/dev/null || echo "not found")
        if [ "$state" = "running" ]; then
            printf "."
            continue
        fi
        echo ""
        echo "Post-processing agent finished (${state})."
        break
    done

    # Capture container exit code BEFORE harvest. Harvest runs unconditionally
    # so a crashed agent's in-flight commits still land locally (best-effort
    # recovery), but we propagate the failure upward so callers (CI workflows,
    # daemons) can refuse to publish partial state.
    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$pp_id" \
        2>/dev/null || echo "1")

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/bin/harvest.sh"

    if [ "$exit_code" -ne 0 ]; then
        echo "WARNING: post-process container exited with code ${exit_code};" \
             "any commits harvested may represent partial state." >&2
        return "$exit_code"
    fi
}

case "${1:-start}" in
    start)
        shift
        parse_start_args "$@"
        cmd_start
        if $OPEN_DASHBOARD; then
            # The dashboard runs until closed; it must not keep the lock.
            swarm_unlock
            exec "$SWARM_DIR/bin/dashboard.sh"
        fi
        ;;
    stop)          shift; cmd_stop "$@" ;;
    logs)          cmd_logs "${2:-1}" ;;
    status)        cmd_status ;;
    wait)          cmd_wait ;;
    post-process)  cmd_post_process ;;
    interactive)
        shift
        cmd_interactive chat "$@"
        ;;
    chat)
        shift
        cmd_interactive chat "$@"
        ;;
    shell)
        shift
        cmd_interactive shell "$@"
        ;;
    *)
        echo "Usage: $0 {start|stop|logs N|status|wait|post-process|interactive}" >&2
        echo "Try '$0 --help' for more information." >&2
        exit 1
        ;;
esac
# The run got to its end (see swarm_exit_trap).
SWARM_EXIT_OK=true
