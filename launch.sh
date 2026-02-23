#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|logs N|status|wait|post-process}

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
IMAGE_NAME="${PROJECT}-agent"
CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file ${CONFIG_FILE} not found." >&2
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required to parse config files." >&2
        exit 1
    fi
    AGENT_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
    AGENT_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
    MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
    INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
    GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
    GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@claude-swarm.local"' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-3}"
    CLAUDE_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    AGENT_PROMPT="${SWARM_PROMPT:-}"
    AGENT_SETUP="${SWARM_SETUP:-}"
    MAX_IDLE="${SWARM_MAX_IDLE:-3}"
    INJECT_GIT_RULES="${SWARM_INJECT_GIT_RULES:-true}"
    GIT_USER_NAME="${SWARM_GIT_USER_NAME:-swarm-agent}"
    GIT_USER_EMAIL="${SWARM_GIT_USER_EMAIL:-agent@claude-swarm.local}"
    EFFORT_LEVEL="${SWARM_EFFORT:-}"
fi

cmd_start() {
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: ANTHROPIC_API_KEY is not set." >&2
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker is not installed." >&2
        exit 1
    fi

    if [ -z "$AGENT_PROMPT" ]; then
        if [ -n "$CONFIG_FILE" ]; then
            echo "ERROR: 'prompt' is missing in ${CONFIG_FILE}." >&2
        else
            echo "ERROR: SWARM_PROMPT is not set." >&2
        fi
        exit 1
    fi

    if [ ! -f "$REPO_ROOT/$AGENT_PROMPT" ]; then
        echo "ERROR: ${AGENT_PROMPT} not found." >&2
        exit 1
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
    rm -rf "$BARE_REPO"
    git clone --bare "$REPO_ROOT" "$BARE_REPO"

    git -C "$BARE_REPO" branch agent-work HEAD 2>/dev/null || true
    git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/agent-work

    # Mirror each submodule so containers can init without network.
    MIRROR_VOLS=()
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
    MIRROR_VOLS=()
    git submodule foreach --quiet 'echo "$name"' | while read -r name; do
        safe_name="${name//\//_}"
        mirror="/tmp/${PROJECT}-mirror-${safe_name}.git"
        echo "-v ${mirror}:/mirrors/${name}:ro"
    done > /tmp/${PROJECT}-mirror-vols.txt

    # Build per-agent config (model|base_url|api_key|effort per line).
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    AGENTS_CFG="/tmp/${PROJECT}-agents.cfg"
    if [ -n "$CONFIG_FILE" ]; then
        jq -r '.agents[] | range(.count) as $i |
            [.model, (.base_url // ""), (.api_key // ""), (.effort // "")] | join("|")' \
            "$CONFIG_FILE" > "$AGENTS_CFG"
    else
        : > "$AGENTS_CFG"
        for _i in $(seq 1 "$NUM_AGENTS"); do
            printf '%s|||%s\n' "$CLAUDE_MODEL" "${EFFORT_LEVEL:-}" >> "$AGENTS_CFG"
        done
    fi

    # Read mirror volume mounts (shared across all containers).
    MIRROR_ARGS=()
    while read -r line; do
        # shellcheck disable=SC2086
        MIRROR_ARGS+=($line)
    done < /tmp/${PROJECT}-mirror-vols.txt

    AGENT_IDX=0
    while IFS='|' read -r agent_model agent_base_url agent_api_key agent_effort; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        docker rm -f "$NAME" 2>/dev/null || true

        # Tag git user name with model so commits identify the model.
        local short_model="${agent_model/claude-/}"
        short_model="${short_model//\//-}"
        local agent_git_name="${GIT_USER_NAME} [${short_model}]"

        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}}) ---"
        EXTRA_ENV=()
        if [ -n "$agent_base_url" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${agent_base_url}")
        elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
        fi
        [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
            && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")
        local eff="${agent_effort:-${EFFORT_LEVEL:-}}"
        [ -n "$eff" ] \
            && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${eff}")

        docker run -d \
            --name "$NAME" \
            -v "${BARE_REPO}:/upstream:rw" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            -e "ANTHROPIC_API_KEY=${agent_api_key:-${ANTHROPIC_API_KEY:-}}" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "AGENT_PROMPT=${AGENT_PROMPT}" \
            -e "AGENT_SETUP=${AGENT_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "GIT_USER_NAME=${agent_git_name}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f /tmp/${PROJECT}-mirror-vols.txt /tmp/${PROJECT}-agents.cfg

    # Write state file so a standalone dashboard can pick up config.
    local state_model_summary state_config_label
    if [ -n "$CONFIG_FILE" ]; then
        state_model_summary=$(jq -r \
            '[.agents[] | "\(.count)x \(.model | split("/") | .[-1])"] | join(", ")' \
            "$CONFIG_FILE")
        state_config_label=$(basename "$CONFIG_FILE")
    else
        state_model_summary="${NUM_AGENTS}x ${CLAUDE_MODEL}"
        state_config_label="env vars"
    fi
    cat > "/tmp/${PROJECT}-swarm.env" <<ENVEOF
SWARM_TITLE="${SWARM_TITLE:-}"
SWARM_PROMPT="${AGENT_PROMPT}"
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

    local pp_prompt pp_model pp_base_url pp_api_key pp_effort
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_base_url=$(jq -r '.post_process.base_url // empty' "$CONFIG_FILE")
    pp_api_key=$(jq -r '.post_process.api_key // empty' "$CONFIG_FILE")
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")

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
    done > /tmp/${PROJECT}-pp-vols.txt
    while read -r line; do
        # shellcheck disable=SC2086
        MIRROR_ARGS+=($line)
    done < /tmp/${PROJECT}-pp-vols.txt
    rm -f /tmp/${PROJECT}-pp-vols.txt

    local EXTRA_ENV=()
    if [ -n "$pp_base_url" ]; then
        EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${pp_base_url}")
    elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
    fi
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
        && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")
    [ -n "$pp_effort" ] \
        && EXTRA_ENV+=(-e "CLAUDE_CODE_EFFORT_LEVEL=${pp_effort}")

    echo "--- Starting post-processing (${pp_model}) ---"
    docker run -d \
        --name "$NAME" \
        -v "${BARE_REPO}:/upstream:rw" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        -e "ANTHROPIC_API_KEY=${pp_api_key:-${ANTHROPIC_API_KEY:-}}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "AGENT_PROMPT=${pp_prompt}" \
        -e "AGENT_SETUP=${AGENT_SETUP:-}" \
        -e "MAX_IDLE=${MAX_IDLE}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
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
        cmd_start
        if [ "${2:-}" = "--dashboard" ]; then
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
        exit 1
        ;;
esac
