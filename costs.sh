#!/bin/bash
set -euo pipefail

# Print cost and usage summary for all swarm agents.
# Usage: ./costs.sh [--json]

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
IMAGE_NAME="${PROJECT}-agent"
JSON_MODE=false

if [ "${1:-}" = "--json" ]; then
    JSON_MODE=true
fi

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
        cache += $5; dur += $7; turns += $9; sessions++
    } END {
        printf "%s %d %d %d %d %d %d\n",
            cost, tok_in, tok_out, cache, dur, turns, sessions
    }' "$tmpf"
    rm -f "$tmpf"
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

containers=$(docker ps -a --filter "name=${IMAGE_NAME}-" \
    --format '{{.Names}}' 2>/dev/null | sort -V || true)

if [ -z "$containers" ]; then
    echo "No swarm containers found." >&2
    exit 1
fi

total_cost=0
total_in=0
total_out=0
total_cache=0
total_dur=0
total_turns=0
total_sessions=0
json_agents="["

if ! $JSON_MODE; then
    printf "%-4s %-20s %9s %10s %10s %6s %8s %8s\n" \
        "#" "Model" "Cost" "Input" "Output" "Cache" "Turns" "Time"
    printf "%s\n" "$(printf '%.0s─' $(seq 1 82))"
fi

first_json=true

for cname in $containers; do
    agent_id="${cname##*-}"
    state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "?")
    model=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
        "$cname" 2>/dev/null | grep '^CLAUDE_MODEL=' | head -1 | cut -d= -f2- || true)
    model="${model:-unknown}"
    short="${model/claude-/}"

    stats=$(read_agent_stats "$cname" "$agent_id")
    a_cost=$(echo "$stats" | awk '{print $1}')
    a_in=$(echo "$stats" | awk '{print $2}')
    a_out=$(echo "$stats" | awk '{print $3}')
    a_cache=$(echo "$stats" | awk '{print $4}')
    a_dur=$(echo "$stats" | awk '{print $5}')
    a_turns=$(echo "$stats" | awk '{print $6}')
    a_sessions=$(echo "$stats" | awk '{print $7}')

    total_cost=$(echo "$total_cost + $a_cost" | bc)
    total_in=$((total_in + a_in))
    total_out=$((total_out + a_out))
    total_cache=$((total_cache + a_cache))
    total_dur=$((total_dur + a_dur))
    total_turns=$((total_turns + a_turns))
    total_sessions=$((total_sessions + a_sessions))

    dur_s=$((a_dur / 1000))

    if $JSON_MODE; then
        $first_json || json_agents="${json_agents},"
        first_json=false
        id_json="${agent_id}"
        if ! [[ "$agent_id" =~ ^[0-9]+$ ]]; then
            id_json="\"${agent_id}\""
        fi
        json_agents="${json_agents}{\"id\":${id_json},\"model\":\"${model}\",\"state\":\"${state}\","
        json_agents="${json_agents}\"cost_usd\":${a_cost},\"input_tokens\":${a_in},"
        json_agents="${json_agents}\"output_tokens\":${a_out},\"cache_read_tokens\":${a_cache},"
        json_agents="${json_agents}\"duration_ms\":${a_dur},\"turns\":${a_turns},\"sessions\":${a_sessions}}"
    else
        printf "%-4s %-20s \$%8.4f %10s %10s %6s %8s %7ds\n" \
            "$agent_id" "$short" "$a_cost" \
            "$(format_tokens "$a_in")" "$(format_tokens "$a_out")" \
            "$(format_tokens "$a_cache")" "$a_turns" "$dur_s"
    fi
done

json_agents="${json_agents}]"

if $JSON_MODE; then
    total_cost_json=$(printf '%.6f' "$total_cost")
    printf '{"agents":%s,"total":{"cost_usd":%s,"input_tokens":%d,"output_tokens":%d,"cache_read_tokens":%d,"duration_ms":%d,"turns":%d,"sessions":%d}}\n' \
        "$json_agents" "$total_cost_json" "$total_in" "$total_out" \
        "$total_cache" "$total_dur" "$total_turns" "$total_sessions"
else
    printf "%s\n" "$(printf '%.0s─' $(seq 1 82))"
    t_dur_s=$((total_dur / 1000))
    printf "%-4s %-20s \$%8.4f %10s %10s %6s %8s %7ds\n" \
        "" "TOTAL" "$total_cost" \
        "$(format_tokens "$total_in")" "$(format_tokens "$total_out")" \
        "$(format_tokens "$total_cache")" "$total_turns" "$t_dur_s"
    printf "\n%d agents, %d sessions, \$%.4f total cost\n" \
        "$(echo "$containers" | wc -l)" "$total_sessions" "$total_cost"
fi
