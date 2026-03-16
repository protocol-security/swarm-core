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
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
