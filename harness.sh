#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop claude sessions.

AGENT_ID="${AGENT_ID:-unnamed}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
AGENT_PROMPT="${AGENT_PROMPT:?AGENT_PROMPT is required.}"
AGENT_SETUP="${AGENT_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@claude-swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

echo "[harness:${AGENT_ID}] Starting (model=${CLAUDE_MODEL}, prompt=${AGENT_PROMPT})..."

if [ ! -d "/workspace/.git" ]; then
    echo "[harness:${AGENT_ID}] Cloning upstream to /workspace..."
    git clone /upstream /workspace
    cd /workspace

    # Point submodule URLs at local mirrors before init.
    git config --file .gitmodules --get-regexp 'submodule\..*\.path' | \
    while read -r key path; do
        name="${key#submodule.}"
        name="${name%.path}"
        git config "submodule.${name}.url" "/mirrors/${name}"
    done
    git submodule update --init --recursive

    git checkout agent-work

    # Run project-specific setup if provided.
    if [ -n "$AGENT_SETUP" ] && [ -f "$AGENT_SETUP" ]; then
        echo "[harness:${AGENT_ID}] Running ${AGENT_SETUP}..."
        bash "$AGENT_SETUP"
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
           --model "$CLAUDE_MODEL" &> "$LOGFILE" || true

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
