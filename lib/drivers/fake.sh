#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Fake (test double)
# Emits realistic JSONL output for unit-testing the harness loop
# without Docker or API keys.  See "Exploring the Continuum of
# Test Doubles" (MSDN Magazine, Sep 2007).

agent_name()    { echo "Fake Agent"; }
agent_cmd()     { echo "fake-agent"; }
agent_version() { echo "0.0.0-fake"; }

# Run one fake agent session.
# Emits a minimal but realistic JSONL stream: init, assistant, result.
# Args: <model> <prompt_text> <logfile> [append_system_prompt_file]
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"

    {
        printf '{"type":"system","subtype":"init","session_id":"fake-01","tools":["Bash","Read","Write"],"model":"%s"}\n' "$model"
        printf '{"type":"assistant","session_id":"fake-01","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Fake agent completed the task."}]}}\n'
        printf '{"type":"result","subtype":"success","session_id":"fake-01","total_cost_usd":0.0001,"is_error":false,"duration_ms":100,"duration_api_ms":80,"num_turns":1,"result":"Done.","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    } | stdbuf -oL tee "$logfile"
}

# No agent-specific settings needed for the fake driver.
agent_settings() { :; }

# Detect fatal errors — fake driver never fails fatally.
agent_detect_fatal() { :; }

# Extract stats from session log (same JSONL format as Claude).
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

# Activity jq filter — fake agent emits no tool_use blocks, so
# the filter is a no-op that still accepts the same JSONL format.
agent_activity_jq() {
    cat <<'JQ'
def ts: now | strftime("%H:%M:%S");
def prefix: "\u001b[33m\(ts)   agent[\($id)]";
def reset: "\u001b[0m";

fromjson? // empty |
select(.type == "assistant") |
.message.content[]? |
select(.type == "tool_use") |
"\(prefix) " + .name + reset
JQ
}

agent_docker_env() { :; }

agent_install_cmd() {
    echo '# Fake driver: no agent to install.'
}
