#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for lib/activity-filter.sh.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="$TESTS_DIR/../lib/activity-filter.sh"

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

# Strip ANSI escape codes and the HH:MM:SS timestamp prefix.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
strip_ts() { strip_ansi | sed 's/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]   //'; }

run_filter_raw() {
    AGENT_ID="${1:-1}" "$FILTER" <<< "$2"
}

run_filter() {
    run_filter_raw "$@" | strip_ts
}

# ============================================================
echo "=== 1. Bash tool use ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}')
assert_eq "bash tool" "agent[1] Shell: npm test" "$OUT"

# ============================================================
echo ""
echo "=== 2. Read tool use ==="

OUT=$(run_filter 2 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/main.ts"}}]}}')
assert_eq "read tool" "agent[2] Read src/main.ts" "$OUT"

# ============================================================
echo ""
echo "=== 3. Write tool use ==="

OUT=$(run_filter 3 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"out/result.json"}}]}}')
assert_eq "write tool" "agent[3] Write out/result.json" "$OUT"

# ============================================================
echo ""
echo "=== 4. Edit tool use ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"lib/utils.py"}}]}}')
assert_eq "edit tool" "agent[1] Edit lib/utils.py" "$OUT"

# ============================================================
echo ""
echo "=== 5. Long command truncation ==="

LONG_CMD="echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa very long"
OUT=$(run_filter 1 "{\"type\":\"assistant\",\"session_id\":\"s\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"$LONG_CMD\"}}]}}")
assert_contains "truncated" "..." "$OUT"
# After strip_ts: agent[1] Shell: (16) + 80 chars = 96.
LINE_LEN=${#OUT}
if [ "$LINE_LEN" -le 96 ]; then
    echo "  PASS: line length <= 96 (got ${LINE_LEN})"
    PASS=$((PASS + 1))
else
    echo "  FAIL: line length <= 96 (got ${LINE_LEN})"
    FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== 6. Multi-line command uses first line ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo hello\necho world"}}]}}')
assert_eq "first line only" "agent[1] Shell: echo hello" "$OUT"

# ============================================================
echo ""
echo "=== 7. Non-tool events are silent ==="

OUT=$(run_filter 1 '{"type":"system","subtype":"init","session_id":"s","tools":["Bash"]}')
assert_eq "system event silent" "" "$OUT"

OUT=$(run_filter 1 '{"type":"result","subtype":"success","session_id":"s","total_cost_usd":0.01}')
assert_eq "result event silent" "" "$OUT"

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"Thinking..."}]}}')
assert_eq "text event silent" "" "$OUT"

# ============================================================
echo ""
echo "=== 8. Thinking content block ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Let me analyze the error in src/main.ts and figure out the root cause.","signature":"sig"}]}}')
assert_eq "thinking displayed" "agent[1] Think: Let me analyze the error in src/main.ts and figure out the root cause." "$OUT"

LONG_THINK="This is a very long thinking block that should be truncated because it exceeds the eighty character limit for display purposes in the activity stream"
OUT=$(run_filter 1 "{\"type\":\"assistant\",\"session_id\":\"s\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"$LONG_THINK\",\"signature\":\"sig\"}]}}")
assert_contains "thinking truncated" "..." "$OUT"

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Line one\nLine two\nLine three","signature":"sig"}]}}')
assert_eq "thinking first line only" "agent[1] Think: Line one" "$OUT"

# Thinking + tool_use in same message — both displayed.
OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Plan the edit","signature":"sig"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"x.ts"}}]}}')
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
assert_eq "thinking + tool both shown" "2" "$LINES"
assert_contains "thinking line present" "Think: Plan the edit" "$OUT"
assert_contains "tool line present" "Edit x.ts" "$OUT"

# ============================================================
echo ""
echo "=== 9. Multiple tool uses in one message ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.ts"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"b.ts"}}]}}')
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
assert_eq "two lines" "2" "$LINES"
assert_contains "first file" "Read a.ts" "$OUT"
assert_contains "second file" "Read b.ts" "$OUT"

# ============================================================
echo ""
echo "=== 10. Invalid JSON is silently skipped ==="

OUT=$(run_filter 1 'not json at all')
assert_eq "garbage skipped" "" "$OUT"

OUT=$(run_filter 1 '{"partial": true')
assert_eq "partial json skipped" "" "$OUT"

# ============================================================
echo ""
echo "=== 11. Multi-line JSONL stream ==="

cat > "$TMPDIR/stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s","tools":["Bash","Read"]}
{"type":"assistant","session_id":"s","message":{"id":"m1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"README.md"}}]}}
{"type":"user","session_id":"s","message":{"id":"m2","type":"message","role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"# Hello"}]}}
{"type":"assistant","session_id":"s","message":{"id":"m3","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make build"}}]}}
{"type":"result","subtype":"success","session_id":"s","total_cost_usd":0.05}
EOF

OUT=$(AGENT_ID=5 "$FILTER" < "$TMPDIR/stream.jsonl" | strip_ts)
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
assert_eq "two activity lines" "2" "$LINES"
assert_contains "read event" "agent[5] Read README.md" "$OUT"
assert_contains "shell event" "agent[5] Shell: make build" "$OUT"

# ============================================================
echo ""
echo "=== 12. Glob and Grep tools ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Glob","input":{"pattern":"**/*.ts"}}]}}')
assert_eq "glob tool" "agent[1] Glob **/*.ts" "$OUT"

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"TODO"}}]}}')
assert_eq "grep tool" "agent[1] Grep TODO" "$OUT"

# ============================================================
echo ""
echo "=== 13. Task tool ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Task","input":{"description":"Fix lint errors"}}]}}')
assert_eq "task tool" "agent[1] Task: Fix lint errors" "$OUT"

# ============================================================
echo ""
echo "=== 14. Unknown tool ==="

OUT=$(run_filter 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{"query":"test"}}]}}')
assert_eq "unknown tool fallback" "agent[1] WebSearch" "$OUT"

# ============================================================
echo ""
echo "=== 15. Default AGENT_ID ==="

OUT=$(AGENT_ID="" "$FILTER" <<< '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pwd"}}]}}' | strip_ts)
assert_contains "empty id uses default" "agent[?] Shell: pwd" "$OUT"

# ============================================================
echo ""
echo "=== 16. Timestamp prefix format ==="

RAW=$(run_filter_raw 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pwd"}}]}}')
PLAIN=$(echo "$RAW" | strip_ansi)
TS_MATCH=$(echo "$PLAIN" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || true)
if [ -n "$TS_MATCH" ]; then
    echo "  PASS: has HH:MM:SS timestamp"
    PASS=$((PASS + 1))
else
    echo "  FAIL: has HH:MM:SS timestamp"
    echo "        actual: ${PLAIN}"
    FAIL=$((FAIL + 1))
fi
assert_contains "ts prefix format" "agent[1]" "$PLAIN"

# Verify 3-space padding aligns agent with harness.
AFTER_TS="${PLAIN#????????}"
PAD_SPACES="${AFTER_TS%%agent*}"
assert_eq "agent padded 3 spaces" "   " "$PAD_SPACES"

# ============================================================
echo ""
echo "=== 17. ANSI color — full line yellow ==="

RAW=$(run_filter_raw 1 '{"type":"assistant","session_id":"s","message":{"id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pwd"}}]}}')

# Yellow open (\033[33m) should appear before the timestamp.
_esc=$(printf '\033')
if printf '%s' "$RAW" | grep -q "${_esc}\[33m"; then
    echo "  PASS: has yellow ANSI open"
    PASS=$((PASS + 1))
else
    echo "  FAIL: has yellow ANSI open"
    FAIL=$((FAIL + 1))
fi

# Reset (\033[0m) should appear after the tool content.
if printf '%s' "$RAW" | grep -q "${_esc}\[0m"; then
    echo "  PASS: has ANSI reset"
    PASS=$((PASS + 1))
else
    echo "  FAIL: has ANSI reset"
    FAIL=$((FAIL + 1))
fi

# The tool name should be inside the colored region (before reset).
BEFORE_RESET=$(printf '%s' "$RAW" | sed 's/\x1b\[0m.*//')
assert_contains "tool before reset" "Shell: pwd" "$BEFORE_RESET"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
