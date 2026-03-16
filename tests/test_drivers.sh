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

_required_fns=(agent_name agent_cmd agent_version agent_run
               agent_settings agent_extract_stats agent_activity_jq)

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

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
