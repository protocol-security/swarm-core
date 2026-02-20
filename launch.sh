#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|logs N|status}

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
    GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
    GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@claude-swarm.local"' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-3}"
    CLAUDE_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    AGENT_PROMPT="${SWARM_PROMPT:-}"
    AGENT_SETUP="${SWARM_SETUP:-}"
    MAX_IDLE="${SWARM_MAX_IDLE:-3}"
    GIT_USER_NAME="${SWARM_GIT_USER_NAME:-swarm-agent}"
    GIT_USER_EMAIL="${SWARM_GIT_USER_EMAIL:-agent@claude-swarm.local}"
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

    # Build per-agent config (model, base_url, api_key per line).
    AGENTS_TSV="/tmp/${PROJECT}-agents.tsv"
    if [ -n "$CONFIG_FILE" ]; then
        jq -r '.agents[] | range(.count) as $i |
            [.model, (.base_url // ""), (.api_key // "")] | @tsv' \
            "$CONFIG_FILE" > "$AGENTS_TSV"
    else
        : > "$AGENTS_TSV"
        for _i in $(seq 1 "$NUM_AGENTS"); do
            printf '%s\t\t\n' "$CLAUDE_MODEL" >> "$AGENTS_TSV"
        done
    fi

    # Read mirror volume mounts (shared across all containers).
    MIRROR_ARGS=()
    while read -r line; do
        # shellcheck disable=SC2086
        MIRROR_ARGS+=($line)
    done < /tmp/${PROJECT}-mirror-vols.txt

    AGENT_IDX=0
    while IFS=$'\t' read -r agent_model agent_base_url agent_api_key; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        docker rm -f "$NAME" 2>/dev/null || true

        echo "--- Launching ${NAME} (${agent_model}) ---"
        EXTRA_ENV=()
        if [ -n "$agent_base_url" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${agent_base_url}")
        elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}")
        fi
        [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
            && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}")

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
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            "$IMAGE_NAME"
    done < "$AGENTS_TSV"

    rm -f /tmp/${PROJECT}-mirror-vols.txt /tmp/${PROJECT}-agents.tsv

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
        docker rm "$NAME" 2>/dev/null || true
    done
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

case "${1:-start}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    logs)   cmd_logs "${2:-1}" ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 {start|stop|logs N|status}" >&2
        exit 1
        ;;
esac
