#!/bin/bash
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/drivers/pi.sh
source "$ROOT/lib/drivers/pi.sh"

PASS=0
FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    expected: %s\n    actual: %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}
has() {
    if grep -qF -- "$1" "$2"; then echo yes; else echo no; fi
}

assert_eq "name" Pi "$(agent_name)"
assert_eq "command" pi "$(agent_cmd)"
assert_eq "default model" claude-opus-4-6 "$(agent_default_model)"
for fn in agent_default_model agent_name agent_cmd agent_version \
        agent_run agent_interactive_run agent_settings agent_extract_stats \
        agent_detect_fatal agent_is_retriable agent_activity_jq \
        agent_docker_env agent_docker_auth agent_install_cmd; do
    assert_eq "interface $fn" function "$(type -t "$fn")"
done

# Stub only the CLI boundary, exercising the real driver and reaper.
mkdir -p "$WORK/bin" "$WORK/workspace"
export PI_TEST_ARGS="$WORK/args" PI_TEST_LOG="$WORK/events"
cat > "$WORK/bin/pi" <<'CLI'
#!/bin/bash
if [ "${1:-}" = --version ]; then echo 0.86.1-test; exit; fi
printf '%s\n' "$@" > "$PI_TEST_ARGS"
cat "$PI_TEST_LOG"
exit "${PI_TEST_EXIT:-0}"
CLI
chmod +x "$WORK/bin/pi"
export PATH="$WORK/bin:$PATH"
assert_eq "version" 0.86.1-test "$(agent_version)"

# Pi repeats messages in multiple event types; count only message_end.
cat > "$WORK/events" <<'JSONL'
{"type":"session","version":3}
not json
{"type":"message_end","message":{"role":"user","content":"hi"}}
{"type":"message_update","usage":{"input":99999}}
{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":30,"cacheWrite":40,"cost":{"total":0.1}},"stopReason":"toolUse"}}
{"type":"turn_end","message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":30,"cacheWrite":40,"cost":{"total":0.1}}}}
{"type":"entry_appended","entry":{"type":"message","message":{"role":"assistant","usage":{"input":10}}}}
{"type":"message_end","message":{"role":"toolResult","usage":{"input":999}}}
{"type":"message_end","message":{"role":"assistant","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"cost":{"total":0.2}},"stopReason":"stop"}}
{"type":"agent_end","messages":[{"role":"assistant","usage":{"input":999}}]}
JSONL
assert_eq "usage without double counting" $'0.300\t11\t22\t33\t44\t0\t0\t2' \
    "$(agent_extract_stats "$WORK/events" | awk -F '\t' \
        'BEGIN { OFS="\t" } { $1=sprintf("%.3f", $1); print }')"
printf '%s\n' \
    '{"type":"entry_appended","entry":{"type":"compaction","usage":{"input":5,"output":6,"cost":{"total":0.4}}}}' \
    '{"type":"entry_appended","entry":{"type":"usage","usage":{"cacheRead":7,"cost":{"total":0.1}}}}' \
    >> "$WORK/events"
# Compare numerically rather than depending on floating-point formatting.
assert_eq "compaction and other usage" 'true' \
    "$(agent_extract_stats "$WORK/events" | awk -F '\t' \
        '{print ($1 > .799 && $1 < .801 && $2 == 16 && $3 == 28 &&
                 $4 == 40 && $5 == 44 && $8 == 2) ? "true" : "false"}')"
: > "$WORK/empty"
for file in empty missing; do
    assert_eq "$file usage" $'0\t0\t0\t0\t0\t0\t0\t0' \
        "$(agent_extract_stats "$WORK/$file")"
done
assert_eq "successful response" "" "$(agent_detect_fatal "$WORK/events" 0)"
assert_eq "nonzero with tokens is fatal" yes \
    "$(agent_detect_fatal "$WORK/events" 9 | grep -q 'code 9' && echo yes)"
assert_eq "empty success is fatal" yes \
    "$(agent_detect_fatal "$WORK/empty" 0 | grep -q 'no response' && echo yes)"
printf 'No API key found\n' > "$WORK/empty.err"
assert_eq "startup stderr" 'No API key found' \
    "$(agent_detect_fatal "$WORK/empty" 1)"

for reason in error aborted; do
    jq -nc --arg reason "$reason" \
        '{type:"message_end", message:{role:"assistant",
          stopReason:$reason,errorMessage:""}}' > "$WORK/error"
    assert_eq "empty $reason diagnostic" "Pi request $reason" \
        "$(agent_detect_fatal "$WORK/error" 0)"
done
for error in '429 rate limit' '503 overloaded' '502 bad gateway' \
        'fetch failed' '401 unauthorized' '400 extra usage required'; do
    jq -nc --arg error "$error" \
        '{type:"message_end",message:{role:"assistant",stopReason:"error",
          errorMessage:$error}}' > "$WORK/error"
    assert_eq "zero-exit fatal $error" "$error" \
        "$(agent_detect_fatal "$WORK/error" 0)"
    case "$error" in
        429*|503*) expected=rate_limited ;;
        502*|fetch*) expected=transient ;;
        *) expected="" ;;
    esac
    assert_eq "retry $error" "$expected" \
        "$(agent_is_retriable "$WORK/error" 0)"
done
cat "$WORK/events" >> "$WORK/error"
assert_eq "recovered error" "" "$(agent_detect_fatal "$WORK/error" 0)"
assert_eq "recovered error not retriable" "" \
    "$(agent_is_retriable "$WORK/error" 0)"

cd "$WORK/workspace"
printf 'Injected git instructions.\n' > "$WORK/system.md"
PI_EFFORT=none agent_run claude-sonnet-4-6 '- prompt with spaces' \
    "$WORK/run.log" "$WORK/system.md" >/dev/null
for arg in --provider anthropic --model claude-sonnet-4-6 --thinking off \
        --print --mode json --no-session --offline --no-approve \
        read,write,edit,bash 'Injected git instructions.' '- prompt with spaces'; do
    assert_eq "run arg $arg" yes "$(has "$arg" "$WORK/args")"
done
assert_eq "reaper writes log" "$(< "$WORK/events")" "$(< "$WORK/run.log")"
rc=0
PI_TEST_EXIT=7 agent_run anthropic/claude-sonnet-4-6 hi \
    "$WORK/fail.log" >/dev/null || rc=$?
assert_eq "exit propagated" 7 "$rc"
assert_eq "qualified model stripped" no \
    "$(has anthropic/claude-sonnet-4-6 "$WORK/args")"
agent_run openrouter/anthropic/claude-sonnet-4.6 hi \
    "$WORK/run.log" >/dev/null
assert_eq "provider parsed" yes "$(has openrouter "$WORK/args")"
assert_eq "model keeps inner slash" yes \
    "$(has anthropic/claude-sonnet-4.6 "$WORK/args")"
mkdir .claude
printf 'Legacy context.\n' > .claude/CLAUDE.md
agent_run claude-sonnet-4-6 hi "$WORK/run.log" >/dev/null
assert_eq "legacy context appended" yes "$(has 'Legacy context.' "$WORK/args")"
printf 'Native context.\n' > AGENTS.md
agent_run claude-sonnet-4-6 hi "$WORK/run.log" >/dev/null
assert_eq "native context wins" no "$(has 'Legacy context.' "$WORK/args")"
agent_interactive_run claude-sonnet-4-6 "$WORK/system.md" \
    "$WORK/system.md" > "$WORK/ui"
assert_eq "interactive prompt hint" yes \
    "$(has 'Profile prompt is available' "$WORK/ui")"
assert_eq "interactive retains native UI" no "$(has --print "$WORK/args")"
assert_eq "interactive retains trust prompt" no \
    "$(has --no-approve "$WORK/args")"
assert_eq "interactive receives appendix" yes \
    "$(has 'Injected git instructions.' "$WORK/args")"

# Auth resolution is independent of whatever credentials the host has.
unset ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
unset PI_API_KEY PI_BASE_URL
assert_eq "missing auth label" $'-e\nSWARM_AUTH_MODE=' \
    "$(agent_docker_auth '' '' '' '' 2>/dev/null)"
export ANTHROPIC_API_KEY=api-test CLAUDE_CODE_OAUTH_TOKEN=oauth-test
assert_eq "apikey excludes OAuth" $'-e\nANTHROPIC_API_KEY=api-test\n-e\nSWARM_AUTH_MODE=key' \
    "$(agent_docker_auth '' '' apikey '')"
assert_eq "oauth excludes API key" $'-e\nANTHROPIC_OAUTH_TOKEN=oauth-test\n-e\nSWARM_AUTH_MODE=oauth' \
    "$(agent_docker_auth '' '' oauth '')"
assert_eq "auto chooses OAuth" "$(agent_docker_auth '' '' oauth '')" \
    "$(agent_docker_auth '' '' '' '')"
assert_eq "native Pi OAuth priority" $'-e\nANTHROPIC_OAUTH_TOKEN=native-test\n-e\nSWARM_AUTH_MODE=oauth' \
    "$(ANTHROPIC_OAUTH_TOKEN=native-test agent_docker_auth '' '' oauth '')"
assert_eq "group API key wins over auth" $'-e\nPI_API_KEY=group-key\n-e\nSWARM_AUTH_MODE=key' \
    "$(agent_docker_auth group-key '' oauth '')"
assert_eq "generic key for other providers" $'-e\nPI_API_KEY=generic-key\n-e\nSWARM_AUTH_MODE=key' \
    "$(PI_API_KEY=generic-key agent_docker_auth '' '' '' '')"
assert_eq "bearer and base URL" $'-e\nPI_BASE_URL=https://example.test\n-e\nANTHROPIC_AUTH_TOKEN=bearer-test\n-e\nSWARM_AUTH_MODE=token' \
    "$(agent_docker_auth '' bearer-test '' https://example.test)"
assert_eq "no OAuth fallback in explicit OAuth mode" \
    $'-e\nSWARM_AUTH_MODE=' \
    "$(CLAUDE_CODE_OAUTH_TOKEN='' agent_docker_auth '' '' oauth '' 2>/dev/null)"
agent_docker_env high > "$WORK/env"
assert_eq "effort forwarded" yes "$(has PI_EFFORT=high "$WORK/env")"
assert_eq "empty effort leaves Pi default" "" "$(agent_docker_env '')"

export PI_CODING_AGENT_DIR="$WORK/pi-home"
PI_API_KEY='!not-a-shell-command' PI_BASE_URL=https://example.test \
    SWARM_MODEL=openai/gpt-5.4 agent_settings "$WORK/workspace"
assert_eq "auth stores reference not secret" '$PI_API_KEY' \
    "$(jq -r '.openai.key' "$PI_CODING_AGENT_DIR/auth.json")"
assert_eq "base URL assigned to selected provider" https://example.test \
    "$(jq -r '.providers.openai.baseUrl' "$PI_CODING_AGENT_DIR/models.json")"
assert_eq "retries delegated to harness" false \
    "$(jq -r '.retry.enabled' "$PI_CODING_AGENT_DIR/settings.json")"
assert_eq "cache warming disabled" off \
    "$(jq -r '.cacheWarming' "$PI_CODING_AGENT_DIR/settings.json")"
assert_eq "telemetry disabled without effort" false \
    "$(jq -r '.enableInstallTelemetry' "$PI_CODING_AGENT_DIR/settings.json")"
assert_eq "credential file is private" auth.json \
    "$(find "$PI_CODING_AGENT_DIR/auth.json" -perm 600 -exec basename {} \;)"
assert_eq "no generated config in workspace" no \
    "$([ -e .pi ] && echo yes || echo no)"

agent_activity_jq > "$WORK/activity.jq"
cat > "$WORK/activity" <<'JSONL'
{"type":"tool_execution_start","toolName":"bash","args":{"command":"echo test\nsecond line"}}
{"type":"tool_execution_start","toolName":"read","args":{"path":"a.txt"}}
{"type":"tool_execution_start","toolName":"write","args":{"path":"b.txt"}}
{"type":"tool_execution_start","toolName":"edit","args":{"path":"c.txt"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Consider the task."}]}}
{"type":"turn_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Duplicate"}]}}
invalid
JSONL
AGENT_ID=3 SWARM_JQ_FILTER_FILE="$WORK/activity.jq" \
    "$ROOT/lib/activity-filter.sh" < "$WORK/activity" > "$WORK/display"
for text in 'agent[3]' 'Shell: echo test' 'Read a.txt' 'Write b.txt' \
        'Edit c.txt' 'Think: Consider the task.'; do
    assert_eq "activity $text" yes "$(has "$text" "$WORK/display")"
done
assert_eq "no duplicated thinking" no "$(has Duplicate "$WORK/display")"
assert_eq "single-line shell display" no "$(has 'second line' "$WORK/display")"

# Exercise actual build functions with Docker stubbed, including profiles
# that are interactive-only and a Pi post-processor.
eval "$(awk '/^compute_swarm_agents\(\) \{/,/^\}$/' "$ROOT/launch.sh")"
eval "$(awk '/^build_image\(\) \{/,/^\}$/' "$ROOT/launch.sh")"
CONFIG_FILE="$WORK/config.json"
# Used by the extracted build_image function.
# shellcheck disable=SC2034
SWARM_DIR="$ROOT"
# shellcheck disable=SC2034
IMAGE_NAME=pi-unit-test
docker() { printf '%s\n' "$@" > "$WORK/docker-args"; }
printf '%s\n' '{"driver":"pi","pi_version":"0.86.1",
 "agents":[{"count":1,"model":"claude-sonnet-4-6"}]}' > "$CONFIG_FILE"
build_image >/dev/null
assert_eq "Pi build union" yes "$(has SWARM_AGENTS=pi "$WORK/docker-args")"
assert_eq "Pi version build argument" yes \
    "$(has PI_VERSION=0.86.1 "$WORK/docker-args")"
printf '%s\n' '{"agents":[{"count":1},{"count":0,"driver":"pi"}],
 "post_process":{"driver":"pi"}}' > "$CONFIG_FILE"
assert_eq "mixed build union" claude-code,pi \
    "$(compute_swarm_agents "$CONFIG_FILE")"
build_image >/dev/null
assert_eq "unconfigured version omitted" no \
    "$(has PI_VERSION= "$WORK/docker-args")"
agent_install_cmd > "$WORK/install"
assert_eq "install disables lifecycle scripts" yes \
    "$(has --ignore-scripts "$WORK/install")"
assert_eq "Node install includes Pi" yes \
    "$(has '(gemini-cli|codex-cli|pi)' "$ROOT/Dockerfile")"

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
