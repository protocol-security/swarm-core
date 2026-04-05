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
if .type == "thought" then
  "\(prefix) Think: " + ((.content // "") | first_line | truncate(80)) + reset
elif .type == "tool_use" then
  if   .tool_name == "run_shell_command" then "\(prefix) Shell: " + ((.parameters.command // "") | first_line | truncate(80)) + reset
  elif .tool_name == "read_file"         then "\(prefix) Read "  + (.parameters.file_path // "") + reset
  elif .tool_name == "write_file"        then "\(prefix) Write " + (.parameters.file_path // "") + reset
  elif .tool_name == "edit_file"         then "\(prefix) Edit "  + (.parameters.file_path // "") + reset
  elif .tool_name == "list_directory"    then "\(prefix) List "  + (.parameters.dir_path // "") + reset
  elif .tool_name == "grep_search"       then "\(prefix) Grep "  + (.parameters.pattern // "") + reset
  else "\(prefix) " + (.tool_name // "unknown") + reset
  end
else empty
end
JQ
}

# Detect fatal errors in a Gemini CLI session log.
# Checks both explicit error events and result events with
# error status (quota exhaustion, auth failure, etc.).
agent_detect_fatal() {
    local logfile="$1"

    local error_line
    error_line=$(grep '"type"[[:space:]]*:[[:space:]]*"error"' "$logfile" 2>/dev/null | head -1 || true)
    if [ -n "$error_line" ]; then
        echo "$error_line" | jq -r '.message // .error // "unknown error"' 2>/dev/null || true
        return
    fi

    # Gemini wraps API errors in a result event with status:"error"
    # rather than emitting a separate error event. Example:
    #   {"type":"result","status":"error","error":{"message":"..."}}
    # Must match type:"result" too -- tool_result events also have
    # status:"error" for normal tool failures (file not found, etc.).
    local result_line
    result_line=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null \
        | grep '"status"[[:space:]]*:[[:space:]]*"error"' | head -1 || true)
    if [ -n "$result_line" ]; then
        local msg
        msg=$(echo "$result_line" | jq -r '.error.message // "unknown API error"' 2>/dev/null || true)
        # Enrich with retry delay from stderr if available.
        if [ -f "${logfile}.err" ]; then
            local retry
            retry=$(grep -o 'retry in [^.]*' "${logfile}.err" 2>/dev/null | head -1 || true)
            [ -n "$retry" ] && msg="${msg} (${retry})"
        fi
        echo "$msg"
    fi
}

# Detect retriable errors (rate limits, quota exhaustion).
# Returns non-empty string if the error is retriable, empty if fatal.
# Args: <logfile> <exit_code>
agent_is_retriable() {
    local logfile="$1"
    grep -qi 'RESOURCE_EXHAUSTED\|429.*Too many\|Too many requests' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi 'rate.limit\|quota\|retry in\|too many requests' \
            "${logfile}.err" 2>/dev/null && echo "rate_limited" && return
    fi
}

# Gemini CLI has no effort flag.
agent_docker_env() { :; }

# Resolve auth credentials and emit Docker -e flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: GEMINI_API_KEY
agent_docker_auth() {
    local api_key="$1"
    # auth_token=$2, auth_mode=$3, base_url=$4 — unused;
    # Gemini CLI only supports native GEMINI_API_KEY auth.

    local label=""
    local key="${api_key:-${GEMINI_API_KEY:-}}"
    if [ -n "$key" ]; then
        printf -- '-e\nGEMINI_API_KEY=%s\n' "$key"
        label="key"
    fi

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g @google/gemini-cli
INSTALL
}
