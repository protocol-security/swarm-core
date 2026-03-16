#!/bin/bash
# Agent driver: Claude Code
# Implements the role interface for Anthropic's Claude Code CLI.

agent_name()    { echo "Claude Code"; }
agent_cmd()     { echo "claude"; }

agent_version() {
    local v
    v=$(claude --version 2>/dev/null || echo "unknown")
    echo "${v%% *}"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    local -a args=(
        --dangerously-skip-permissions
        -p "$prompt_text"
        --model "$model"
        --output-format stream-json
        --verbose
    )
    if [ -n "$append_file" ]; then
        args+=(--append-system-prompt-file "$append_file")
    fi

    claude "${args[@]}" 2>"${logfile}.err" \
        | stdbuf -oL tee "$logfile"
}

# Write agent-specific settings files into the workspace.
# Disables Co-Authored-By, attribution header, and telemetry.
agent_settings() {
    local workspace="$1"
    mkdir -p "${workspace}/.claude"
    cat > "${workspace}/.claude/settings.local.json" <<'SETTINGS'
{"attribution":{"commit":"","pr":""},"env":{"CLAUDE_CODE_ATTRIBUTION_HEADER":"0","CLAUDE_CODE_ENABLE_TELEMETRY":"0","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"}}
SETTINGS
}

# Extract stats from a session log (JSONL or plain JSON).
# Prints: cost tok_in tok_out cache_rd cache_cr dur api_ms turns
agent_extract_stats() {
    local logfile="$1"
    local RESULT_LINE
    RESULT_LINE=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null | tail -1 || true)
    if [ -z "$RESULT_LINE" ]; then
        RESULT_LINE=$(cat "$logfile" 2>/dev/null || true)
    fi
    local cost dur api_ms turns tok_in tok_out cache_rd cache_cr
    cost=$(echo "$RESULT_LINE" | jq -r '.total_cost_usd // 0' 2>/dev/null || true)
    cost="${cost:-0}"
    dur=$(echo "$RESULT_LINE" | jq -r '.duration_ms // 0' 2>/dev/null || true)
    dur="${dur:-0}"
    api_ms=$(echo "$RESULT_LINE" | jq -r '.duration_api_ms // 0' 2>/dev/null || true)
    api_ms="${api_ms:-0}"
    turns=$(echo "$RESULT_LINE" | jq -r '.num_turns // 0' 2>/dev/null || true)
    turns="${turns:-0}"
    tok_in=$(echo "$RESULT_LINE" | jq -r '.usage.input_tokens // 0' 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(echo "$RESULT_LINE" | jq -r '.usage.output_tokens // 0' 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cache_rd=$(echo "$RESULT_LINE" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || true)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(echo "$RESULT_LINE" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || true)
    cache_cr="${cache_cr:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$cost" "$tok_in" "$tok_out" "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns"
}

# Return the jq program for parsing activity from stream-json.
agent_activity_jq() {
    cat <<'JQ'
def truncate(n):
  if length > n then .[:n-3] + "..." else . end;

def first_line:
  split("\n")[0] // .;

def ts:
  now | strftime("%H:%M:%S");

def prefix:
  "\u001b[33m\(ts)   agent[\($id)]";

def reset:
  "\u001b[0m";

fromjson? // empty |
select(.type == "assistant") |
.message.content[]? |
select(.type == "tool_use") |
if   .name == "Bash"  then "\(prefix) Shell: " + ((.input.command // "") | first_line | truncate(80)) + reset
elif .name == "Read"  then "\(prefix) Read "  + (.input.file_path // .input.path // "") + reset
elif .name == "Write" then "\(prefix) Write " + (.input.file_path // .input.path // "") + reset
elif .name == "Edit"  then "\(prefix) Edit "  + (.input.file_path // .input.path // "") + reset
elif .name == "MultiEdit" then "\(prefix) MultiEdit " + (.input.file_path // .input.path // "") + reset
elif .name == "Glob"  then "\(prefix) Glob "  + (.input.pattern // "") + reset
elif .name == "Grep"  then "\(prefix) Grep "  + (.input.pattern // "") + reset
elif .name == "Task"  then "\(prefix) Task: " + ((.input.description // .input.prompt // "") | first_line | truncate(60)) + reset
else "\(prefix) " + .name + reset
end
JQ
}

# Map generic config to agent-specific Docker env vars.
# Args: <api_key> <effort>
# Prints -e flags for docker run.
agent_docker_env() {
    local api_key="${1:-}" effort="${2:-}"
    [ -n "$api_key" ] && printf -- '-e\nANTHROPIC_API_KEY=%s\n' "$api_key"
    [ -n "$effort" ]  && printf -- '-e\nCLAUDE_CODE_EFFORT_LEVEL=%s\n' "$effort"
}

# Dockerfile fragment to install this agent's CLI.
agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh \
    && rm /tmp/claude-install.sh
ENV PATH="/home/agent/.local/bin:${PATH}"
INSTALL
}
