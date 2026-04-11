#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: OpenAI Codex CLI
# Implements the role interface for OpenAI's Codex CLI.

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "gpt-5.4"; }
agent_name()    { echo "Codex CLI"; }
agent_cmd()     { echo "codex"; }

agent_version() {
    local v
    v=$(codex --version 2>/dev/null || echo "unknown")
    echo "${v%% *}"
}

# Run one agent session.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    local append_file="${4:-}"

    # Codex reads .codex/instructions.md from the workspace for
    # additional system-level context (like GEMINI.md for Gemini).
    if [ -n "$append_file" ] && [ -f "$append_file" ]; then
        mkdir -p /workspace/.codex
        cp "$append_file" /workspace/.codex/instructions.md \
            2>/dev/null || true
    fi

    local effort_args=()
    if [ -n "${CODEX_EFFORT:-}" ]; then
        effort_args=(-c "model_reasoning_effort=\"${CODEX_EFFORT}\"")
    fi

    codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -m "$model" \
        --json \
        --skip-git-repo-check \
        "${effort_args[@]+"${effort_args[@]}"}" \
        "$prompt_text" \
        2>"${logfile}.err" \
        | stdbuf -oL tee "$logfile"
}

# Write agent-specific settings and authenticate.
# Config goes to ~/.codex/ (where Codex CLI looks by default),
# NOT /workspace/.codex/ (which is only for instructions.md).
agent_settings() {
    local _workspace="$1"
    local codex_home="${HOME}/.codex"
    mkdir -p "$codex_home" 2>/dev/null \
        || { sudo mkdir -p "$codex_home" && sudo chown "$(id -u):$(id -g)" "$codex_home"; }

    cat > "${codex_home}/config.toml" <<'TOML'
cli_auth_credentials_store = "file"
TOML

    if [ -n "${OPENAI_API_KEY:-}" ]; then
        CODEX_HOME="$codex_home" \
            printenv OPENAI_API_KEY \
            | codex login --with-api-key 2>/dev/null || true
    fi
}

# Extract stats from Codex JSONL output.
# Codex emits turn.completed events with usage; sum across turns.
#   {"type":"turn.completed","usage":{"input_tokens":N,
#    "cached_input_tokens":N,"output_tokens":N}}
agent_extract_stats() {
    local logfile="$1"
    local stats
    stats=$(grep '"type"[[:space:]]*:[[:space:]]*"turn.completed"' \
        "$logfile" 2>/dev/null \
        | jq -s '{
            tok_in:  [.[].usage.input_tokens        // 0] | add,
            tok_out: [.[].usage.output_tokens        // 0] | add,
            cached:  [.[].usage.cached_input_tokens  // 0] | add,
            turns:   length
        }' 2>/dev/null || true)
    if [ -z "$stats" ] || [ "$stats" = "null" ]; then
        printf "0\t0\t0\t0\t0\t0\t0\t0"
        return
    fi
    local tok_in tok_out cached turns
    tok_in=$(echo "$stats" | jq -r '.tok_in // 0')
    tok_out=$(echo "$stats" | jq -r '.tok_out // 0')
    cached=$(echo "$stats" | jq -r '.cached // 0')
    turns=$(echo "$stats" | jq -r '.turns // 0')
    # No native cost or timing from Codex JSONL; use pricing config.
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "0" "$tok_in" "$tok_out" "$cached" "0" "0" "0" "$turns"
}

# Return the jq program for parsing activity from Codex JSONL.
# Codex emits item.started/item.completed events with item types:
#   command_execution, agent_message, file_change, mcp_tool_call, etc.
# File paths live in .changes[].path (not .file_path).
# No separate reasoning type; thinking is internal to the model.
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
select(.type == "item.started" or .type == "item.completed") |
.item |
if .type == "command_execution" then
  "\(prefix) Shell: " + ((.command // "") | first_line | truncate(80)) + reset
elif .type == "file_change" then
  "\(prefix) Edit " + ((.changes[0].path // "") | first_line) + reset
elif .type == "mcp_tool_call" then
  "\(prefix) MCP: " + (.tool_name // "unknown") + reset
elif .type == "web_search" then
  "\(prefix) Search: " + (.query // "") + reset
elif .type == "agent_message" then
  empty
else empty
end
JQ
}

# Detect fatal errors in a Codex session log.
# Checks for turn.failed and error events.
agent_detect_fatal() {
    local logfile="$1"

    local fail_line
    fail_line=$(grep '"type"[[:space:]]*:[[:space:]]*"turn.failed"' \
        "$logfile" 2>/dev/null | head -1 || true)
    if [ -n "$fail_line" ]; then
        echo "$fail_line" | jq -r '.error // .message // "turn failed"' \
            2>/dev/null || true
        return
    fi

    local error_line
    error_line=$(grep '"type"[[:space:]]*:[[:space:]]*"error"' \
        "$logfile" 2>/dev/null | head -1 || true)
    if [ -n "$error_line" ]; then
        echo "$error_line" | jq -r '.message // .error // "unknown error"' \
            2>/dev/null || true
        return
    fi

    # Check stderr for errors when log is empty or has no tokens.
    if [ -f "${logfile}.err" ]; then
        local err_msg
        err_msg=$(grep -i 'error\|invalid.*key\|unauthorized' \
            "${logfile}.err" 2>/dev/null \
            | grep -iv 'could not update PATH\|proceeding.*PATH' \
            | head -1 || true)
        if [ -n "$err_msg" ] && \
                ! grep -q '"type"[[:space:]]*:[[:space:]]*"turn.completed"' \
                "$logfile" 2>/dev/null; then
            echo "$err_msg"
        fi
    fi
}

# Detect retriable errors (rate limits, quota).
# Returns non-empty string if the error is retriable, empty if fatal.
# Args: <logfile> <exit_code>
agent_is_retriable() {
    local logfile="$1"
    grep -qi '429\|rate.limit\|too many requests\|quota' \
        "$logfile" 2>/dev/null && echo "rate_limited" && return
    if [ -f "${logfile}.err" ]; then
        grep -qi 'rate.limit\|too many requests\|quota\|429' \
            "${logfile}.err" 2>/dev/null && echo "rate_limited" && return
    fi
    return 0
}

# Map effort to Codex config override.
# Args: <effort>
agent_docker_env() {
    local effort="${1:-}"
    if [ -n "$effort" ]; then
        printf -- '-e\nCODEX_EFFORT=%s\n' "$effort"
    fi
}

# Resolve auth credentials and emit Docker flags.
# Args: <api_key> <auth_token> <auth_mode> <base_url>
# Reads host env: OPENAI_API_KEY, CODEX_AUTH_JSON
#
# Auth modes:
#   chatgpt  — Mount ~/.codex/auth.json (ChatGPT subscription).
#   apikey   — Use OPENAI_API_KEY only.
#   (empty)  — Auto-detect: auth.json if found, else API key.
agent_docker_auth() {
    local api_key="$1" _auth_token="$2" auth_mode="$3" _base_url="$4"

    local label=""
    local key="${api_key:-${OPENAI_API_KEY:-}}"
    local auth_json="${CODEX_AUTH_JSON:-${HOME}/.codex/auth.json}"

    # Guard: detect a corrupted auth.json (directory instead of file),
    # which older code or a stale Docker -v mount may have created.
    if [ -d "$auth_json" ]; then
        echo "WARNING: ${auth_json} is a directory (should be a file)." >&2
        echo "  Fix with: sudo rm -rf '${auth_json}'" >&2
    fi

    # Use --mount instead of -v so Docker errors out (rather than
    # silently creating a directory) if the source file is missing.
    local _mount_fmt='--mount\ntype=bind,source=%s,target=/home/agent/.codex/auth.json,readonly\n'

    case "${auth_mode}" in
        chatgpt)
            if [ -f "$auth_json" ]; then
                printf -- "$_mount_fmt" "$auth_json"
                label="chatgpt"
            else
                echo "WARNING: auth=chatgpt but ${auth_json} not found" >&2
            fi
            ;;
        apikey)
            if [ -n "$key" ]; then
                printf -- '-e\nOPENAI_API_KEY=%s\n' "$key"
                label="key"
            fi
            ;;
        *)
            if [ -n "$key" ]; then
                printf -- '-e\nOPENAI_API_KEY=%s\n' "$key"
                label="key"
            fi
            if [ -f "$auth_json" ]; then
                printf -- "$_mount_fmt" "$auth_json"
                if [ -n "$label" ]; then label="auto"
                else label="chatgpt"; fi
            fi
            ;;
    esac

    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

# Dockerfile fragment to install this agent's CLI.
agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g @openai/codex
INSTALL
}
