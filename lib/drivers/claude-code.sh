#!/bin/bash
# Agent driver: Claude Code
# Implements the role interface for Anthropic's Claude Code CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "claude-opus-4-6"; }
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
# Delegates to the shared JSONL parser in _common.sh.
agent_extract_stats() { _extract_jsonl_stats "$1"; }

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

# Detect fatal errors in a Claude Code session log.
# Returns non-empty string if fatal, empty if OK.
# Args: <logfile> <exit_code>
agent_detect_fatal() {
    local logfile="$1"
    # exit_code=$2 — available but not needed for Claude Code
    # since we detect errors from the structured JSON log.
    local session_error
    session_error=$(grep '"error"[[:space:]]*:' "$logfile" 2>/dev/null \
        | jq -r 'select(.error) | .error' 2>/dev/null | head -1 || true)
    if [ -n "$session_error" ]; then
        # Check zero tokens via result line.
        local result_line tok_in tok_out
        result_line=$(grep '"type"[[:space:]]*:[[:space:]]*"result"' "$logfile" 2>/dev/null | tail -1 || true)
        tok_in=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)
        tok_out=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)
        if [ "${tok_in:-0}" = "0" ] && [ "${tok_out:-0}" = "0" ]; then
            local session_msg
            session_msg=$(echo "$result_line" | jq -r '.result // empty' 2>/dev/null || true)
            echo "${session_error}: ${session_msg}"
            return
        fi
    fi
}

# Detect retriable errors (rate limits, overload).
# Returns non-empty string if the error is retriable, empty if fatal.
# Args: <logfile> <exit_code>
agent_is_retriable() {
    local logfile="$1"
    grep -q '"overloaded_error"\|"rate_limit_error"\|"overloaded"' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    grep -q '"Too many requests"\|"rate limit"' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi 'rate.limit\|too many requests\|overloaded' \
            "${logfile}.err" 2>/dev/null && echo "rate_limited" && return
    fi
}

# Map generic config to agent-specific Docker env vars.
# Args: <effort>
# Prints -e flags for docker run (one flag per line).
agent_docker_env() {
    local effort="${1:-}"
    if [ -n "$effort" ]; then
        printf -- '-e\nCLAUDE_CODE_EFFORT_LEVEL=%s\n' "$effort"
    fi
}

# Resolve auth credentials and emit Docker -e flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN,
#                 ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL
agent_docker_auth() {
    local api_key="$1" auth_token="$2" auth_mode="$3" base_url="$4"

    if [ -n "$base_url" ]; then
        printf -- '-e\nANTHROPIC_BASE_URL=%s\n' "$base_url"
    elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        printf -- '-e\nANTHROPIC_BASE_URL=%s\n' "$ANTHROPIC_BASE_URL"
    fi
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
        && printf -- '-e\nANTHROPIC_AUTH_TOKEN=%s\n' "$ANTHROPIC_AUTH_TOKEN"

    local resolved_key="" label=""
    if [ -n "$auth_token" ]; then
        printf -- '-e\nANTHROPIC_AUTH_TOKEN=%s\n' "$auth_token"
        label="token"
    else
        case "${auth_mode}" in
            oauth)
                printf -- '-e\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
                label="oauth"
                ;;
            apikey)
                resolved_key="${api_key:-${ANTHROPIC_API_KEY:-}}"
                label="key"
                ;;
            *)
                resolved_key="${api_key:-${ANTHROPIC_API_KEY:-}}"
                [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
                    && printf -- '-e\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN"
                if [ -n "$api_key" ]; then label="key"
                elif [ -n "$resolved_key" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then label="auto"
                elif [ -n "$resolved_key" ]; then label="key"
                elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then label="oauth"
                fi
                ;;
        esac
    fi

    printf -- '-e\nANTHROPIC_API_KEY=%s\n' "$resolved_key"
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
# CLAUDE_CODE_VERSION is a Docker build-arg; empty = latest.
agent_install_cmd() {
    cat <<'INSTALL'
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh ${CLAUDE_CODE_VERSION:+$CLAUDE_CODE_VERSION} \
    && rm /tmp/claude-install.sh
ENV PATH="/home/agent/.local/bin:${PATH}"
INSTALL
}
