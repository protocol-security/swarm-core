#!/bin/bash
# shellcheck disable=SC2034
# Agent driver: Fake (test double)
# Emits realistic JSONL output for unit-testing the harness loop
# without Docker or API keys.  See "Exploring the Continuum of
# Test Doubles" (MSDN Magazine, Sep 2007).

# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

agent_default_model() { echo "fake-model"; }
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

# Extract stats from session log — delegates to the shared JSONL
# parser since the fake driver emits the standard format.
agent_extract_stats() { _extract_jsonl_stats "$1"; }

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

agent_docker_auth() {
    printf -- '-e\nSWARM_AUTH_MODE=\n'
}

agent_install_cmd() {
    echo '# Fake driver: no agent to install.'
}
