#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|logs N|status|wait|post-process}

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0 COMMAND [OPTIONS]

Orchestrate coding agents in Docker containers.

Commands:
  start [OPTIONS]      Build image, create bare repo, launch agents.
  stop                 Stop all running agent containers.
  logs N               Tail logs for agent N (default: 1).
  status               Show running/stopped state for each agent.
  wait                 Block until all agents exit, then harvest.
  post-process         Run the post-processing agent from the config.

Start options (override env vars):
  --prompt FILE        Prompt file path.
  --model MODEL        Model name (default: claude-opus-4-6).
  --agents N           Agent count (default: 3; conflicts with config groups).
  --max-idle N         Idle sessions before exit (default: 3).
  --effort LEVEL       Reasoning effort: low, medium, high.
  --setup SCRIPT       Setup script path.
  --no-inject-git-rules  Disable git coordination rules.
  --dashboard          Open the TUI dashboard after launch.

Environment (lowest priority, after CLI args and config file):
  ANTHROPIC_API_KEY         API key (required unless OAuth).
  CLAUDE_CODE_OAUTH_TOKEN   OAuth token for subscription auth.
  SWARM_CONFIG              Path to swarm.json config file.
  SWARM_PROMPT              Prompt file path.
  SWARM_MODEL               Model name.
  SWARM_NUM_AGENTS          Agent count.
  SWARM_MAX_IDLE            Idle sessions before exit.
  SWARM_EFFORT              Reasoning effort.
  SWARM_TITLE               Dashboard title override.
  SWARM_DRIVER              Agent driver (default: claude-code).
HELP
    exit 0
fi

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
SWARM_RUN_HASH="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_CONTEXT="${PROJECT}@${SWARM_RUN_HASH} (${SWARM_RUN_BRANCH})"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
IMAGE_NAME="${PROJECT}-agent"

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

# Docker containers may create files owned by a different UID inside
# bind-mounted host directories.  Plain rm -rf fails without root.
# Use a throwaway Alpine container (Docker is already required) so
# we never need sudo/su -c.
rm_docker_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local parent base
    parent="$(dirname "$dir")"
    base="$(basename "$dir")"
    docker run --rm -v "${parent}:${parent}" alpine \
        rm -rf "${parent}/${base}" 2>/dev/null \
        || rm -rf "$dir" 2>/dev/null || true
}

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file ${CONFIG_FILE} not found." >&2
        exit 1
    fi
    SWARM_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
    SWARM_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
    MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
    INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
    GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
    GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@swarm.local"' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
    SWARM_DRIVER_DEFAULT=$(jq -r '.driver // "claude-code"' "$CONFIG_FILE")
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-3}"
    SWARM_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    SWARM_PROMPT="${SWARM_PROMPT:-}"
    SWARM_SETUP="${SWARM_SETUP:-}"
    MAX_IDLE="${SWARM_MAX_IDLE:-3}"
    INJECT_GIT_RULES="${SWARM_INJECT_GIT_RULES:-true}"
    GIT_USER_NAME="${SWARM_GIT_USER_NAME:-swarm-agent}"
    GIT_USER_EMAIL="${SWARM_GIT_USER_EMAIL:-agent@swarm.local}"
    EFFORT_LEVEL="${SWARM_EFFORT:-}"
    SWARM_DRIVER_DEFAULT="${SWARM_DRIVER:-claude-code}"
fi

# CLI overrides for `start`.  Applied after config/env defaults.
# Extracted as a function for testability.
parse_start_args() {
    OPEN_DASHBOARD=false
    AGENTS_CLI_OVERRIDE=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)
                SWARM_PROMPT="${2:?--prompt requires a value}"
                shift 2 ;;
            --model)
                SWARM_MODEL="${2:?--model requires a value}"
                shift 2 ;;
            --agents)
                NUM_AGENTS="${2:?--agents requires a value}"
                AGENTS_CLI_OVERRIDE=true
                shift 2 ;;
            --max-idle)
                MAX_IDLE="${2:?--max-idle requires a value}"
                shift 2 ;;
            --effort)
                EFFORT_LEVEL="${2:?--effort requires a value}"
                shift 2 ;;
            --setup)
                SWARM_SETUP="${2:?--setup requires a value}"
                shift 2 ;;
            --no-inject-git-rules)
                INJECT_GIT_RULES="false"
                shift ;;
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

cmd_start() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN must be set." >&2
        exit 1
    fi

    if [ -z "$SWARM_PROMPT" ]; then
        if [ -n "$CONFIG_FILE" ]; then
            echo "ERROR: 'prompt' is missing in ${CONFIG_FILE}." >&2
        else
            echo "ERROR: SWARM_PROMPT is not set." >&2
        fi
        exit 1
    fi

    if [ ! -f "$REPO_ROOT/$SWARM_PROMPT" ]; then
        echo "ERROR: ${SWARM_PROMPT} not found." >&2
        exit 1
    fi

    if $AGENTS_CLI_OVERRIDE && [ -n "$CONFIG_FILE" ]; then
        echo "ERROR: --agents cannot override agent groups defined in ${CONFIG_FILE}." >&2
        echo "       Edit the 'count' fields in ${CONFIG_FILE} instead." >&2
        exit 1
    fi

    # Validate per-group prompt overrides.
    if [ -n "$CONFIG_FILE" ]; then
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
    fi

    # Refuse to overwrite a bare repo that has unharvested commits.
    if [ -d "$BARE_REPO" ]; then
        BARE_HEAD=$(git -C "$BARE_REPO" rev-parse refs/heads/agent-work 2>/dev/null || true)
        LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
        if [ -n "$BARE_HEAD" ] && [ "$BARE_HEAD" != "$LOCAL_HEAD" ]; then
            echo "ERROR: ${BARE_REPO} has unharvested agent commits." >&2
            echo "       Run harvest.sh first, or remove it manually:" >&2
            echo "       rm -rf ${BARE_REPO}" >&2
            exit 1
        fi
    fi

    echo "--- Creating bare repo ---"
    rm_docker_dir "$BARE_REPO"
    git clone --bare "$REPO_ROOT" "$BARE_REPO"

    git -C "$BARE_REPO" branch agent-work HEAD 2>/dev/null || true
    git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/agent-work

    # Mirror each submodule so containers can init without network.
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name|$toplevel/.git/modules/$sm_path"' | \
    while IFS='|' read -r name gitdir; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        rm -rf "$mirror"
        echo "--- Mirroring submodule: ${name} ---"
        git clone --bare "$gitdir" "$mirror"
    done

    echo "--- Building agent image ---"
    docker build -t "$IMAGE_NAME" -f "$SWARM_DIR/Dockerfile" "$SWARM_DIR"

    # Build mirror volume args from discovered submodules.
    git submodule foreach --quiet 'echo "$name"' | while read -r name; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        echo "-v ${mirror}:/mirrors/${name}:ro"
    done > "/tmp/${PROJECT}-mirror-vols.txt"

    # Build per-agent config (model|base_url|api_key|effort|auth|context|prompt|auth_token|tag|driver per line).
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    AGENTS_CFG="/tmp/${PROJECT}-agents.cfg"
    if [ -n "$CONFIG_FILE" ]; then
        jq -r '.driver as $dd | .agents[] | range(.count) as $i |
            [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // ""), (.driver // $dd // "")] | join("|")' \
            "$CONFIG_FILE" > "$AGENTS_CFG"
    else
        : > "$AGENTS_CFG"
        for _i in $(seq 1 "$NUM_AGENTS"); do
            printf '%s|||%s||||||\n' "$SWARM_MODEL" "${EFFORT_LEVEL:-}" >> "$AGENTS_CFG"
        done
    fi

    # Read mirror volume mounts (shared across all containers).
    MIRROR_ARGS=()
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-mirror-vols.txt"

    AGENT_IDX=0
    while IFS='|' read -r agent_model agent_base_url agent_api_key agent_effort agent_auth agent_context agent_prompt agent_auth_token agent_tag agent_driver; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        docker rm -f "$NAME" 2>/dev/null || true
        agent_api_key="$(expand_env_ref "$agent_api_key")"
        agent_auth_token="$(expand_env_ref "$agent_auth_token")"
        agent_context="${agent_context:-full}"
        agent_driver="${agent_driver:-${SWARM_DRIVER_DEFAULT}}"
        local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"

        local ctx_label="" prompt_label="" driver_label=""
        [ "$agent_context" != "full" ] && ctx_label=" context=${agent_context}"
        [ -n "$agent_prompt" ] && prompt_label=" prompt=${agent_prompt}"
        [ "$agent_driver" != "claude-code" ] && driver_label=" driver=${agent_driver}"
        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}}${ctx_label}${prompt_label}${driver_label}) ---"
        EXTRA_ENV=()
        if [ -n "$agent_base_url" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${agent_base_url}")
        elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
        fi
        [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
            && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")

        # Per-agent auth source: "oauth" = subscription only,
        # "apikey" = API key only, "" = pass both (CLI decides).
        #
        # auth_token mode (OpenRouter-style): the key goes into
        # ANTHROPIC_AUTH_TOKEN (Bearer header) and ANTHROPIC_API_KEY
        # is explicitly empty so the agent CLI enters third-party mode.
        local resolved_api_key
        if [ -n "$agent_auth_token" ]; then
            resolved_api_key=""
            EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${agent_auth_token}")
        else
            case "${agent_auth}" in
                oauth)
                    resolved_api_key=""
                    EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}")
                    ;;
                apikey)
                    resolved_api_key="${agent_api_key:-${ANTHROPIC_API_KEY:-}}"
                    ;;
                *)
                    resolved_api_key="${agent_api_key:-${ANTHROPIC_API_KEY:-}}"
                    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                        && EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
                    ;;
            esac
        fi

        # Dashboard auth label: describes the actual credential source.
        local auth_label=""
        if [ -n "$agent_auth_token" ]; then
            auth_label="token"
        elif [ "$agent_auth" = "oauth" ]; then
            auth_label="oauth"
        elif [ "$agent_auth" = "apikey" ]; then
            auth_label="key"
        elif [ -n "$agent_api_key" ]; then
            auth_label="key"
        elif [ -n "$resolved_api_key" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
            auth_label="auto"
        elif [ -n "$resolved_api_key" ]; then
            auth_label="key"
        elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
            auth_label="oauth"
        fi

        local eff="${agent_effort:-${EFFORT_LEVEL:-}}"
        [ -n "$eff" ] \
            && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${eff}")

        docker run -d \
            --name "$NAME" \
            -v "${BARE_REPO}:/upstream:rw" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            -e "ANTHROPIC_API_KEY=${resolved_api_key}" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            -e "SWARM_MODEL=${agent_model}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "SWARM_PROMPT=${effective_prompt}" \
            -e "SWARM_SETUP=${SWARM_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            -e "SWARM_AUTH_MODE=${auth_label}" \
            -e "SWARM_TAG=${agent_tag}" \
            -e "SWARM_CONTEXT=${agent_context}" \
            -e "SWARM_DRIVER=${agent_driver}" \
            -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
            -e "SWARM_CFG_PROMPT=${effective_prompt}" \
            -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f "/tmp/${PROJECT}-mirror-vols.txt" "/tmp/${PROJECT}-agents.cfg"

    # Write state file so a standalone dashboard can pick up config.
    local state_model_summary state_config_label
    if [ -n "$CONFIG_FILE" ]; then
        state_model_summary=$(jq -r \
            '.prompt as $dp | ($dp | split("/") | .[-1] | rtrimstr(".md")) as $dp_stem |
            [.agents[] |
              "\(.count)x \(.model | split("/") | .[-1])" +
              (if .context == "none" then " ctx:bare"
               elif .context == "slim" then " ctx:slim"
               else "" end) +
              (if .prompt and .prompt != $dp then
                ":" + (.prompt | split("/") | .[-1] | rtrimstr(".md") |
                  if startswith($dp_stem + "-") then .[$dp_stem | length + 1:] else . end)
               else "" end)] | join(", ")' \
            "$CONFIG_FILE")
        state_config_label=$(basename "$CONFIG_FILE")
    else
        state_model_summary="${NUM_AGENTS}x ${SWARM_MODEL}"
        state_config_label="env vars"
    fi
    cat > "/tmp/${PROJECT}-swarm.env" <<ENVEOF
SWARM_TITLE="${SWARM_TITLE:-}"
SWARM_PROMPT="${SWARM_PROMPT}"
SWARM_CONFIG="${CONFIG_FILE}"
SWARM_NUM_AGENTS="${NUM_AGENTS}"
SWARM_MODEL_SUMMARY="${state_model_summary}"
SWARM_CONFIG_LABEL="${state_config_label}"
ENVEOF

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
    echo "Bare repo: ${BARE_REPO}"
}

cmd_stop() {
    echo "--- Stopping agents ---"
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        docker stop "$NAME" 2>/dev/null && echo "  stopped ${NAME}" \
            || echo "  ${NAME} not running"
    done
    rm -f "/tmp/${PROJECT}-swarm.env"
}

cmd_logs() {
    local n="${1:-1}"
    docker logs -f "${IMAGE_NAME}-${n}"
}

cmd_status() {
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        printf "%-30s " "${NAME}:"
        docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null \
            || echo "not found"
    done
}

cmd_wait() {
    echo "--- Waiting for all agents to finish ---"

    while true; do
        sleep 10
        local all_done=true running=0 exited=0
        for i in $(seq 1 "$NUM_AGENTS"); do
            local state
            state=$(docker inspect -f '{{.State.Status}}' "${IMAGE_NAME}-${i}" 2>/dev/null || echo "not found")
            case "$state" in
                running) running=$((running + 1)); all_done=false ;;
                exited)  exited=$((exited + 1)) ;;
            esac
        done

        printf "\r  %d running, %d exited " "$running" "$exited"

        if $all_done; then
            echo ""
            echo "All agents finished."
            break
        fi
    done

    if [ -n "$CONFIG_FILE" ]; then
        local pp_prompt
        pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
        if [ -n "$pp_prompt" ]; then
            echo ""
            cmd_post_process
            return
        fi
    fi

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

cmd_post_process() {
    if [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: post-process requires a config file with a post_process section." >&2
        exit 1
    fi

    local pp_prompt pp_model pp_base_url pp_api_key pp_effort pp_auth pp_auth_token pp_tag pp_driver
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_base_url=$(jq -r '.post_process.base_url // empty' "$CONFIG_FILE")
    pp_api_key=$(jq -r '.post_process.api_key // empty' "$CONFIG_FILE")
    pp_api_key="$(expand_env_ref "$pp_api_key")"
    pp_auth_token=$(jq -r '.post_process.auth_token // empty' "$CONFIG_FILE")
    pp_auth_token="$(expand_env_ref "$pp_auth_token")"
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")
    pp_auth=$(jq -r '.post_process.auth // empty' "$CONFIG_FILE")
    pp_tag=$(jq -r '.post_process.tag // empty' "$CONFIG_FILE")
    pp_driver=$(jq -r '.post_process.driver // .driver // "claude-code"' "$CONFIG_FILE")

    if [ -z "$pp_prompt" ]; then
        echo "ERROR: post_process.prompt is not set in ${CONFIG_FILE}." >&2
        exit 1
    fi

    if [ ! -d "$BARE_REPO" ]; then
        echo "ERROR: ${BARE_REPO} not found." >&2
        exit 1
    fi

    local NAME="${IMAGE_NAME}-post"
    docker rm -f "$NAME" 2>/dev/null || true

    # Build mirror volume args from existing mirrors.
    local MIRROR_ARGS=()
    cd "$REPO_ROOT"
    git submodule foreach --quiet 'echo "$name"' 2>/dev/null | while read -r name; do
        local safe_name="${name//\//_}"
        local mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        if [ -d "$mirror" ]; then
            echo "-v ${mirror}:/mirrors/${name}:ro"
        fi
    done > "/tmp/${PROJECT}-pp-vols.txt"
    while read -r line; do
        # shellcheck disable=SC2206
        MIRROR_ARGS+=($line)
    done < "/tmp/${PROJECT}-pp-vols.txt"
    rm -f "/tmp/${PROJECT}-pp-vols.txt"

    local EXTRA_ENV=()
    if [ -n "$pp_base_url" ]; then
        EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${pp_base_url}")
    elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
    fi
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
        && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")

    local pp_resolved_api_key
    if [ -n "$pp_auth_token" ]; then
        pp_resolved_api_key=""
        EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${pp_auth_token}")
    else
        case "${pp_auth}" in
            oauth)
                pp_resolved_api_key=""
                EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}")
                ;;
            apikey)
                pp_resolved_api_key="${pp_api_key:-${ANTHROPIC_API_KEY:-}}"
                ;;
            *)
                pp_resolved_api_key="${pp_api_key:-${ANTHROPIC_API_KEY:-}}"
                [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                    && EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
                ;;
        esac
    fi

    local pp_auth_label=""
    if [ -n "$pp_auth_token" ]; then
        pp_auth_label="token"
    elif [ "$pp_auth" = "oauth" ]; then
        pp_auth_label="oauth"
    elif [ "$pp_auth" = "apikey" ]; then
        pp_auth_label="key"
    elif [ -n "$pp_api_key" ]; then
        pp_auth_label="key"
    elif [ -n "$pp_resolved_api_key" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        pp_auth_label="auto"
    elif [ -n "$pp_resolved_api_key" ]; then
        pp_auth_label="key"
    elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        pp_auth_label="oauth"
    fi

    [ -n "$pp_effort" ] \
        && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${pp_effort}")

    echo "--- Starting post-processing (${pp_model}) ---"
    docker run -d \
        --name "$NAME" \
        -v "${BARE_REPO}:/upstream:rw" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        -e "ANTHROPIC_API_KEY=${pp_resolved_api_key}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        -e "SWARM_MODEL=${pp_model}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "SWARM_PROMPT=${pp_prompt}" \
        -e "SWARM_SETUP=${SWARM_SETUP:-}" \
        -e "MAX_IDLE=${MAX_IDLE}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
        -e "SWARM_AUTH_MODE=${pp_auth_label}" \
        -e "SWARM_TAG=${pp_tag}" \
        -e "SWARM_DRIVER=${pp_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${pp_prompt}" \
        -e "SWARM_CFG_SETUP=${SWARM_SETUP:-}" \
        "$IMAGE_NAME"

    echo "Post-processing agent launched: ${NAME}"
    echo "Waiting for completion..."

    while true; do
        sleep 10
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "not found")
        if [ "$state" = "running" ]; then
            printf "."
            continue
        fi
        echo ""
        echo "Post-processing agent finished (${state})."
        break
    done

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

case "${1:-start}" in
    start)
        shift
        parse_start_args "$@"
        cmd_start
        if $OPEN_DASHBOARD; then
            exec "$SWARM_DIR/dashboard.sh"
        fi
        ;;
    stop)          cmd_stop ;;
    logs)          cmd_logs "${2:-1}" ;;
    status)        cmd_status ;;
    wait)          cmd_wait ;;
    post-process)  cmd_post_process ;;
    *)
        echo "Usage: $0 {start|stop|logs N|status|wait|post-process}" >&2
        echo "Try '$0 --help' for more information." >&2
        exit 1
        ;;
esac
