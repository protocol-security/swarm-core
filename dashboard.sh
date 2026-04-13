#!/bin/bash
set -euo pipefail

# Always-on TUI dashboard for swarm agents.
# Pure bash with ANSI escape codes and tput.

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Always-on TUI dashboard for swarm agents.
Refreshes every 3 seconds. Shows per-agent model, auth source,
status, cost, token usage, cache tokens, turns, and duration.

Keybindings:
  q           Quit the dashboard.
  1-9         Tail logs for agent N.
  h           Harvest agent results into current branch.
  s           Stop numbered agents (not post-process).
  p           Run post-processing agent.

Environment:
  SWARM_TITLE    Dashboard title override.
  SWARM_CONFIG   Path to swarm.json (auto-detected from repo root).
HELP
    exit 0
fi

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker tput bc

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
IMAGE_NAME="${PROJECT}-agent"
START_TIME=$(date +%s)

GIT_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
GIT_SHORT_HEAD=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")

DEFAULT_TITLE="${PROJECT}"
[ -n "$GIT_SHORT_HEAD" ] && DEFAULT_TITLE="${PROJECT} (@${GIT_SHORT_HEAD})"

# Save user's explicit env var so it takes priority over state file.
USER_TITLE="${SWARM_TITLE:-}"

# Source state file written by launch.sh (fills in env vars
# that a standalone dashboard would otherwise lack).
STATE_FILE="/tmp/${PROJECT}-swarm.env"
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

DASHBOARD_TITLE="${USER_TITLE:-${SWARM_TITLE:-${DEFAULT_TITLE}}}"

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -n "$CONFIG_FILE" ]; then
    local_title=$(jq -r '.title // empty' "$CONFIG_FILE")
    if [ -n "$local_title" ]; then
        DASHBOARD_TITLE="$local_title"
    fi
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
    MODEL_SUMMARY=$(jq -r \
        '(.prompt // "") as $dp | ($dp | split("/") | .[-1] // "" | rtrimstr(".md")) as $dp_stem |
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
    CONFIG_LABEL="$(basename "$CONFIG_FILE")"
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-}"
    if [ -z "$NUM_AGENTS" ]; then
        NUM_AGENTS=$(docker ps -a --filter "name=${IMAGE_NAME}-" \
            --format '{{.Names}}' 2>/dev/null \
            | grep -c "^${IMAGE_NAME}-[0-9]" 2>/dev/null || true)
        NUM_AGENTS="${NUM_AGENTS:-0}"
        [ "$NUM_AGENTS" -eq 0 ] && NUM_AGENTS=3
    fi
    SWARM_ACTIVE_MODEL="${SWARM_MODEL:-claude-opus-4-6}"
    MODEL_SUMMARY="${NUM_AGENTS}x ${SWARM_ACTIVE_MODEL}"
    CONFIG_LABEL="env vars"
fi

MODEL_COL_W=25
if [ -n "$CONFIG_FILE" ]; then
    MODEL_COL_W=$(jq -r '
        [.agents[] | .model + if .effort then " (\(.effort[:1]))" else "" end] +
        [.post_process // {} | select(.model) |
         .model + if .effort then " (\(.effort[:1]))" else "" end] |
        map(length) | max + 2
    ' "$CONFIG_FILE" 2>/dev/null || echo 25)
fi
[ "$MODEL_COL_W" -lt 22 ] && MODEL_COL_W=22

HAS_MULTI_DRIVERS=false
DRV_COL_W=6
if [ -n "$CONFIG_FILE" ]; then
    _nd=$(jq -r '.driver as $dd | [.agents[] | (.driver // $dd // "claude-code")] | unique | length' \
        "$CONFIG_FILE" 2>/dev/null || echo 1)
    [ "$_nd" -gt 1 ] && HAS_MULTI_DRIVERS=true
fi

HAS_TAGS=false
TAG_COL_W=12
if [ -n "$CONFIG_FILE" ]; then
    _tw=$(jq -r '[.agents[] | .tag // empty] | if length == 0 then 0
        else map(length) | max end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$_tw" -gt 0 ]; then
        HAS_TAGS=true
        TAG_COL_W="$_tw"
        [ "$TAG_COL_W" -lt 3 ] && TAG_COL_W=3
        [ "$TAG_COL_W" -gt 16 ] && TAG_COL_W=16
    fi
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

format_duration_short() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%dh' $((s / 3600))
    elif [ "$s" -ge 60 ]; then
        printf '%dm' $((s / 60))
    else
        printf '%ds' "$s"
    fi
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

format_tps() {
    local tokens=${1:-0} ms=${2:-0}
    if [ "$ms" -le 0 ] || [ "$tokens" -le 0 ]; then
        printf '%s' '--'
        return
    fi
    printf '%.1f' "$(echo "$tokens * 1000 / $ms" | bc -l)"
}

format_model() {
    local m="${1:-unknown}" effort="${2:-}"
    if [ -n "$effort" ]; then
        local e="${effort:0:1}"
        [ "$effort" = "max" ] && e="M"
        printf '%s (%s)' "$m" "$e"
    else
        printf '%s' "$m"
    fi
}

short_driver() {
    case "${1:-}" in
        claude-code) printf 'claude' ;;
        gemini-cli)  printf 'gemini' ;;
        codex-cli)   printf 'codex'  ;;
        *)           printf '%s' "${1:-}" ;;
    esac
}

truncate_str() {
    local s="$1" max="${2:-16}"
    if [ "${#s}" -le "$max" ]; then
        printf '%s' "$s"
        return
    fi
    local keep=$(( (max - 1) / 2 ))
    printf '%s~%s' "${s:0:$keep}" "${s: -$keep}"
}

read_agent_stats() {
    local name=$1 agent_id=$2
    local stats_file="agent_logs/stats_agent_${agent_id}.tsv"
    local tmpf="/tmp/.swarm-stats-${name}.tsv"
    docker cp "${name}:/workspace/${stats_file}" "$tmpf" 2>/dev/null || true
    if [ ! -s "$tmpf" ]; then
        rm -f "$tmpf"
        echo "0 0 0 0 0 0 0"
        return
    fi
    awk -F'\t' '{
        cost += $2; tok_in += $3; tok_out += $4;
        cache += $5; dur += $7; api_ms += $8; turns += $9
    } END {
        printf "%s %d %d %d %d %d %d\n", cost, tok_in, tok_out, cache, dur, api_ms, turns
    }' "$tmpf"
    rm -f "$tmpf"
}

read_idle_state() {
    local name=$1 agent_id=$2
    local idle_file="agent_logs/idle_agent_${agent_id}"
    local tmpf="/tmp/.swarm-idle-${name}"
    docker cp "${name}:/workspace/${idle_file}" "$tmpf" 2>/dev/null || true
    if [ -s "$tmpf" ]; then
        cat "$tmpf"
        rm -f "$tmpf"
    else
        rm -f "$tmpf"
        echo ""
    fi
}

read_retry_state() {
    local name=$1 agent_id=$2
    local retry_file="agent_logs/retry_agent_${agent_id}"
    local tmpf="/tmp/.swarm-retry-${name}"
    docker cp "${name}:/workspace/${retry_file}" "$tmpf" 2>/dev/null || true
    if [ -s "$tmpf" ]; then
        cat "$tmpf"
        rm -f "$tmpf"
    else
        rm -f "$tmpf"
        echo ""
    fi
}

emit_row() {
    local id_str="$1" model_str="$2" driver_str="$3" auth_str="$4"
    local status_color="$5" status_str="$6"
    local cost_str="$7" inout_str="$8" cache_str="$9"
    local turns_str="${10}" tps_str="${11}" dur_str="${12}"
    local tag_str="${13:-}" is_bold="${14:-}"

    local open="" close=""
    if [ "$is_bold" = "bold" ]; then open="$BOLD"; close="$RESET"; fi

    printf "  ${open}%-3s %-${MODEL_COL_W}s" "$id_str" "$model_str"
    if $SHOW_DRIVER; then printf " %-${DRV_COL_W}s" "$driver_str"; fi
    if $SHOW_AUTH;  then printf " %-7s" "$auth_str"; fi
    printf " %b%-14s%b %7s" "$status_color" "$status_str" "$RESET" "$cost_str"
    if $SHOW_INOUT; then printf " %13s" "$inout_str"; fi
    if $SHOW_CACHE; then printf " %7s" "$cache_str"; fi
    if $SHOW_TURNS; then printf " %6s" "$turns_str"; fi
    if $SHOW_TPS;   then printf " %6s" "$tps_str"; fi
    printf " %8s" "$dur_str"
    if $SHOW_TAG;   then printf "  %-${TAG_COL_W}s" "$tag_str"; fi
    printf "${close}\n"
}

emit_header() {
    printf "  ${BOLD}%-3s %-${MODEL_COL_W}s" "#" "Model"
    if $SHOW_DRIVER; then printf " %-${DRV_COL_W}s" "Driver"; fi
    if $SHOW_AUTH;  then printf " %-7s" "Auth"; fi
    printf " %-14s %7s" "Status" "Cost"
    if $SHOW_INOUT; then printf " %13s" "In/Out"; fi
    if $SHOW_CACHE; then printf " %7s" "Cache"; fi
    if $SHOW_TURNS; then printf " %6s" "Turns"; fi
    if $SHOW_TPS;   then printf " %6s" "Tok/s"; fi
    printf " %8s" "Time"
    if $SHOW_TAG;   then printf "  %-${TAG_COL_W}s" "Tag"; fi
    printf "${RESET}\n"
}

draw() {
    # Re-read state file so display updates on every refresh.
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        DASHBOARD_TITLE="${USER_TITLE:-${SWARM_TITLE:-${DEFAULT_TITLE}}}"
        NUM_AGENTS="${SWARM_NUM_AGENTS:-$NUM_AGENTS}"
        MODEL_SUMMARY="${SWARM_MODEL_SUMMARY:-$MODEL_SUMMARY}"
        CONFIG_LABEL="${SWARM_CONFIG_LABEL:-$CONFIG_LABEL}"

        local _new_cfg="${SWARM_CONFIG:-}"
        if [ -n "$_new_cfg" ] && [ "$_new_cfg" != "$CONFIG_FILE" ] && [ -f "$_new_cfg" ]; then
            CONFIG_FILE="$_new_cfg"
            local _nd
            _nd=$(jq -r '.driver as $dd | [.agents[] | (.driver // $dd // "claude-code")] | unique | length' \
                "$CONFIG_FILE" 2>/dev/null || echo 1)
            HAS_MULTI_DRIVERS=false
            [ "$_nd" -gt 1 ] && HAS_MULTI_DRIVERS=true

            local _tw
            _tw=$(jq -r '[.agents[] | .tag // empty] | if length == 0 then 0
                else map(length) | max end' "$CONFIG_FILE" 2>/dev/null || echo 0)
            HAS_TAGS=false
            if [ "$_tw" -gt 0 ]; then
                HAS_TAGS=true
                TAG_COL_W=$((_tw + 2))
                [ "$TAG_COL_W" -lt 6 ] && TAG_COL_W=6
            fi
        fi
    fi

    local now elapsed uptime_str
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    uptime_str=$(format_duration "$elapsed")

    # Adaptive column visibility based on terminal width.
    # Base: # (3) + Model (MW+1) + Status (15) + Cost (8) + Time (9) + indent (2).
    local base_w=$((MODEL_COL_W + 38))
    SHOW_INOUT=false; SHOW_AUTH=false; SHOW_TURNS=false; SHOW_TPS=false; SHOW_CACHE=false; SHOW_TAG=false; SHOW_DRIVER=false
    local avail=$((TERM_COLS - base_w))
    if $HAS_MULTI_DRIVERS && [ "$avail" -ge $((DRV_COL_W + 1)) ]; then SHOW_DRIVER=true; avail=$((avail - DRV_COL_W - 1)); fi
    if [ "$avail" -ge 14 ]; then SHOW_INOUT=true; avail=$((avail - 14)); fi
    if [ "$avail" -ge 9 ];  then SHOW_AUTH=true;  avail=$((avail - 9)); fi
    if [ "$avail" -ge 7 ];  then SHOW_TURNS=true; avail=$((avail - 7)); fi
    if [ "$avail" -ge 7 ];  then SHOW_TPS=true;   avail=$((avail - 7)); fi
    if [ "$avail" -ge 8 ];  then SHOW_CACHE=true;  avail=$((avail - 8)); fi
    if $HAS_TAGS && [ "$avail" -ge $((TAG_COL_W + 2)) ]; then SHOW_TAG=true; fi

    tput cup 0 0 2>/dev/null || true
    tput ed 2>/dev/null || true

    # Header.
    local title=" ${BOLD}${DASHBOARD_TITLE}${RESET}"
    local title_len=${#DASHBOARD_TITLE}
    local right="${DIM}uptime: ${uptime_str}${RESET}"
    printf "%b%*s%b\n" "$title" $((TERM_COLS - title_len - 2 - ${#uptime_str} - 10)) "" "$right"
    if [ -n "$GIT_BRANCH" ]; then
        printf " ${DIM}config: %s | branch: %s${RESET}\n" "$CONFIG_LABEL" "$GIT_BRANCH"
    else
        printf " ${DIM}config: %s${RESET}\n" "$CONFIG_LABEL"
    fi
    printf " ${DIM}agents: %s — %s${RESET}\n" "$NUM_AGENTS" "$MODEL_SUMMARY"
    echo ""

    emit_header

    local running_count=0 exited_count=0
    local total_cost=0 total_in=0 total_out=0 total_cache=0 total_dur=0 total_api_ms=0 total_turns=0

    for i in $(seq 1 "$NUM_AGENTS"); do
        local name="${IMAGE_NAME}-${i}"

        local state
        state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "not found")

        local model="unknown" effort="" auth_mode="" agent_tag="" agent_driver=""
        if [ "$state" != "not found" ]; then
            local env_dump
            env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
                "$name" 2>/dev/null || true)
            model=$(printf '%s' "$env_dump" | grep '^SWARM_MODEL=' | head -1 | cut -d= -f2- || true)
            model="${model:-unknown}"
            effort=$(printf '%s' "$env_dump" | grep '^SWARM_EFFORT=' | head -1 | cut -d= -f2- || true)
            agent_tag=$(printf '%s' "$env_dump" | grep '^SWARM_TAG=' | head -1 | cut -d= -f2- || true)
            agent_driver=$(printf '%s' "$env_dump" | grep '^SWARM_DRIVER=' | head -1 | cut -d= -f2- || true)
            auth_mode=$(printf '%s' "$env_dump" | grep '^SWARM_AUTH_MODE=' | head -1 | cut -d= -f2- || true)
        fi

        local model_label
        model_label=$(format_model "$model" "$effort")

        local agent_stats a_cost a_in a_out a_cache a_dur a_api_ms a_turns
        agent_stats=$(read_agent_stats "$name" "$i")
        a_cost=$(echo "$agent_stats" | awk '{print $1}')
        a_in=$(echo "$agent_stats" | awk '{print $2}')
        a_out=$(echo "$agent_stats" | awk '{print $3}')
        a_cache=$(echo "$agent_stats" | awk '{print $4}')
        a_dur=$(echo "$agent_stats" | awk '{print $5}')
        a_api_ms=$(echo "$agent_stats" | awk '{print $6}')
        a_turns=$(echo "$agent_stats" | awk '{print $7}')

        total_cost=$(echo "$total_cost + $a_cost" | bc)
        total_in=$((total_in + a_in))
        total_out=$((total_out + a_out))
        total_cache=$((total_cache + a_cache))
        total_dur=$((total_dur + a_dur))
        total_api_ms=$((total_api_ms + a_api_ms))
        total_turns=$((total_turns + a_turns))

        local idle_state="" retry_state=""
        if [ "$state" = "running" ]; then
            idle_state=$(read_idle_state "$name" "$i")
            retry_state=$(read_retry_state "$name" "$i")
        fi

        local status_text status_color
        case "$state" in
            running)
                running_count=$((running_count + 1))
                if [ -n "$retry_state" ]; then
                    local _rw _rm
                    _rw=${retry_state%%/*}; _rm=${retry_state##*/}
                    status_text="retry $(format_duration_short "$_rw")/$(format_duration_short "$_rm")"
                    status_color="$YELLOW"
                elif [ -n "$idle_state" ]; then
                    status_text="idle ${idle_state}"
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

        emit_row "$i" "$model_label" "$(short_driver "$agent_driver")" "$auth_mode" \
            "$status_color" "$status_text" \
            "$(format_cost "$a_cost")" \
            "$(format_tokens "$a_in")/$(format_tokens "$a_out")" \
            "$(format_tokens "$a_cache")" \
            "$a_turns" "$(format_tps "$a_out" "$a_api_ms")" \
            "$(format_duration_ms "$a_dur")" "$agent_tag"
    done

    # Post-process row (if container exists).
    local pp_name="${IMAGE_NAME}-post"
    local pp_state
    pp_state=$(docker inspect -f '{{.State.Status}}' "$pp_name" 2>/dev/null || true)
    if [ -n "$pp_state" ] && [ "$pp_state" != "none" ]; then
        local pp_model pp_effort pp_auth_mode pp_tag pp_driver
        local pp_env_dump
        pp_env_dump=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
            "$pp_name" 2>/dev/null || true)
        pp_model=$(printf '%s' "$pp_env_dump" | grep '^SWARM_MODEL=' | head -1 | cut -d= -f2- || true)
        pp_model="${pp_model:-unknown}"
        pp_effort=$(printf '%s' "$pp_env_dump" | grep '^SWARM_EFFORT=' | head -1 | cut -d= -f2- || true)
        pp_tag=$(printf '%s' "$pp_env_dump" | grep '^SWARM_TAG=' | head -1 | cut -d= -f2- || true)
        pp_driver=$(printf '%s' "$pp_env_dump" | grep '^SWARM_DRIVER=' | head -1 | cut -d= -f2- || true)
        pp_auth_mode=$(printf '%s' "$pp_env_dump" | grep '^SWARM_AUTH_MODE=' | head -1 | cut -d= -f2- || true)

        local pp_model_label
        pp_model_label=$(format_model "$pp_model" "$pp_effort")

        local pp_stats pp_cost pp_in pp_out pp_cache pp_dur pp_api_ms pp_turns
        pp_stats=$(read_agent_stats "$pp_name" "post")
        pp_cost=$(echo "$pp_stats" | awk '{print $1}')
        pp_in=$(echo "$pp_stats" | awk '{print $2}')
        pp_out=$(echo "$pp_stats" | awk '{print $3}')
        pp_cache=$(echo "$pp_stats" | awk '{print $4}')
        pp_dur=$(echo "$pp_stats" | awk '{print $5}')
        pp_api_ms=$(echo "$pp_stats" | awk '{print $6}')
        pp_turns=$(echo "$pp_stats" | awk '{print $7}')

        total_cost=$(echo "$total_cost + $pp_cost" | bc)
        total_in=$((total_in + pp_in))
        total_out=$((total_out + pp_out))
        total_dur=$((total_dur + pp_dur))
        total_api_ms=$((total_api_ms + pp_api_ms))
        total_turns=$((total_turns + pp_turns))

        local pp_status_color
        case "$pp_state" in
            running) pp_status_color="$GREEN" ;;
            exited)  pp_status_color="$RED" ;;
            *)       pp_status_color="$DIM" ;;
        esac

        printf "  ${DIM}%s${RESET}\n" "$(printf '%.0s·' $(seq 1 $((TERM_COLS - 4))))"
        emit_row "PP" "$pp_model_label" "$(short_driver "$pp_driver")" "$pp_auth_mode" \
            "$pp_status_color" "$pp_state" \
            "$(format_cost "$pp_cost")" \
            "$(format_tokens "$pp_in")/$(format_tokens "$pp_out")" \
            "$(format_tokens "$pp_cache")" \
            "$pp_turns" "$(format_tps "$pp_out" "$pp_api_ms")" \
            "$(format_duration_ms "$pp_dur")" "$pp_tag"
    fi

    # Totals row.
    printf "  ${DIM}%s${RESET}\n" "$(printf '%.0s─' $(seq 1 $((TERM_COLS - 4))))"
    local t_cost_str t_inout_str t_cache_str t_tps_str t_dur_str
    t_cost_str=$(format_cost "$total_cost")
    t_inout_str="$(format_tokens "$total_in")/$(format_tokens "$total_out")"
    t_cache_str=$(format_tokens "$total_cache")
    t_tps_str=$(format_tps "$total_out" "$total_api_ms")
    t_dur_str=$(format_duration_ms "$total_dur")
    emit_row "" "Total" "" "" \
        "" "" "$t_cost_str" "$t_inout_str" "$t_cache_str" \
        "$total_turns" "$t_tps_str" "$t_dur_str" "" "bold"

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
        # shellcheck disable=SC2059
        printf " ${DIM}(bare repo not found -- are agents running?)${RESET}\n"
    fi

    echo ""

    if [ "$running_count" -eq 0 ] && [ "$exited_count" -gt 0 ]; then
        printf " ${BOLD}${GREEN}Swarm complete${RESET} -- all %s agents exited.\n" "$exited_count"
        echo ""
    fi

    # Help bar.
    # shellcheck disable=SC2059
    printf " ${DIM}[q]${RESET} quit"
    # shellcheck disable=SC2059
    printf "  ${DIM}[1-9]${RESET} logs"
    # shellcheck disable=SC2059
    printf "  ${DIM}[h]${RESET} harvest"
    # shellcheck disable=SC2059
    printf "  ${DIM}[s]${RESET} stop all"
    # shellcheck disable=SC2059
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
                if ! docker inspect -f '{{.State.Running}}' "${IMAGE_NAME}-${key}" 2>/dev/null | grep -q true; then
                    echo ""
                    read -rp "Press Enter to return to dashboard..." _
                fi
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
                    if docker stop "${IMAGE_NAME}-${i}" 2>/dev/null; then
                        echo "  stopped ${IMAGE_NAME}-${i}"
                    fi
                done
                echo ""
                read -rp "Press Enter to return to dashboard..." _
                enter_alt_screen
                ;;
            p|P)
                leave_alt_screen
                _pp_configured=false
                if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
                    _pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE" 2>/dev/null)
                    [ -n "$_pp_prompt" ] && _pp_configured=true
                fi
                if ! $_pp_configured; then
                    echo "(post-processing not configured -- add post_process to swarm.json)"
                    echo ""
                    read -rp "Press Enter to return to dashboard..." _
                    enter_alt_screen
                    continue
                fi
                echo "--- Stopping agents ---"
                for i in $(seq 1 "$NUM_AGENTS"); do
                    docker stop "${IMAGE_NAME}-${i}" 2>/dev/null || true
                done
                echo "--- Starting post-processing ---"
                "$SWARM_DIR/launch.sh" post-process || \
                    echo "(post-processing failed)"
                echo ""
                read -rp "Press Enter to return to dashboard..." _
                enter_alt_screen
                ;;
        esac
    fi
done
