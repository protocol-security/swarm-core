#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop claude sessions.

AGENT_ID="${AGENT_ID:-unnamed}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
AGENT_PROMPT="${AGENT_PROMPT:?AGENT_PROMPT is required.}"
AGENT_SETUP="${AGENT_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"
STATS_FILE="agent_logs/stats_agent_${AGENT_ID}.tsv"

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@claude-swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

echo "[harness:${AGENT_ID}] Starting (model=${CLAUDE_MODEL}, prompt=${AGENT_PROMPT})..."

if [ ! -d "/workspace/.git" ]; then
    echo "[harness:${AGENT_ID}] Cloning upstream to /workspace..."
    git clone /upstream /workspace
    cd /workspace

    # Init only submodules whose mirrors were mounted into the
    # container. Client submodules without mirrors keep their
    # upstream URLs and are left for the agent to init on demand.
    if [ -f .gitmodules ]; then
        git config --file .gitmodules --get-regexp 'submodule\..*\.path' | \
        while read -r key path; do
            name="${key#submodule.}"
            name="${name%.path}"
            if [ -d "/mirrors/${name}" ]; then
                git config "submodule.${name}.url" "/mirrors/${name}"
                git submodule update --init -- "$path"
            fi
        done
    fi

    git checkout agent-work

    # Run project-specific setup if provided.
    if [ -n "$AGENT_SETUP" ] && [ -f "$AGENT_SETUP" ]; then
        echo "[harness:${AGENT_ID}] Running ${AGENT_SETUP}..."
        sudo bash "$AGENT_SETUP"
    fi

    mkdir -p agent_logs
    echo "[harness:${AGENT_ID}] Setup complete."
fi

cd /workspace

IDLE_COUNT=0

while true; do
    # Reset to latest. Do not re-init submodules; setup changes would be lost.
    git fetch origin
    git reset --hard origin/agent-work

    BEFORE=$(git rev-parse origin/agent-work)
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="agent_logs/agent_${AGENT_ID}_${COMMIT}_$(date +%s).log"
    mkdir -p agent_logs

    echo "[harness:${AGENT_ID}] Starting session at ${COMMIT}..."

    claude --dangerously-skip-permissions \
           -p "$(cat "$AGENT_PROMPT")" \
           --model "$CLAUDE_MODEL" \
           --output-format json > "$LOGFILE" 2>"${LOGFILE}.err" || true

    # Extract usage stats from JSON output.
    cost=$(jq -r '.total_cost_usd // 0' "$LOGFILE" 2>/dev/null || echo 0)
    dur=$(jq -r '.duration_ms // 0' "$LOGFILE" 2>/dev/null || echo 0)
    api_ms=$(jq -r '.duration_api_ms // 0' "$LOGFILE" 2>/dev/null || echo 0)
    turns=$(jq -r '.num_turns // 0' "$LOGFILE" 2>/dev/null || echo 0)
    tok_in=$(jq -r '.usage.input_tokens // 0' "$LOGFILE" 2>/dev/null || echo 0)
    tok_out=$(jq -r '.usage.output_tokens // 0' "$LOGFILE" 2>/dev/null || echo 0)
    cache_rd=$(jq -r '.usage.cache_read_input_tokens // 0' "$LOGFILE" 2>/dev/null || echo 0)
    cache_cr=$(jq -r '.usage.cache_creation_input_tokens // 0' "$LOGFILE" 2>/dev/null || echo 0)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns" \
        >> "$STATS_FILE"
    echo "[harness:${AGENT_ID}] Session cost=\$${cost} tokens=${tok_in}/${tok_out} turns=${turns} duration=${dur}ms"

    git fetch origin
    AFTER=$(git rev-parse origin/agent-work)

    if [ "$BEFORE" = "$AFTER" ]; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        echo "[harness:${AGENT_ID}] No commits pushed (idle ${IDLE_COUNT}/${MAX_IDLE})."
        if [ "$IDLE_COUNT" -ge "$MAX_IDLE" ]; then
            echo "[harness:${AGENT_ID}] Idle limit reached, exiting."
            exit 0
        fi
    else
        IDLE_COUNT=0
        echo "[harness:${AGENT_ID}] Session ended. Restarting..."
    fi
done
