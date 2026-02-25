#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop claude sessions.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Container entrypoint for claude-swarm agents. Not intended to
be run directly -- launched automatically inside Docker by
launch.sh.

Clones the bare repo, runs optional setup, then loops claude
sessions until the agent is idle for MAX_IDLE cycles.

Required environment:
  AGENT_PROMPT   Path to prompt file (relative to repo root).
  CLAUDE_MODEL   Model to use for claude sessions.

Optional environment:
  AGENT_ID       Agent identifier (default: unnamed).
  AGENT_SETUP    Setup script to run before first session.
  MAX_IDLE       Idle sessions before exit (default: 3).
  INJECT_GIT_RULES  Inject git coordination rules (default: true).
HELP
    exit 0
fi

AGENT_ID="${AGENT_ID:-unnamed}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
AGENT_PROMPT="${AGENT_PROMPT:?AGENT_PROMPT is required.}"
AGENT_SETUP="${AGENT_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"
INJECT_GIT_RULES="${INJECT_GIT_RULES:-true}"
STATS_FILE="agent_logs/stats_agent_${AGENT_ID}.tsv"

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@claude-swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# Capture CLI version once for the prepare-commit-msg hook.
CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
CLAUDE_VERSION="${CLAUDE_VERSION%% *}"
export CLAUDE_VERSION

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

    # Disable Claude Code's Co-Authored-By trailer; the hook-injected
    # trailers (Model/Agent) are the single source of truth.
    mkdir -p .claude
    printf '{"attribution":{"commit":"","pr":""}}\n' > .claude/settings.local.json

    # Install prepare-commit-msg hook to append provenance trailers.
    # Fires on every commit including git commit -m.
    SWARM_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
    export SWARM_VERSION
    mkdir -p .git/hooks
    cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: claude-swarm %s, Claude Code %s\n' \
        "$CLAUDE_MODEL" "$SWARM_VERSION" "$CLAUDE_VERSION" >> "$1"
fi
HOOK
    chmod +x .git/hooks/prepare-commit-msg

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

    APPEND_ARGS=()
    if [ "$INJECT_GIT_RULES" = "true" ] && [ -f /agent-system-prompt.md ]; then
        APPEND_ARGS+=(--append-system-prompt-file /agent-system-prompt.md)
    fi

    claude --dangerously-skip-permissions \
           -p "$(cat "$AGENT_PROMPT")" \
           --model "$CLAUDE_MODEL" \
           "${APPEND_ARGS[@]+"${APPEND_ARGS[@]}"}" \
           --output-format json > "$LOGFILE" 2>"${LOGFILE}.err" || true

    # Extract usage stats from JSON output.
    cost=$(jq -r '.total_cost_usd // 0' "$LOGFILE" 2>/dev/null || true)
    cost="${cost:-0}"
    dur=$(jq -r '.duration_ms // 0' "$LOGFILE" 2>/dev/null || true)
    dur="${dur:-0}"
    api_ms=$(jq -r '.duration_api_ms // 0' "$LOGFILE" 2>/dev/null || true)
    api_ms="${api_ms:-0}"
    turns=$(jq -r '.num_turns // 0' "$LOGFILE" 2>/dev/null || true)
    turns="${turns:-0}"
    tok_in=$(jq -r '.usage.input_tokens // 0' "$LOGFILE" 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(jq -r '.usage.output_tokens // 0' "$LOGFILE" 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cache_rd=$(jq -r '.usage.cache_read_input_tokens // 0' "$LOGFILE" 2>/dev/null || true)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(jq -r '.usage.cache_creation_input_tokens // 0' "$LOGFILE" 2>/dev/null || true)
    cache_cr="${cache_cr:-0}"
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
