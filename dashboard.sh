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
DASHBOARD_TITLE="${SWARM_TITLE:-claude-swarm}"

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    local_title=$(jq -r '.title // empty' "$CONFIG_FILE")
    if [ -n "$local_title" ]; then
        DASHBOARD_TITLE="$local_title"
    fi
    AGENT_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
    MODEL_SUMMARY=$(jq -r \
        '[.agents[] | "\(.count)x \(.model | split("/") | .[-1])"] | join(", ")' \
        "$CONFIG_FILE")
    CONFIG_LABEL="$(basename "$CONFIG_FILE")"
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-}"
    if [ -z "$NUM_AGENTS" ]; then
        NUM_AGENTS=$(docker ps -a --filter "name=${IMAGE_NAME}-" \
            --format '{{.Names}}' 2>/dev/null \
            | grep -c "^${IMAGE_NAME}-[0-9]" || echo 0)
        [ "$NUM_AGENTS" -eq 0 ] && NUM_AGENTS=3
    fi
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

format_duration_ms() {
    format_duration $(( ${1:-0} / 1000 ))
}

format_tokens() {
    local n=${1:-0}
    if [ "$n" -ge 1000000 ]; then
        printf '%.1fM' "$(echo "$n / 1000000" | bc -l)"
    elif [ "$n" -ge 1000 ]; then
        printf '%.0fk' "$(echo "$n / 1000" | bc -l)"
    else
        printf '%d' "$n"
    fi
}

format_cost() {
    printf '$%.2f' "${1:-0}"
}

read_agent_stats() {
    local name=$1 agent_id=$2
    local stats_file="agent_logs/stats_agent_${agent_id}.tsv"
    local tmpf="/tmp/.swarm-stats-${name}.tsv"
    docker cp "${name}:/workspace/${stats_file}" "$tmpf" 2>/dev/null || true
    if [ ! -s "$tmpf" ]; then
        rm -f "$tmpf"
        echo "0 0 0 0 0 0"
        return
    fi
    awk -F'\t' '{
        cost += $2; tok_in += $3; tok_out += $4;
        cache += $5; dur += $7; turns += $9
    } END {
        printf "%s %d %d %d %d %d\n", cost, tok_in, tok_out, cache, dur, turns
    }' "$tmpf"
    rm -f "$tmpf"
}

draw() {
    local now elapsed uptime_str
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    uptime_str=$(format_duration "$elapsed")

    tput cup 0 0 2>/dev/null || true
    tput ed 2>/dev/null || true

    # Header.
    local title=" ${BOLD}${DASHBOARD_TITLE}${RESET}"
    local title_len=${#DASHBOARD_TITLE}
    local right="${DIM}uptime: ${uptime_str}${RESET}"
    printf "%b%*s%b\n" "$title" $((TERM_COLS - title_len - 2 - ${#uptime_str} - 10)) "" "$right"
    printf " ${DIM}config: %s | prompt: %s${RESET}\n" "$CONFIG_LABEL" "$AGENT_PROMPT"
    printf " ${DIM}agents: %s (%s)${RESET}\n" "$NUM_AGENTS" "$MODEL_SUMMARY"
    echo ""

    # Agent table header.
    printf "  ${BOLD}%-3s %-16s %-10s %8s %9s %5s %7s${RESET}\n" \
        "#" "Model" "Status" "Cost" "In/Out" "Turns" "Time"

    local running_count=0 exited_count=0
    local total_cost=0 total_in=0 total_out=0 total_cache=0 total_dur=0 total_turns=0

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

        # Read cumulative stats from the container.
        local agent_stats a_cost a_in a_out a_cache a_dur a_turns
        agent_stats=$(read_agent_stats "$name" "$i")
        a_cost=$(echo "$agent_stats" | awk '{print $1}')
        a_in=$(echo "$agent_stats" | awk '{print $2}')
        a_out=$(echo "$agent_stats" | awk '{print $3}')
        a_cache=$(echo "$agent_stats" | awk '{print $4}')
        a_dur=$(echo "$agent_stats" | awk '{print $5}')
        a_turns=$(echo "$agent_stats" | awk '{print $6}')

        total_cost=$(echo "$total_cost + $a_cost" | bc)
        total_in=$((total_in + a_in))
        total_out=$((total_out + a_out))
        total_cache=$((total_cache + a_cache))
        total_dur=$((total_dur + a_dur))
        total_turns=$((total_turns + a_turns))

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

        local cost_str in_out_str dur_str
        cost_str=$(format_cost "$a_cost")
        in_out_str="$(format_tokens "$a_in")/$(format_tokens "$a_out")"
        dur_str=$(format_duration_ms "$a_dur")

        printf "  %-3s %-16s " "$i" "$short"
        printf "%b%-10s%b" "$status_color" "$status_text" "$RESET"
        printf " %8s %9s %5s %7s\n" "$cost_str" "$in_out_str" "$a_turns" "$dur_str"
    done

    # Post-process row (if container exists).
    local pp_name="${IMAGE_NAME}-post"
    local pp_state
    pp_state=$(docker inspect -f '{{.State.Status}}' "$pp_name" 2>/dev/null || true)
    if [ -n "$pp_state" ] && [ "$pp_state" != "none" ]; then
        local pp_model
        pp_model=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
            "$pp_name" 2>/dev/null | grep '^CLAUDE_MODEL=' | head -1 | cut -d= -f2- || true)
        pp_model="${pp_model:-unknown}"
        local pp_short="${pp_model/claude-/}"

        local pp_stats pp_cost pp_in pp_out pp_dur pp_turns
        pp_stats=$(read_agent_stats "$pp_name" "post")
        pp_cost=$(echo "$pp_stats" | awk '{print $1}')
        pp_in=$(echo "$pp_stats" | awk '{print $2}')
        pp_out=$(echo "$pp_stats" | awk '{print $3}')
        pp_dur=$(echo "$pp_stats" | awk '{print $5}')
        pp_turns=$(echo "$pp_stats" | awk '{print $6}')

        total_cost=$(echo "$total_cost + $pp_cost" | bc)
        total_in=$((total_in + pp_in))
        total_out=$((total_out + pp_out))
        total_dur=$((total_dur + pp_dur))
        total_turns=$((total_turns + pp_turns))

        local pp_status_color
        case "$pp_state" in
            running) pp_status_color="$GREEN" ;;
            exited)  pp_status_color="$RED" ;;
            *)       pp_status_color="$DIM" ;;
        esac

        printf "  ${DIM}%s${RESET}\n" "$(printf '%.0s·' $(seq 1 $((TERM_COLS - 4))))"
        printf "  %-3s %-16s " "PP" "$pp_short"
        printf "%b%-10s%b" "$pp_status_color" "$pp_state" "$RESET"
        printf " %8s %9s %5s %7s\n" \
            "$(format_cost "$pp_cost")" \
            "$(format_tokens "$pp_in")/$(format_tokens "$pp_out")" \
            "$pp_turns" "$(format_duration_ms "$pp_dur")"
    fi

    # Totals row.
    printf "  ${DIM}%s${RESET}\n" "$(printf '%.0s─' $(seq 1 $((TERM_COLS - 4))))"
    local t_cost_str t_inout_str t_dur_str
    t_cost_str=$(format_cost "$total_cost")
    t_inout_str="$(format_tokens "$total_in")/$(format_tokens "$total_out")"
    t_dur_str=$(format_duration_ms "$total_dur")
    printf "  ${BOLD}%-3s %-16s %-10s %8s %9s %5s %7s${RESET}\n" \
        "" "Total" "" "$t_cost_str" "$t_inout_str" "$total_turns" "$t_dur_str"

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
    draw || true

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
