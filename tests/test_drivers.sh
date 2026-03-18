#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for the driver role interface.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVERS_DIR="$TESTS_DIR/../lib/drivers"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual:              ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label} (value was empty)"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
echo "=== 1. Driver directory contains expected drivers ==="

assert_eq "claude-code driver exists" "true" \
    "$([ -f "$DRIVERS_DIR/claude-code.sh" ] && echo true || echo false)"
assert_eq "fake driver exists" "true" \
    "$([ -f "$DRIVERS_DIR/fake.sh" ] && echo true || echo false)"
assert_eq "_common.sh exists" "true" \
    "$([ -f "$DRIVERS_DIR/_common.sh" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 2. Claude Code driver — role interface ==="

source "$DRIVERS_DIR/claude-code.sh"

assert_eq "claude-code name" "Claude Code" "$(agent_name)"
assert_eq "claude-code cmd"  "claude"      "$(agent_cmd)"

JQ_FILTER=$(agent_activity_jq)
assert_not_empty "claude-code jq filter" "$JQ_FILTER"
assert_contains "claude-code jq has Bash" "Bash" "$JQ_FILTER"
assert_contains "claude-code jq has Read" "Read" "$JQ_FILTER"

INSTALL=$(agent_install_cmd)
assert_contains "claude-code install has curl" "curl" "$INSTALL"
assert_contains "claude-code install has claude.ai" "claude.ai" "$INSTALL"

# ============================================================
echo ""
echo "=== 3. Claude Code driver — agent_settings ==="

WORK="$TMPDIR/workspace"
mkdir -p "$WORK"
agent_settings "$WORK"

assert_eq "settings file created" "true" \
    "$([ -f "$WORK/.claude/settings.local.json" ] && echo true || echo false)"
assert_eq "settings valid JSON" "true" \
    "$(jq empty "$WORK/.claude/settings.local.json" 2>/dev/null && echo true || echo false)"
assert_eq "attribution commit empty" "" \
    "$(jq -r '.attribution.commit' "$WORK/.claude/settings.local.json")"
assert_eq "telemetry off" "0" \
    "$(jq -r '.env.CLAUDE_CODE_ENABLE_TELEMETRY' "$WORK/.claude/settings.local.json")"

# ============================================================
echo ""
echo "=== 4. Claude Code driver — agent_extract_stats ==="

cat > "$TMPDIR/session.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s01","tools":["Bash"],"model":"claude-opus-4-6"}
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.1234,"is_error":false,"duration_ms":15000,"duration_api_ms":12000,"num_turns":5,"result":"Done.","usage":{"input_tokens":500,"output_tokens":300,"cache_read_input_tokens":8000,"cache_creation_input_tokens":1000}}
EOF

STATS=$(agent_extract_stats "$TMPDIR/session.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"

assert_eq "stats cost"     "0.1234" "$cost"
assert_eq "stats tok_in"   "500"    "$tok_in"
assert_eq "stats tok_out"  "300"    "$tok_out"
assert_eq "stats cache_rd" "8000"   "$cache_rd"
assert_eq "stats cache_cr" "1000"   "$cache_cr"
assert_eq "stats dur"      "15000"  "$dur"
assert_eq "stats api_ms"   "12000"  "$api_ms"
assert_eq "stats turns"    "5"      "$turns"

# ============================================================
echo ""
echo "=== 5. Fake driver — role interface ==="

source "$DRIVERS_DIR/fake.sh"

assert_eq "fake name"    "Fake Agent"     "$(agent_name)"
assert_eq "fake cmd"     "fake-agent"     "$(agent_cmd)"
assert_eq "fake version" "0.0.0-fake"     "$(agent_version)"

# ============================================================
echo ""
echo "=== 6. Fake driver — agent_run produces valid JSONL ==="

LOGFILE="$TMPDIR/fake-session.log"
OUTPUT=$(agent_run "test-model" "test prompt" "$LOGFILE" 2>/dev/null)

assert_eq "fake log file created" "true" \
    "$([ -s "$LOGFILE" ] && echo true || echo false)"

# All lines should be valid JSON.
INVALID=$(jq -e empty "$LOGFILE" 2>&1 | grep -c "error" || true)
LINES=$(wc -l < "$LOGFILE" | tr -d ' ')
assert_eq "fake log 3 lines" "3" "$LINES"

# Result line should have expected fields.
RESULT=$(grep '"type".*"result"' "$LOGFILE")
assert_contains "fake result has cost" "total_cost_usd" "$RESULT"
assert_contains "fake result has model" "test-model" \
    "$(grep '"type".*"system"' "$LOGFILE")"

# ============================================================
echo ""
echo "=== 7. Fake driver — agent_extract_stats ==="

STATS=$(agent_extract_stats "$LOGFILE")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"

assert_eq "fake cost"   "0.0001" "$cost"
assert_eq "fake tok_in" "10"     "$tok_in"
assert_eq "fake tok_out" "5"     "$tok_out"
assert_eq "fake turns"  "1"      "$turns"

# ============================================================
echo ""
echo "=== 8. Fake driver — settings is a no-op ==="

WORK2="$TMPDIR/workspace2"
mkdir -p "$WORK2"
agent_settings "$WORK2"

assert_eq "no settings dir created" "false" \
    "$([ -d "$WORK2/.claude" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 9. Driver field in config parsing ==="

cat > "$TMPDIR/driver_cfg.json" <<'EOF'
{
  "prompt": "p.md",
  "driver": "fake",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" },
    { "count": 1, "model": "gemini-2.5-pro", "driver": "gemini-cli" }
  ]
}
EOF

# Parse driver field from config.
TOP_DRIVER=$(jq -r '.driver // "claude-code"' "$TMPDIR/driver_cfg.json")
assert_eq "top-level driver" "fake" "$TOP_DRIVER"

# Per-agent driver with fallback to top-level.
AGENTS=$(jq -r '.driver as $dd | .agents[] |
    (.driver // $dd // "claude-code")' "$TMPDIR/driver_cfg.json")
LINE1=$(echo "$AGENTS" | sed -n '1p')
LINE2=$(echo "$AGENTS" | sed -n '2p')
assert_eq "agent1 inherits top driver" "fake"       "$LINE1"
assert_eq "agent2 per-agent driver"    "gemini-cli"  "$LINE2"

# No driver field defaults to claude-code.
echo '{"prompt":"p.md","agents":[{"count":1,"model":"m"}]}' > "$TMPDIR/no_driver.json"
DEFAULT=$(jq -r '.driver // "claude-code"' "$TMPDIR/no_driver.json")
assert_eq "default driver" "claude-code" "$DEFAULT"

# ============================================================
echo ""
echo "=== 10. Activity filter reads jq from SWARM_JQ_FILTER_FILE ==="

# Regression test for the process boundary: activity-filter.sh
# runs as a separate process and cannot inherit shell functions
# from the harness.  It reads the jq filter from a file written
# by the harness (SWARM_JQ_FILTER_FILE).

FILTER_DIR="$TESTS_DIR/../lib"

# Test 1: With SWARM_JQ_FILTER_FILE set, the filter file is used.
cat > "$TMPDIR/custom.jq" <<'JQ'
fromjson? // empty |
select(.type == "custom") |
"CUSTOM:" + .name
JQ

CUSTOM_INPUT='{"type":"custom","name":"test-tool"}'
CUSTOM_OUT=$(echo "$CUSTOM_INPUT" | \
    AGENT_ID=1 SWARM_JQ_FILTER_FILE="$TMPDIR/custom.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_eq "custom jq filter from file" "CUSTOM:test-tool" "$CUSTOM_OUT"

# Test 2: Without SWARM_JQ_FILTER_FILE, falls back to built-in Claude filter.
CLAUDE_INPUT='{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"src/main.ts"}}]}}'
FALLBACK_OUT=$(echo "$CLAUDE_INPUT" | \
    AGENT_ID=1 SWARM_JQ_FILTER_FILE="" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "fallback filter reads tool_use" "Read src/main.ts" "$FALLBACK_OUT"

# Test 3: Claude Code driver's agent_activity_jq() produces a
# valid filter that works when written to file (simulating the
# harness→activity-filter process boundary).
source "$DRIVERS_DIR/claude-code.sh"
agent_activity_jq > "$TMPDIR/claude-code.jq"
CC_OUT=$(echo "$CLAUDE_INPUT" | \
    AGENT_ID=2 SWARM_JQ_FILTER_FILE="$TMPDIR/claude-code.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "driver jq via file boundary" "Read src/main.ts" "$CC_OUT"

# Test 4: Fake driver's jq filter works via file boundary too.
source "$DRIVERS_DIR/fake.sh"
agent_activity_jq > "$TMPDIR/fake.jq"
FAKE_INPUT='{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t","name":"DoSomething","input":{}}]}}'
FAKE_OUT=$(echo "$FAKE_INPUT" | \
    AGENT_ID=3 SWARM_JQ_FILTER_FILE="$TMPDIR/fake.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "fake driver jq via file boundary" "DoSomething" "$FAKE_OUT"

# ============================================================
echo ""
echo "=== 11. agent_detect_fatal — Claude Code driver ==="

source "$DRIVERS_DIR/claude-code.sh"

# Fatal: error line with zero tokens.
cat > "$TMPDIR/fatal.jsonl" <<'EOF'
{"error":"model_not_found","message":"The model does not exist"}
{"type":"result","subtype":"error","session_id":"s01","total_cost_usd":0,"is_error":true,"duration_ms":100,"duration_api_ms":0,"num_turns":0,"result":"Error","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
FATAL_OUT=$(agent_detect_fatal "$TMPDIR/fatal.jsonl" 1)
assert_not_empty "fatal error detected" "$FATAL_OUT"
assert_contains "fatal mentions error" "model_not_found" "$FATAL_OUT"

# Non-fatal: error but tokens were produced.
cat > "$TMPDIR/nonfatal.jsonl" <<'EOF'
{"error":"rate_limited","message":"Slow down"}
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.05,"is_error":false,"duration_ms":5000,"duration_api_ms":4000,"num_turns":3,"result":"Done","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
NONFATAL_OUT=$(agent_detect_fatal "$TMPDIR/nonfatal.jsonl" 0)
assert_eq "non-fatal not flagged" "" "$NONFATAL_OUT"

# No error at all.
cat > "$TMPDIR/clean.jsonl" <<'EOF'
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.10,"is_error":false,"duration_ms":10000,"duration_api_ms":8000,"num_turns":5,"result":"Done","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
CLEAN_OUT=$(agent_detect_fatal "$TMPDIR/clean.jsonl" 0)
assert_eq "clean log not flagged" "" "$CLEAN_OUT"

# ============================================================
echo ""
echo "=== 12. agent_detect_fatal — Fake driver ==="

source "$DRIVERS_DIR/fake.sh"

FAKE_FATAL=$(agent_detect_fatal "$TMPDIR/fatal.jsonl" 1)
assert_eq "fake driver never fatal" "" "$FAKE_FATAL"

# ============================================================
echo ""
echo "=== 13. agent_docker_env — Claude Code driver ==="

source "$DRIVERS_DIR/claude-code.sh"

ENV_OUT=$(agent_docker_env "high")
assert_not_empty "cc docker_env non-empty" "$ENV_OUT"
assert_contains "cc docker_env has CLAUDE_CODE_EFFORT_LEVEL" \
    "CLAUDE_CODE_EFFORT_LEVEL=high" "$ENV_OUT"

ENV_EMPTY=$(agent_docker_env "")
assert_eq "cc docker_env empty effort" "" "$ENV_EMPTY"

# ============================================================
echo ""
echo "=== 14. agent_docker_env — Fake driver ==="

source "$DRIVERS_DIR/fake.sh"

FAKE_ENV=$(agent_docker_env "high")
assert_eq "fake docker_env is no-op" "" "$FAKE_ENV"

# ============================================================
echo ""
echo "=== 15. _common.sh — shared stats helper ==="

source "$DRIVERS_DIR/_common.sh"

cat > "$TMPDIR/common_test.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s01","tools":["Bash"],"model":"test"}
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.42,"is_error":false,"duration_ms":5000,"duration_api_ms":4000,"num_turns":3,"result":"OK","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":500}}
EOF

STATS=$(_extract_jsonl_stats "$TMPDIR/common_test.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "common cost"     "0.42"  "$cost"
assert_eq "common tok_in"   "200"   "$tok_in"
assert_eq "common tok_out"  "100"   "$tok_out"
assert_eq "common cache_rd" "3000"  "$cache_rd"
assert_eq "common cache_cr" "500"   "$cache_cr"
assert_eq "common dur"      "5000"  "$dur"
assert_eq "common api_ms"   "4000"  "$api_ms"
assert_eq "common turns"    "3"     "$turns"

# Empty file: all zeroes.
: > "$TMPDIR/common_empty.jsonl"
STATS=$(_extract_jsonl_stats "$TMPDIR/common_empty.jsonl")
IFS=$'\t' read -r cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$STATS"
assert_eq "common empty cost"  "0" "$cost"
assert_eq "common empty turns" "0" "$turns"

# ============================================================
echo ""
echo "=== 16. Driver interface completeness ==="

_required_fns=(agent_default_model agent_name agent_cmd agent_version
               agent_run agent_settings agent_extract_stats
               agent_activity_jq agent_docker_auth)

source "$DRIVERS_DIR/claude-code.sh"
for fn in "${_required_fns[@]}"; do
    assert_eq "cc has $fn" "true" \
        "$(type -t "$fn" &>/dev/null && echo true || echo false)"
done

source "$DRIVERS_DIR/fake.sh"
for fn in "${_required_fns[@]}"; do
    assert_eq "fake has $fn" "true" \
        "$(type -t "$fn" &>/dev/null && echo true || echo false)"
done

source "$DRIVERS_DIR/gemini-cli.sh"
for fn in "${_required_fns[@]}"; do
    assert_eq "gemini has $fn" "true" \
        "$(type -t "$fn" &>/dev/null && echo true || echo false)"
done

# ============================================================
echo ""
echo "=== 17. Gemini CLI driver — role interface ==="

assert_eq "gemini-cli driver exists" "true" \
    "$([ -f "$DRIVERS_DIR/gemini-cli.sh" ] && echo true || echo false)"

source "$DRIVERS_DIR/gemini-cli.sh"

assert_eq "gemini-cli name"    "Gemini CLI"     "$(agent_name)"
assert_eq "gemini-cli cmd"     "gemini"         "$(agent_cmd)"
assert_eq "gemini-cli default" "gemini-2.5-pro" "$(agent_default_model)"

GEM_JQ=$(agent_activity_jq)
assert_not_empty "gemini-cli jq filter" "$GEM_JQ"
assert_contains "gemini-cli jq has tool_use" "tool_use" "$GEM_JQ"
assert_contains "gemini-cli jq has run_shell_command" "run_shell_command" "$GEM_JQ"

GEM_INSTALL=$(agent_install_cmd)
assert_contains "gemini-cli install has npm" "npm" "$GEM_INSTALL"
assert_contains "gemini-cli install has @google/gemini-cli" "@google/gemini-cli" "$GEM_INSTALL"

# ============================================================
echo ""
echo "=== 18. Gemini CLI driver — agent_settings ==="

GWORK="$TMPDIR/gem-workspace"
mkdir -p "$GWORK"
agent_settings "$GWORK"

assert_eq "gemini settings file created" "true" \
    "$([ -f "$GWORK/.gemini/settings.json" ] && echo true || echo false)"
assert_eq "gemini settings valid JSON" "true" \
    "$(jq empty "$GWORK/.gemini/settings.json" 2>/dev/null && echo true || echo false)"

# ============================================================
echo ""
echo "=== 19. Gemini CLI driver — agent_extract_stats ==="

cat > "$TMPDIR/gemini-session.jsonl" <<'EOF'
{"type":"init","model":"gemini-2.5-pro","tools":["shell","read_file","write_file"]}
{"type":"tool_call","name":"shell","input":"ls -la"}
{"type":"result","stats":{"input_tokens":800,"output_tokens":200,"cached":5000,"duration_ms":12000,"tool_calls":4}}
EOF

GSTATS=$(agent_extract_stats "$TMPDIR/gemini-session.jsonl")
IFS=$'\t' read -r g_cost g_in g_out g_cache_rd g_cache_cr g_dur g_api_ms g_turns <<< "$GSTATS"

assert_eq "gemini cost is 0 (not tracked)" "0"     "$g_cost"
assert_eq "gemini tok_in"                  "800"   "$g_in"
assert_eq "gemini tok_out"                 "200"   "$g_out"
assert_eq "gemini cached"                  "5000"  "$g_cache_rd"
assert_eq "gemini cache_cr"                "0"     "$g_cache_cr"
assert_eq "gemini duration"                "12000" "$g_dur"
assert_eq "gemini turns = tool_calls"      "4"     "$g_turns"

# Empty result: all zeroes.
: > "$TMPDIR/gemini-empty.jsonl"
GSTATS_EMPTY=$(agent_extract_stats "$TMPDIR/gemini-empty.jsonl")
IFS=$'\t' read -r g_cost g_in g_out g_cache_rd g_cache_cr g_dur g_api_ms g_turns <<< "$GSTATS_EMPTY"
assert_eq "gemini empty cost"  "0" "$g_cost"
assert_eq "gemini empty turns" "0" "$g_turns"

# ============================================================
echo ""
echo "=== 20. Gemini CLI driver — agent_detect_fatal ==="

cat > "$TMPDIR/gemini-fatal.jsonl" <<'EOF'
{"type":"error","message":"API key invalid","severity":"fatal"}
EOF
GFATAL=$(agent_detect_fatal "$TMPDIR/gemini-fatal.jsonl" 1)
assert_not_empty "gemini fatal detected" "$GFATAL"
assert_contains "gemini fatal message" "API key invalid" "$GFATAL"

cat > "$TMPDIR/gemini-clean.jsonl" <<'EOF'
{"type":"result","stats":{"input_tokens":100,"output_tokens":50,"cached":0,"duration_ms":5000,"tool_calls":2}}
EOF
GCLEAN=$(agent_detect_fatal "$TMPDIR/gemini-clean.jsonl" 0)
assert_eq "gemini clean not flagged" "" "$GCLEAN"

# Quota exhaustion: result event with status:"error" (not a separate error event).
cat > "$TMPDIR/gemini-quota.jsonl" <<'EOF'
{"type":"init","timestamp":"2026-03-18T09:51:40.322Z","session_id":"test","model":"gemini-3.1-pro-preview"}
{"type":"result","timestamp":"2026-03-18T09:51:40.600Z","status":"error","error":{"type":"Error","message":"[API Error: You have exhausted your daily quota on this model.]"},"stats":{"total_tokens":0,"input_tokens":0,"output_tokens":0,"cached":0,"input":0,"duration_ms":0,"tool_calls":0}}
EOF
GQUOTA=$(agent_detect_fatal "$TMPDIR/gemini-quota.jsonl" 1)
assert_not_empty "gemini quota error detected" "$GQUOTA"
assert_contains "gemini quota message" "quota" "$GQUOTA"

# Quota with retry delay in stderr.
cat > "$TMPDIR/gemini-quota.jsonl.err" <<'EOF'
TerminalQuotaError: You have exhausted your daily quota on this model.
Please retry in 14h8m19.430128398s.
EOF
GQUOTA_RETRY=$(agent_detect_fatal "$TMPDIR/gemini-quota.jsonl" 1)
assert_contains "gemini quota has retry" "retry in 14h8m19" "$GQUOTA_RETRY"

# Auth error via result status (no .err file with retry).
cat > "$TMPDIR/gemini-auth-err.jsonl" <<'EOF'
{"type":"result","status":"error","error":{"type":"Error","message":"[API Error: Invalid API key]"},"stats":{"total_tokens":0,"input_tokens":0,"output_tokens":0}}
EOF
GAUTH=$(agent_detect_fatal "$TMPDIR/gemini-auth-err.jsonl" 1)
assert_not_empty "gemini auth error detected" "$GAUTH"
assert_contains "gemini auth message" "Invalid API key" "$GAUTH"

# Tool-level errors (tool_result with status:"error") must NOT be treated as fatal.
cat > "$TMPDIR/gemini-tool-err.jsonl" <<'EOF'
{"type":"tool_result","timestamp":"2026-03-18T12:27:29.716Z","tool_id":"hp3irmrr","status":"error","output":"File not found.","error":{"type":"file_not_found","message":"File not found: /workspace/targets/Foo/Bar.cs"}}
{"type":"tool_result","timestamp":"2026-03-18T12:57:09.792Z","tool_id":"8m6f5t7c","status":"error","output":"Error: Failed to edit","error":{"type":"edit_no_occurrence_found","message":"Failed to edit"}}
{"type":"result","timestamp":"2026-03-18T13:21:18.397Z","status":"success","stats":{"total_tokens":4953705,"input_tokens":4924523,"output_tokens":13596,"cached":0,"input":0,"duration_ms":4054153,"tool_calls":95}}
EOF
GTOOL=$(agent_detect_fatal "$TMPDIR/gemini-tool-err.jsonl" 0)
assert_eq "tool_result errors not fatal" "" "$GTOOL"

# ============================================================
echo ""
echo "=== 21. agent_default_model — all drivers ==="

source "$DRIVERS_DIR/claude-code.sh"
assert_eq "cc default model" "claude-opus-4-6" "$(agent_default_model)"

source "$DRIVERS_DIR/fake.sh"
assert_eq "fake default model" "fake-model" "$(agent_default_model)"

source "$DRIVERS_DIR/gemini-cli.sh"
assert_eq "gemini default model" "gemini-2.5-pro" "$(agent_default_model)"

# ============================================================
echo ""
echo "=== 22. agent_docker_auth — Claude Code driver ==="

source "$DRIVERS_DIR/claude-code.sh"

# OAuth mode.
CLAUDE_CODE_OAUTH_TOKEN="test-oauth" \
ANTHROPIC_API_KEY="" \
AUTH_OUT=$(agent_docker_auth "" "" "oauth" "")
assert_contains "cc auth oauth has CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_OAUTH_TOKEN" "$AUTH_OUT"
assert_contains "cc auth oauth label" "SWARM_AUTH_MODE=oauth" "$AUTH_OUT"

# API key mode.
AUTH_OUT=$(ANTHROPIC_API_KEY="sk-test" agent_docker_auth "" "" "apikey" "")
assert_contains "cc auth key has ANTHROPIC_API_KEY" "ANTHROPIC_API_KEY=sk-test" "$AUTH_OUT"
assert_contains "cc auth key label" "SWARM_AUTH_MODE=key" "$AUTH_OUT"

# Auth token (OpenRouter) mode.
AUTH_OUT=$(agent_docker_auth "" "or-token-123" "" "https://openrouter.ai/api")
assert_contains "cc auth token has ANTHROPIC_AUTH_TOKEN=or-token" "ANTHROPIC_AUTH_TOKEN=or-token-123" "$AUTH_OUT"
assert_contains "cc auth token has base_url" "ANTHROPIC_BASE_URL=https://openrouter.ai/api" "$AUTH_OUT"
assert_contains "cc auth token label" "SWARM_AUTH_MODE=token" "$AUTH_OUT"

# ============================================================
echo ""
echo "=== 23. agent_docker_auth — Gemini CLI driver ==="

source "$DRIVERS_DIR/gemini-cli.sh"

# Native key.
AUTH_OUT=$(GEMINI_API_KEY="gkey-123" agent_docker_auth "" "" "" "")
assert_contains "gemini auth native key" "GEMINI_API_KEY=gkey-123" "$AUTH_OUT"
assert_contains "gemini auth native label" "SWARM_AUTH_MODE=key" "$AUTH_OUT"

# OpenRouter via auth_token.
AUTH_OUT=$(agent_docker_auth "" "or-key-456" "" "https://openrouter.ai/api")
assert_contains "gemini auth openrouter key" "OPENROUTER_API_KEY=or-key-456" "$AUTH_OUT"
assert_contains "gemini auth openrouter base" "GEMINI_API_BASE=https://openrouter.ai/api" "$AUTH_OUT"
assert_contains "gemini auth openrouter label" "SWARM_AUTH_MODE=openrouter" "$AUTH_OUT"

# ============================================================
echo ""
echo "=== 24. agent_docker_auth — Fake driver ==="

source "$DRIVERS_DIR/fake.sh"

AUTH_OUT=$(agent_docker_auth "" "" "" "")
assert_contains "fake auth has empty SWARM_AUTH_MODE" "SWARM_AUTH_MODE=" "$AUTH_OUT"

# ============================================================
echo ""
echo "=== 25. agent_docker_env — Gemini CLI driver ==="

source "$DRIVERS_DIR/gemini-cli.sh"

GEM_ENV=$(agent_docker_env "high")
assert_eq "gemini docker_env is no-op" "" "$GEM_ENV"

# ============================================================
echo ""
echo "=== 26. Gemini CLI — activity jq filter via file boundary ==="

source "$DRIVERS_DIR/gemini-cli.sh"
agent_activity_jq > "$TMPDIR/gemini.jq"

GEMINI_INPUT='{"type":"tool_use","tool_name":"run_shell_command","tool_id":"abc","parameters":{"command":"ls -la"}}'
GEM_ACT_OUT=$(echo "$GEMINI_INPUT" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq via file boundary" "Shell:" "$GEM_ACT_OUT"

GEMINI_READ='{"type":"tool_use","tool_name":"read_file","tool_id":"xyz","parameters":{"file_path":"src/main.cs"}}'
GEM_READ_OUT=$(echo "$GEMINI_READ" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq read_file" "Read " "$GEM_READ_OUT"
assert_contains "gemini jq read_file path" "src/main.cs" "$GEM_READ_OUT"

GEMINI_GREP='{"type":"tool_use","tool_name":"grep_search","tool_id":"g1","parameters":{"pattern":"async void"}}'
GEM_GREP_OUT=$(echo "$GEMINI_GREP" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq grep_search" "Grep " "$GEM_GREP_OUT"

GEMINI_WRITE='{"type":"tool_use","tool_name":"write_file","tool_id":"w1","parameters":{"file_path":"out.cs"}}'
GEM_WRITE_OUT=$(echo "$GEMINI_WRITE" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq write_file" "Write " "$GEM_WRITE_OUT"
assert_contains "gemini jq write_file path" "out.cs" "$GEM_WRITE_OUT"

GEMINI_EDIT='{"type":"tool_use","tool_name":"edit_file","tool_id":"e1","parameters":{"file_path":"src/lib.cs"}}'
GEM_EDIT_OUT=$(echo "$GEMINI_EDIT" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq edit_file" "Edit " "$GEM_EDIT_OUT"

GEMINI_LIST='{"type":"tool_use","tool_name":"list_directory","tool_id":"l1","parameters":{"dir_path":"src/"}}'
GEM_LIST_OUT=$(echo "$GEMINI_LIST" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq list_directory" "List " "$GEM_LIST_OUT"

GEMINI_UNKNOWN='{"type":"tool_use","tool_name":"some_custom_tool","tool_id":"u1","parameters":{}}'
GEM_UNK_OUT=$(echo "$GEMINI_UNKNOWN" | \
    AGENT_ID=5 SWARM_JQ_FILTER_FILE="$TMPDIR/gemini.jq" \
    bash "$FILTER_DIR/activity-filter.sh" 2>/dev/null || true)
assert_contains "gemini jq unknown tool" "some_custom_tool" "$GEM_UNK_OUT"

# ============================================================
echo ""
echo "=== 27. Gemini CLI — agent_extract_stats with real production output ==="

source "$DRIVERS_DIR/gemini-cli.sh"

cat > "$TMPDIR/gemini-real.jsonl" <<'EOF'
{"type":"init","timestamp":"2026-03-18T08:56:37.918Z","session_id":"f169e2f8","model":"gemini-3.1-pro-preview-customtools"}
{"type":"tool_use","timestamp":"2026-03-18T08:56:44.708Z","tool_name":"read_file","tool_id":"cm9i42ry","parameters":{"file_path":"README.md"}}
{"type":"tool_result","timestamp":"2026-03-18T08:56:45.388Z","tool_id":"cm9i42ry","status":"success","output":""}
{"type":"result","timestamp":"2026-03-18T09:06:35.031Z","status":"success","stats":{"total_tokens":5395341,"input_tokens":5356301,"output_tokens":5498,"cached":4713012,"input":643289,"duration_ms":597113,"tool_calls":92,"models":{"gemini-3.1-pro-preview-customtools":{"total_tokens":5362869,"input_tokens":5325058,"output_tokens":5261,"cached":4713012,"input":612046},"gemini-3-flash-preview":{"total_tokens":32472,"input_tokens":31243,"output_tokens":237,"cached":0,"input":31243}}}}
EOF

GSTATS=$(agent_extract_stats "$TMPDIR/gemini-real.jsonl")
IFS=$'\t' read -r g_cost g_in g_out g_cache_rd g_cache_cr g_dur g_api_ms g_turns <<< "$GSTATS"

assert_eq "real gemini cost"      "0"       "$g_cost"
assert_eq "real gemini input"     "5356301" "$g_in"
assert_eq "real gemini output"    "5498"    "$g_out"
assert_eq "real gemini cached"    "4713012" "$g_cache_rd"
assert_eq "real gemini cache_cr"  "0"       "$g_cache_cr"
assert_eq "real gemini duration"  "597113"  "$g_dur"
assert_eq "real gemini turns"     "92"      "$g_turns"

# ============================================================
echo ""
echo "=== 28. agent_docker_auth edge cases — Gemini CLI ==="

source "$DRIVERS_DIR/gemini-cli.sh"

# Per-agent api_key overrides GEMINI_API_KEY env.
AUTH_OUT=$(GEMINI_API_KEY="env-key" agent_docker_auth "per-agent-key" "" "" "")
assert_contains "gemini per-agent key" "GEMINI_API_KEY=per-agent-key" "$AUTH_OUT"

# No credentials at all — no key flags, still sets SWARM_AUTH_MODE.
AUTH_OUT=$(GEMINI_API_KEY="" agent_docker_auth "" "" "" "")
assert_contains "gemini no creds has auth mode" "SWARM_AUTH_MODE=" "$AUTH_OUT"
_line_count=$(echo "$AUTH_OUT" | grep -c "GEMINI_API_KEY" || true)
assert_eq "gemini no creds no key flag" "0" "$_line_count"

# OpenRouter without base_url (just auth_token).
AUTH_OUT=$(agent_docker_auth "" "or-key" "" "")
assert_contains "gemini openrouter no base" "OPENROUTER_API_KEY=or-key" "$AUTH_OUT"
_base_count=$(echo "$AUTH_OUT" | grep -c "GEMINI_API_BASE" || true)
assert_eq "gemini openrouter no base_url flag" "0" "$_base_count"

# ============================================================
echo ""
echo "=== 29. agent_docker_auth edge cases — Claude Code ==="

source "$DRIVERS_DIR/claude-code.sh"

# Auto mode: both ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN set, no auth field.
AUTH_OUT=$(ANTHROPIC_API_KEY="sk-auto" CLAUDE_CODE_OAUTH_TOKEN="oat-auto" \
    agent_docker_auth "" "" "" "")
assert_contains "cc auto has api key" "ANTHROPIC_API_KEY=sk-auto" "$AUTH_OUT"
assert_contains "cc auto has oauth" "CLAUDE_CODE_OAUTH_TOKEN=oat-auto" "$AUTH_OUT"
assert_contains "cc auto label" "SWARM_AUTH_MODE=auto" "$AUTH_OUT"

# Per-agent api_key overrides env.
AUTH_OUT=$(ANTHROPIC_API_KEY="env-key" agent_docker_auth "agent-key" "" "" "")
assert_contains "cc per-agent key" "ANTHROPIC_API_KEY=agent-key" "$AUTH_OUT"

# No credentials at all.
AUTH_OUT=$(ANTHROPIC_API_KEY="" CLAUDE_CODE_OAUTH_TOKEN="" \
    agent_docker_auth "" "" "" "")
assert_contains "cc no creds has auth mode" "SWARM_AUTH_MODE=" "$AUTH_OUT"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
