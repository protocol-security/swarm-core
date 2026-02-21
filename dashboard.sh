#!/bin/bash
set -euo pipefail

# Always-on TUI dashboard for claude-swarm.
# Pure bash with ANSI escape codes and tput.

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
IMAGE_NAME="${PROJECT}-agent"
START_TIME=$(date +%s)

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    AGENT_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
    MODEL_SUMMARY=$(jq -r \
        '[.agents[] | "\(.count)x \(.model | split("/") | .[-1])"] | join(", ")' \
        "$CONFIG_FILE")
    CONFIG_LABEL="$(basename "$CONFIG_FILE")"
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-3}"
    AGENT_PROMPT="${SWARM_PROMPT:-}"
    CLAUDE_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    MODEL_SUMMARY="${NUM_AGENTS}x ${CLAUDE_MODEL}"
    CONFIG_LABEL="env vars"
fi

BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

TERM_COLS=80

handle_resize() {
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
}
trap handle_resize SIGWINCH
handle_resize

cleanup() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}
trap cleanup EXIT

enter_alt_screen() {
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
}

leave_alt_screen() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

format_duration() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
    elif [ "$s" -ge 60 ]; then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

draw() {
    local now elapsed uptime_str
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    uptime_str=$(format_duration "$elapsed")

    tput cup 0 0
    tput ed

    # Header.
    local title=" ${BOLD}claude-swarm${RESET}"
    local right="${DIM}uptime: ${uptime_str}${RESET}"
    printf "%b%*s%b\n" "$title" $((TERM_COLS - 13 - ${#uptime_str} - 10)) "" "$right"
    printf " ${DIM}config: %s | prompt: %s${RESET}\n" "$CONFIG_LABEL" "$AGENT_PROMPT"
    printf " ${DIM}agents: %s (%s)${RESET}\n" "$NUM_AGENTS" "$MODEL_SUMMARY"
    echo ""

    # Agent table header.
    printf "  ${BOLD}%-4s %-20s %-14s %8s${RESET}\n" "#" "Model" "Status" "Sessions"

    local running_count=0 exited_count=0

    for i in $(seq 1 "$NUM_AGENTS"); do
        local name="${IMAGE_NAME}-${i}"

        local state
        state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "not found")

        local model="unknown"
        if [ "$state" != "not found" ]; then
            model=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
                "$name" 2>/dev/null | grep '^CLAUDE_MODEL=' | head -1 | cut -d= -f2- || true)
            model="${model:-unknown}"
        fi
        local short="${model/claude-/}"

        local sessions=0 idle_str=""
        if [ "$state" != "not found" ]; then
            local logs
            logs=$(docker logs "$name" 2>&1 || true)
            sessions=$(printf '%s' "$logs" | grep -c "Starting session" || true)
            idle_str=$(printf '%s' "$logs" | grep -o 'idle [0-9]*/[0-9]*' | tail -1 || true)
        fi

        local status_text status_color
        case "$state" in
            running)
                running_count=$((running_count + 1))
                if [ -n "$idle_str" ]; then
                    status_text="$idle_str"
                    status_color="$YELLOW"
                else
                    status_text="running"
                    status_color="$GREEN"
                fi
                ;;
            exited)
                exited_count=$((exited_count + 1))
                status_text="exited"
                status_color="$RED"
                ;;
            *)
                status_text="$state"
                status_color="$DIM"
                ;;
        esac

        printf "  %-4s %-20s " "$i" "$short"
        printf "%b%-14s%b" "$status_color" "$status_text" "$RESET"
        printf " %7s\n" "$sessions"
    done

    echo ""

    # Recent commits.
    if [ -d "$BARE_REPO" ]; then
        local commit_count
        commit_count=$(git -C "$BARE_REPO" rev-list --count refs/heads/agent-work 2>/dev/null || echo 0)
        printf " ${BOLD}Recent commits${RESET} ${DIM}(%s total):${RESET}\n" "$commit_count"
        git -C "$BARE_REPO" log refs/heads/agent-work --oneline -8 2>/dev/null | \
        while IFS= read -r line; do
            printf "   ${DIM}%s${RESET}\n" "$line"
        done
    else
        printf " ${DIM}(bare repo not found -- are agents running?)${RESET}\n"
    fi

    echo ""

    if [ "$running_count" -eq 0 ] && [ "$exited_count" -gt 0 ]; then
        printf " ${BOLD}${GREEN}Swarm complete${RESET} -- all %s agents exited.\n" "$exited_count"
        echo ""
    fi

    # Help bar.
    printf " ${DIM}[q]${RESET} quit"
    printf "  ${DIM}[1-9]${RESET} logs"
    printf "  ${DIM}[h]${RESET} harvest"
    printf "  ${DIM}[s]${RESET} stop all"
    printf "  ${DIM}[p]${RESET} post-process"
    printf "\n"
}

enter_alt_screen

while true; do
    draw

    if read -rsn1 -t 3 key 2>/dev/null; then
        case "$key" in
            q|Q)
                exit 0
                ;;
            [1-9])
                leave_alt_screen
                echo "--- Logs for ${IMAGE_NAME}-${key} (Ctrl-C to return) ---"
                docker logs -f "${IMAGE_NAME}-${key}" 2>&1 || true
                enter_alt_screen
                ;;
            h|H)
                leave_alt_screen
                "$SWARM_DIR/harvest.sh" || true
                echo ""
                read -rp "Press Enter to return to dashboard..." _
                enter_alt_screen
                ;;
            s|S)
                leave_alt_screen
                echo "--- Stopping all agents ---"
                for i in $(seq 1 "$NUM_AGENTS"); do
                    docker stop "${IMAGE_NAME}-${i}" 2>/dev/null \
                        && echo "  stopped ${IMAGE_NAME}-${i}" || true
                done
                echo ""
                read -rp "Press Enter to return to dashboard..." _
                enter_alt_screen
                ;;
            p|P)
                leave_alt_screen
                echo "--- Stopping agents ---"
                for i in $(seq 1 "$NUM_AGENTS"); do
                    docker stop "${IMAGE_NAME}-${i}" 2>/dev/null || true
                done
                echo "--- Starting post-processing ---"
                "$SWARM_DIR/launch.sh" post-process || \
                    echo "(post-processing not configured -- add post_process to swarm.json)"
                echo ""
                read -rp "Press Enter to return to dashboard..." _
                enter_alt_screen
                ;;
        esac
    fi
done
