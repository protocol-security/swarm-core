#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Gemini CLI
# Implements the role interface for Google's Gemini CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "gemini-2.5-pro"; }
agent_name()    { echo "Gemini CLI"; }
agent_cmd()     { echo "gemini"; }

agent_version() {
    local v
    v=$(gemini --version 2>/dev/null || echo "unknown")
    echo "${v%% *}"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    # Gemini CLI reads GEMINI.md from the workspace root for context
    # (analogous to Claude Code's --append-system-prompt-file).
    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        cp "$append_file" /workspace/GEMINI.md 2>/dev/null || true
    fi

    gemini \
        -p "$prompt_text" \
        -m "$model" \
        -y \
        --output-format stream-json \
        2>"${logfile}.err" \
        | stdbuf -oL tee "$logfile"
}

# Write agent-specific settings files into the workspace.
agent_settings() {
    local workspace="$1"
    mkdir -p "${workspace}/.gemini"
    cat > "${workspace}/.gemini/settings.json" <<'SETTINGS'
{"toolApprovalMode":"auto"}
SETTINGS
}

# Extract stats from a Gemini CLI stream-json result event.
# The result event schema differs from Claude Code:
#   { "type": "result", "stats": { "input_tokens": N, "output_tokens": N,
#     "cached": N, "duration_ms": N, "tool_calls": N } }
agent_extract_stats() {
    local logfile="$1"
    local RESULT_LINE
    RESULT_LINE=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null | tail -1 || true)
    if [ -z "$RESULT_LINE" ]; then
        printf "0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi
    local cost tok_in tok_out cached dur tool_calls
    cost=0
    tok_in=$(echo "$RESULT_LINE" | jq -r '.stats.input_tokens // 0' 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(echo "$RESULT_LINE" | jq -r '.stats.output_tokens // 0' 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cached=$(echo "$RESULT_LINE" | jq -r '.stats.cached // 0' 2>/dev/null || true)
    cached="${cached:-0}"
    dur=$(echo "$RESULT_LINE" | jq -r '.stats.duration_ms // 0' 2>/dev/null || true)
    dur="${dur:-0}"
    tool_calls=$(echo "$RESULT_LINE" | jq -r '.stats.tool_calls // 0' 2>/dev/null || true)
    tool_calls="${tool_calls:-0}"
    # Map to standard 8-field format:
    # cost, tok_in, tok_out, cache_rd, cache_cr, dur, api_ms, turns
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$cost" "$tok_in" "$tok_out" "$cached" "0" "$dur" "$dur" "$tool_calls"
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
select(.type == "tool_call") |
if   .name == "shell"      then "\(prefix) Shell: " + ((.input // "") | first_line | truncate(80)) + reset
elif .name == "read_file"   then "\(prefix) Read "  + (.file_path // "") + reset
elif .name == "write_file"  then "\(prefix) Write " + (.file_path // "") + reset
elif .name == "edit_file"   then "\(prefix) Edit "  + (.file_path // "") + reset
elif .name == "glob"        then "\(prefix) Glob "  + (.pattern // "") + reset
elif .name == "grep"        then "\(prefix) Grep "  + (.pattern // "") + reset
else "\(prefix) " + (.name // "unknown") + reset
end
JQ
}

# Detect fatal errors in a Gemini CLI session log.
agent_detect_fatal() {
    local logfile="$1"
    local error_line
    error_line=$(grep '"type"[[:space:]]*:[[:space:]]*"error"' "$logfile" 2>/dev/null | head -1 || true)
    if [ -n "$error_line" ]; then
        local msg
        msg=$(echo "$error_line" | jq -r '.message // .error // "unknown error"' 2>/dev/null || true)
        echo "$msg"
    fi
}

# Gemini CLI has no effort flag.
agent_docker_env() { :; }

# Resolve auth credentials and emit Docker -e flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: GEMINI_API_KEY, OPENROUTER_API_KEY
agent_docker_auth() {
    local api_key="$1" auth_token="$2" auth_mode="$3" base_url="$4"

    local label=""
    if [ -n "$auth_token" ]; then
        printf -- '-e\nOPENROUTER_API_KEY=%s\n' "$auth_token"
        [ -n "$base_url" ] && printf -- '-e\nGEMINI_API_BASE=%s\n' "$base_url"
        label="openrouter"
    else
        local key="${api_key:-${GEMINI_API_KEY:-}}"
        if [ -n "$key" ]; then
            printf -- '-e\nGEMINI_API_KEY=%s\n' "$key"
            label="key"
        fi
    fi

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g @google/gemini-cli
INSTALL
}
