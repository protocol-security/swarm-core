#!/bin/bash
set -euo pipefail

# Interactive setup wizard for claude-swarm.
# Produces a swarm.json config file.
# Uses whiptail for dialogs; falls back to read-based prompts.

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
OUTPUT="$REPO_ROOT/swarm.json"
USE_WHIPTAIL=false

if command -v whiptail &>/dev/null; then
    USE_WHIPTAIL=true
fi

# ---- Dialog helpers ----

msg() {
    if $USE_WHIPTAIL; then
        whiptail --title "claude-swarm" --msgbox "$1" 10 60
    else
        echo ""
        echo "$1"
        echo ""
    fi
}

input() {
    local title="$1" default="$2"
    if $USE_WHIPTAIL; then
        whiptail --title "claude-swarm" --inputbox "$title" 10 60 "$default" 3>&1 1>&2 2>&3 || echo "$default"
    else
        local val
        read -rp "$title [$default]: " val
        echo "${val:-$default}"
    fi
}

password() {
    local title="$1"
    if $USE_WHIPTAIL; then
        whiptail --title "claude-swarm" --passwordbox "$title" 10 60 3>&1 1>&2 2>&3 || echo ""
    else
        local val
        read -rsp "$title: " val
        echo ""
        echo "$val"
    fi
}

yesno() {
    local title="$1"
    if $USE_WHIPTAIL; then
        whiptail --title "claude-swarm" --yesno "$title" 10 60 && return 0 || return 1
    else
        local val
        read -rp "$title [Y/n]: " val
        case "$val" in
            [Nn]*) return 1 ;;
            *)     return 0 ;;
        esac
    fi
}

# ---- Gather settings ----

echo "claude-swarm setup wizard"
echo "========================="
echo ""

# 1. API key.
API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -n "$API_KEY" ]; then
    echo "ANTHROPIC_API_KEY detected in environment (${#API_KEY} chars)."
else
    API_KEY=$(password "Enter your ANTHROPIC_API_KEY")
    if [ -z "$API_KEY" ]; then
        echo "ERROR: API key is required." >&2
        exit 1
    fi
    echo ""
    echo "Tip: export ANTHROPIC_API_KEY before running launch.sh."
fi

# 2. Prompt file.
PROMPT_PATH=$(input "Path to prompt file (relative to repo root)" "")
if [ -z "$PROMPT_PATH" ]; then
    echo "ERROR: Prompt file is required." >&2
    exit 1
fi
if [ ! -f "$REPO_ROOT/$PROMPT_PATH" ]; then
    echo "WARNING: ${PROMPT_PATH} not found in repo root."
    if ! yesno "Continue anyway?"; then
        exit 1
    fi
fi

# 3. Agent groups.
AGENTS_JSON="[]"
GROUP_NUM=0

while true; do
    GROUP_NUM=$((GROUP_NUM + 1))
    echo ""
    echo "--- Agent group ${GROUP_NUM} ---"

    MODEL=$(input "Model name" "claude-opus-4-6")
    COUNT=$(input "Number of agents with this model" "1")

    AGENT_OBJ="{\"count\": ${COUNT}, \"model\": \"${MODEL}\""

    if yesno "Custom endpoint for this group (e.g. OpenRouter)?"; then
        BASE_URL=$(input "Base URL" "https://openrouter.ai/api/v1")
        GROUP_KEY=$(password "API key for this endpoint")
        AGENT_OBJ+=", \"base_url\": \"${BASE_URL}\""
        if [ -n "$GROUP_KEY" ]; then
            AGENT_OBJ+=", \"api_key\": \"${GROUP_KEY}\""
        fi
    fi

    AGENT_OBJ+="}"
    AGENTS_JSON=$(echo "$AGENTS_JSON" | jq --argjson obj "$AGENT_OBJ" '. + [$obj]')

    TOTAL=$(echo "$AGENTS_JSON" | jq '[.[].count] | add')
    echo ""
    echo "Total agents so far: ${TOTAL}"

    if ! yesno "Add another agent group?"; then
        break
    fi
done

# 4. Advanced settings.
SETUP_PATH=""
MAX_IDLE=3
GIT_NAME="swarm-agent"
GIT_EMAIL="agent@claude-swarm.local"

if yesno "Configure advanced settings (setup script, idle limit, git user)?"; then
    SETUP_PATH=$(input "Setup script path (blank to skip)" "")
    MAX_IDLE=$(input "Max idle sessions before exit" "3")
    GIT_NAME=$(input "Git user name for agent commits" "swarm-agent")
    GIT_EMAIL=$(input "Git user email for agent commits" "agent@claude-swarm.local")
fi

# 5. Post-processing.
POST_PROMPT=""
POST_MODEL=""

if yesno "Configure post-processing (runs after all agents finish)?"; then
    POST_PROMPT=$(input "Post-processing prompt file" "")
    POST_MODEL=$(input "Model for post-processing" "claude-opus-4-6")
fi

# ---- Build config ----

CONFIG=$(jq -n \
    --arg prompt "$PROMPT_PATH" \
    --arg setup "$SETUP_PATH" \
    --argjson max_idle "$MAX_IDLE" \
    --arg git_name "$GIT_NAME" \
    --arg git_email "$GIT_EMAIL" \
    --argjson agents "$AGENTS_JSON" \
    '{
        prompt: $prompt,
        max_idle: $max_idle,
        git_user: { name: $git_name, email: $git_email },
        agents: $agents
    }
    | if $setup != "" then .setup = $setup else . end')

if [ -n "$POST_PROMPT" ]; then
    CONFIG=$(echo "$CONFIG" | jq \
        --arg pp_prompt "$POST_PROMPT" \
        --arg pp_model "$POST_MODEL" \
        '. + { post_process: { prompt: $pp_prompt, model: $pp_model } }')
fi

# ---- Review and write ----

echo ""
echo "=== Generated config ==="
echo "$CONFIG" | jq .
echo ""

TOTAL=$(echo "$CONFIG" | jq '[.agents[].count] | add')
echo "Total agents: ${TOTAL}"
echo "Output: ${OUTPUT}"
echo ""

if yesno "Write ${OUTPUT}?"; then
    echo "$CONFIG" | jq . > "$OUTPUT"
    echo "Config written to ${OUTPUT}"
    echo ""
    if yesno "Launch swarm now?"; then
        export ANTHROPIC_API_KEY="$API_KEY"
        "$SWARM_DIR/launch.sh" start
    fi
else
    echo "Aborted."
fi
