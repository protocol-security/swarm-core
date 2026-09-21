#!/bin/bash
# Agent driver: Pi (https://pi.dev).

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "claude-opus-4-6"; }
agent_name() { echo "Pi"; }
agent_cmd() { echo "pi"; }
agent_version() { pi --version 2>/dev/null || echo "unknown"; }

# Bare model IDs select Anthropic; qualified IDs select a Pi provider.
_pi_provider() {
    case "$1" in
        */*) printf '%s' "${1%%/*}" ;;
        *) printf 'anthropic' ;;
    esac
}

# Keep the shared subscription store limited to Codex credentials.
_pi_has_codex_auth() {
    [ -f "$1" ] && jq -e '
        keys == ["openai-codex"] and
        (."openai-codex" |
            .type == "oauth" and
            (.access | type == "string" and length > 0) and
            (.refresh | type == "string" and length > 0) and
            (.expires | type == "number"))
    ' "$1" >/dev/null 2>&1
}

_pi_validate_chatgpt() {
    local provider="$1" pi_home="$2"
    if [ "$provider" != openai-codex ]; then
        echo 'ERROR: Pi auth=chatgpt requires openai-codex/<model>.' >&2
        return 1
    fi
    if [ -n "${PI_BASE_URL:-}" ]; then
        echo 'ERROR: Pi auth=chatgpt does not allow base_url overrides.' >&2
        return 1
    fi
    if ! _pi_has_codex_auth "$pi_home/auth.json" \
            || [ ! -w "$pi_home" ] || [ ! -w "$pi_home/auth.json" ]; then
        echo 'ERROR: Pi chatgpt needs a writable, dedicated PI_AUTH_DIR' >&2
        echo 'containing only an openai-codex OAuth entry in auth.json.' >&2
        return 1
    fi
}

# Share model, effort, and system instructions across both CLI modes.
_pi_invoke() {
    local mode="$1" model="$2" prompt_text="$3" append_file="$4"
    local logfile="${5:-}" provider effort="${PI_EFFORT:-}"
    provider=$(_pi_provider "$model")
    if [ "${PI_CHATGPT_AUTH:-}" = 1 ]; then
        local auth_error pi_home="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
        if ! auth_error=$(_pi_validate_chatgpt "$provider" "$pi_home" 2>&1); then
            if [ "$mode" = json ]; then
                : > "$logfile"
                printf '%s\n' "$auth_error" > "${logfile}.err"
            fi
            printf '%s\n' "$auth_error" >&2
            return 1
        fi
    fi
    if [[ "$model" == */* ]]; then
        model="${model#*/}"
    fi
    local -a args=(--provider "$provider" --model "$model" --offline)
    if [ -n "$effort" ]; then
        [ "$effort" = "none" ] && effort="off"
        args+=(--thinking "$effort")
    fi

    # Pi loads root AGENTS.md/CLAUDE.md natively, not .claude/CLAUDE.md.
    # Read the latter without creating a file the agent could commit.
    local appendix=""
    if [ ! -f AGENTS.override.md ] && [ ! -f AGENTS.md ] \
            && [ ! -f CLAUDE.md ] && [ -f .claude/CLAUDE.md ]; then
        appendix="$(cat .claude/CLAUDE.md)"
    fi
    if [ -n "$append_file" ]; then
        appendix+=$'\n\n'"$(cat "$append_file")"
    fi
    if [ -n "$appendix" ]; then
        args+=(--append-system-prompt "$appendix")
    fi

    if [ "$mode" = "json" ]; then
        # Fresh sessions, four tools, and no automatic project code loading.
        # Docker, not Pi's project-trust setting, is the isolation boundary.
        args+=(--print --mode json --no-session --no-approve
               --tools "read,write,edit,bash" -- "$prompt_text")
        _run_reaped "$logfile" pi "${args[@]}"
    else
        # Keep the native UI and its project-trust prompt.
        pi "${args[@]}"
    fi
}

# Args: <model> <prompt_text> <logfile> [append_system_prompt_file].
agent_run() {
    _pi_invoke json "$1" "$2" "${4:-}" "$3"
}

# Args: <model> <prompt_file> [append_system_prompt_file].
agent_interactive_run() {
    local model="$1" prompt_file="${2:-}" append_file="${3:-}"
    if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
        printf 'Profile prompt is available at %s\n' "$prompt_file"
    fi
    _pi_invoke interactive "$model" "" "$append_file"
}

# Keep generated settings and credentials outside the worktree. API-key
# runs have private Pi homes. ChatGPT runs explicitly share a dedicated
# home so Pi's auth.json.lock serializes refresh and token persistence.
agent_settings() {
    local _workspace="$1" provider
    local pi_home="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
    provider=$(_pi_provider "${SWARM_MODEL:-$(agent_default_model)}")
    if [ "${PI_CHATGPT_AUTH:-}" = 1 ]; then
        _pi_validate_chatgpt "$provider" "$pi_home" || return 1
    else
        mkdir -p "$pi_home"
        chmod 700 "$pi_home"
    fi
    (
        umask 077
        # Atomic replacement keeps simultaneous container startups from
        # reading a partially written shared settings file. Never replace
        # shared auth.json: Pi locks and persists its refreshes itself.
        local settings
        settings=$(mktemp "$pi_home/.swarm-settings.XXXXXX") || exit 1
        trap 'rm -f "$settings"' EXIT
        jq -n --arg chatgpt "${PI_CHATGPT_AUTH:-}" '{
            retry: {enabled: false}, cacheWarming: "off",
            enableInstallTelemetry: false
        } + (if $chatgpt == "1" then {
            transport: "sse", sessionDir: "/home/agent/.pi/sessions"
        } else {} end)' > "$settings" || exit 1
        mv "$settings" "$pi_home/settings.json" || exit 1
        if [ "${PI_CHATGPT_AUTH:-}" != 1 ] && [ -n "${PI_API_KEY:-}" ]; then
            # Store an env reference, not the secret or a shell expression.
            jq -n --arg provider "$provider" \
                '{($provider): {type: "api_key", key: "$PI_API_KEY"}}' \
                > "$pi_home/auth.json"
        fi
        if [ -n "${PI_BASE_URL:-}" ]; then
            jq -n --arg provider "$provider" --arg url "$PI_BASE_URL" \
                '{providers: {($provider): {baseUrl: $url}}}' \
                > "$pi_home/models.json"
        fi
    )
}

# Count authoritative message_end events once, not repeated snapshots in
# message_update, turn_end, agent_end, or entry_appended message entries.
# Additional persisted usage (e.g. compaction) contributes tokens and cost,
# but not assistant turns. Timing falls back to the harness wall clock.
agent_extract_stats() {
    local logfile="$1"
    if [ ! -f "$logfile" ]; then
        printf '0\t0\t0\t0\t0\t0\t0\t0\n'
        return
    fi
    jq -Rnr '
        reduce (inputs | fromjson? | select(type == "object")) as $e
            ([0,0,0,0,0,0,0,0];
            (if $e.type == "message_end"
                    and $e.message.role == "assistant" then
                {usage: $e.message.usage, turns: 1}
             elif $e.type == "entry_appended"
                    and ($e.entry.type == "usage"
                         or $e.entry.type == "compaction"
                         or $e.entry.type == "branch_summary") then
                {usage: $e.entry.usage, turns: 0}
             else {turns: 0} end) as $m |
            .[0] += ($m.usage.cost.total // 0) |
            .[1] += ($m.usage.input // 0) |
            .[2] += ($m.usage.output // 0) |
            .[3] += ($m.usage.cacheRead // 0) |
            .[4] += ($m.usage.cacheWrite // 0) |
            .[7] += $m.turns
        ) | @tsv
    ' "$logfile"
}

# Pi JSON mode may exit zero even when the final assistant response failed.
# A recovered retry must not be mistaken for an earlier terminal failure.
agent_detect_fatal() {
    local logfile="$1" exit_code="${2:-0}" last
    last=$(jq -Rn '
        reduce (inputs | fromjson? | select(type == "object") |
            select(.type == "message_end" and
                   .message.role == "assistant")) as $e
            (null; $e.message)
    ' "$logfile" 2>/dev/null || true)
    local error
    error=$(printf '%s\n' "$last" | jq -r '
        select(.stopReason == "error" or .stopReason == "aborted") |
        if (.errorMessage // "") != "" then .errorMessage
        else "Pi request " + .stopReason end
    ' 2>/dev/null || true)
    if [ -n "$error" ]; then
        printf '%s\n' "$error"
    elif [ "$exit_code" -ne 0 ] || [ -z "$last" ] || [ "$last" = null ]; then
        if [ -s "${logfile}.err" ]; then
            head -1 "${logfile}.err"
        else
            printf 'Pi exited with code %s or produced no response\n' \
                "$exit_code"
        fi
    fi
}

# Only classify the terminal failure, not arbitrary model/tool output.
agent_is_retriable() {
    local error transient
    transient='50[0234]|internal.server.error|connection|timed out|fetch failed'
    error=$(agent_detect_fatal "$1" "${2:-0}")
    if printf '%s\n' "$error" | grep -Eqi \
            '429|rate.limit|too many requests|overloaded'; then
        echo "rate_limited"
    elif printf '%s\n' "$error" | grep -Eqi "$transient"; then
        echo "transient"
    fi
    return 0
}

agent_activity_jq() {
    cat <<'JQ'
def short:
  split("\n")[0] | if length > 80 then .[:77] + "..." else . end;
def prefix:
  "\u001b[33m\(now | strftime("%H:%M:%S"))   agent[\($id)]";
def reset: "\u001b[0m";
fromjson? // empty |
if .type == "tool_execution_start" then
  (if .toolName == "bash" then "Shell: " + ((.args.command // "") | short)
   elif .toolName == "read" then "Read " + (.args.path // "")
   elif .toolName == "write" then "Write " + (.args.path // "")
   elif .toolName == "edit" then "Edit " + (.args.path // "")
   else .toolName // "tool" end) as $text |
  "\(prefix) " + $text + reset
elif .type == "message_end" and .message.role == "assistant" then
  .message.content[]? | select(.type == "thinking") |
  (.thinking // "" | short) as $text | select($text != "") |
  "\(prefix) Think: " + $text + reset
else empty end
JQ
}

agent_docker_env() {
    if [ -n "${1:-}" ]; then
        printf -- '-e\nPI_EFFORT=%s\n' "$1"
    fi
}

# Explicit group credentials win. Otherwise select one auth source so a
# host OAuth token cannot override auth=apikey inside Pi.
# Other providers use api_key/PI_API_KEY or explicit Codex chatgpt auth.
agent_docker_auth() {
    local api_key="$1" auth_token="$2" auth_mode="$3" base_url="$4"
    local oauth="${ANTHROPIC_OAUTH_TOKEN:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"
    local label=""
    if [ -n "$base_url" ]; then
        printf -- '-e\nPI_BASE_URL=%s\n' "$base_url"
    fi
    if [ -n "$auth_token" ]; then
        printf -- '-e\nANTHROPIC_AUTH_TOKEN=%s\n' "$auth_token"
        label="token"
    elif [ -n "$api_key" ]; then
        printf -- '-e\nPI_API_KEY=%s\n' "$api_key"
        label="key"
    elif [ "$auth_mode" = chatgpt ]; then
        # Explicit opt-in only: do not mount the user's general Pi home.
        # A directory mount shares both auth.json and its adjacent lock.
        printf -- '-e\nPI_CHATGPT_AUTH=1\n'
        local auth_dir="${PI_AUTH_DIR:-}"
        if [ -n "$auth_dir" ] \
                && _pi_has_codex_auth "$auth_dir/auth.json"; then
            auth_dir=$(cd "$auth_dir" && pwd -P)
            if [[ "$auth_dir" == *','* || "$auth_dir" == *$'\n'* ]]; then
                echo 'WARNING: PI_AUTH_DIR cannot contain commas/newlines.' >&2
            else
                printf -- '--mount\ntype=bind,source=%s,' "$auth_dir"
                printf 'target=/home/agent/.pi/agent\n'
                label="chatgpt"
            fi
        else
            echo 'WARNING: Pi auth=chatgpt needs a dedicated PI_AUTH_DIR' >&2
            echo 'with only openai-codex OAuth credentials in auth.json.' >&2
        fi
    elif [ "$auth_mode" = oauth ]; then
        if [ -n "$oauth" ]; then
            printf -- '-e\nANTHROPIC_OAUTH_TOKEN=%s\n' "$oauth"
            label="oauth"
        else
            echo "WARNING: Pi auth=oauth but no Anthropic OAuth token." >&2
        fi
    elif [ -z "$auth_mode" ] || [ "$auth_mode" = apikey ]; then
        if [ -n "${PI_API_KEY:-}" ]; then
            printf -- '-e\nPI_API_KEY=%s\n' "$PI_API_KEY"
            label="key"
        elif [ "$auth_mode" != apikey ] && [ -n "$oauth" ]; then
            printf -- '-e\nANTHROPIC_OAUTH_TOKEN=%s\n' "$oauth"
            label="oauth"
        elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            printf -- '-e\nANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY"
            label="key"
        else
            echo "WARNING: no Pi API key or Anthropic OAuth token." >&2
        fi
    else
        printf 'WARNING: unsupported Pi auth mode: %s\n' "$auth_mode" >&2
    fi
    printf -- '-e\nSWARM_AUTH_MODE=%s\n' "$label"
}

agent_install_cmd() {
    cat <<'INSTALL'
RUN npm install -g --ignore-scripts \
    "@earendil-works/pi-coding-agent${PI_VERSION:+@$PI_VERSION}"
INSTALL
}
