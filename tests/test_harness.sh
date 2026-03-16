#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for harness.sh stat extraction and logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- Helpers: same extraction logic used in harness.sh ---
# The harness now uses stream-json (JSONL) output. Stats come from
# the "result" line. For backward compat the helper also accepts
# plain JSON (single object, no "type" field).

extract_stats() {
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
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns"
}

# ============================================================
echo "=== 1. Full JSON output parsing ==="

cat > "$TMPDIR/full.json" <<'EOF'
{
  "total_cost_usd": 0.1292,
  "duration_ms": 19000,
  "duration_api_ms": 15000,
  "num_turns": 6,
  "usage": {
    "input_tokens": 800,
    "output_tokens": 644,
    "cache_read_input_tokens": 117000,
    "cache_creation_input_tokens": 5000
  }
}
EOF

LINE=$(extract_stats "$TMPDIR/full.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.1292"  "$cost"
assert_eq "tok_in"   "800"     "$tok_in"
assert_eq "tok_out"  "644"     "$tok_out"
assert_eq "cache_rd" "117000"  "$cache_rd"
assert_eq "cache_cr" "5000"    "$cache_cr"
assert_eq "dur"      "19000"   "$dur"
assert_eq "api_ms"   "15000"   "$api_ms"
assert_eq "turns"    "6"       "$turns"

# ============================================================
echo ""
echo "=== 2. Minimal JSON (missing fields default to 0) ==="

cat > "$TMPDIR/minimal.json" <<'EOF'
{ "total_cost_usd": 0.05 }
EOF

LINE=$(extract_stats "$TMPDIR/minimal.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.05" "$cost"
assert_eq "tok_in"   "0"    "$tok_in"
assert_eq "tok_out"  "0"    "$tok_out"
assert_eq "cache_rd" "0"    "$cache_rd"
assert_eq "dur"      "0"    "$dur"
assert_eq "turns"    "0"    "$turns"

# ============================================================
echo ""
echo "=== 3. Invalid JSON fallback ==="

echo "not json at all" > "$TMPDIR/garbage.txt"

LINE=$(extract_stats "$TMPDIR/garbage.txt")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost fallback"  "0" "$cost"
assert_eq "turns fallback" "0" "$turns"
assert_eq "dur fallback"   "0" "$dur"

# ============================================================
echo ""
echo "=== 4. Empty file fallback ==="

: > "$TMPDIR/empty.json"

LINE=$(extract_stats "$TMPDIR/empty.json")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost empty"  "0" "$cost"
assert_eq "turns empty" "0" "$turns"

# ============================================================
echo ""
echo "=== 5. Stream-JSON (JSONL) output parsing ==="

cat > "$TMPDIR/stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s01","tools":["Bash","Read","Write"],"model":"claude-opus-4-6"}
{"type":"assistant","session_id":"s01","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la"}}]}}
{"type":"user","session_id":"s01","message":{"id":"msg_2","type":"message","role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"README.md\nsrc\n"}]}}
{"type":"result","subtype":"success","session_id":"s01","total_cost_usd":0.0823,"is_error":false,"duration_ms":25000,"duration_api_ms":20000,"num_turns":4,"result":"Done.","usage":{"input_tokens":500,"output_tokens":300,"cache_read_input_tokens":80000,"cache_creation_input_tokens":2000}}
EOF

LINE=$(extract_stats "$TMPDIR/stream.jsonl")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "jsonl cost"     "0.0823"  "$cost"
assert_eq "jsonl tok_in"   "500"     "$tok_in"
assert_eq "jsonl tok_out"  "300"     "$tok_out"
assert_eq "jsonl cache_rd" "80000"   "$cache_rd"
assert_eq "jsonl cache_cr" "2000"    "$cache_cr"
assert_eq "jsonl dur"      "25000"   "$dur"
assert_eq "jsonl api_ms"   "20000"   "$api_ms"
assert_eq "jsonl turns"    "4"       "$turns"

# ============================================================
echo ""
echo "=== 6. TSV line format ==="

LINE=$(extract_stats "$TMPDIR/full.json")
FIELD_COUNT=$(echo "$LINE" | awk -F'\t' '{print NF}')
assert_eq "9 tab-separated fields" "9" "$FIELD_COUNT"

# ============================================================
echo ""
echo "=== 7. INJECT_GIT_RULES logic ==="

build_append_args() {
    local inject="$1" file_exists="$2"
    local -a APPEND_ARGS=()
    if [ "$inject" = "true" ] && [ "$file_exists" = "true" ]; then
        APPEND_ARGS+=(--append-system-prompt-file /agent-system-prompt.md)
    fi
    echo "${#APPEND_ARGS[@]}"
}

assert_eq "inject=true, file=true"   "2" "$(build_append_args true true)"
assert_eq "inject=false, file=true"  "0" "$(build_append_args false true)"
assert_eq "inject=true, file=false"  "0" "$(build_append_args true false)"
assert_eq "inject=false, file=false" "0" "$(build_append_args false false)"

# ============================================================
echo ""
echo "=== 8. Idle counter logic ==="

simulate_idle() {
    local before="$1" after="$2" idle_count="$3" max_idle="$4"
    if [ "$before" = "$after" ]; then
        idle_count=$((idle_count + 1))
        if [ "$idle_count" -ge "$max_idle" ]; then
            echo "exit"
        else
            echo "idle:${idle_count}"
        fi
    else
        echo "reset"
    fi
}

assert_eq "same SHA increments"    "idle:1"  "$(simulate_idle abc123 abc123 0 3)"
assert_eq "same SHA at limit"      "exit"    "$(simulate_idle abc123 abc123 2 3)"
assert_eq "different SHA resets"   "reset"   "$(simulate_idle abc123 def456 2 3)"
assert_eq "max_idle=1 immediate"   "exit"    "$(simulate_idle abc123 abc123 0 1)"

# ============================================================
echo ""
echo "=== 8b. Idle state file ==="

# Mirrors the idle file write/clear logic in harness.sh.
simulate_idle_file() {
    local before="$1" after="$2" idle_count="$3" max_idle="$4"
    local idle_file="$TMPDIR/idle_test"
    if [ "$before" = "$after" ]; then
        idle_count=$((idle_count + 1))
        printf '%s/%s\n' "$idle_count" "$max_idle" > "$idle_file"
    else
        idle_count=0
        rm -f "$idle_file"
    fi
    if [ -f "$idle_file" ]; then
        cat "$idle_file"
    else
        echo "cleared"
    fi
}

assert_eq "idle file written"    "1/3"     "$(simulate_idle_file abc123 abc123 0 3)"
assert_eq "idle file increments" "2/3"     "$(simulate_idle_file abc123 abc123 1 3)"
assert_eq "idle file at limit"   "3/3"     "$(simulate_idle_file abc123 abc123 2 3)"
assert_eq "idle file cleared"    "cleared" "$(simulate_idle_file abc123 def456 2 3)"
assert_eq "idle file max_idle=1" "1/1"     "$(simulate_idle_file abc123 abc123 0 1)"

# ============================================================
echo ""
echo "=== 8c. Prompt file guard ==="

# Mirrors the guard in harness.sh: skip session if prompt missing.
check_prompt() {
    local prompt_file="$1"
    if [ ! -f "$prompt_file" ]; then
        echo "skip"
    else
        echo "run"
    fi
}

assert_eq "missing prompt skips" "skip" \
    "$(check_prompt "$TMPDIR/nonexistent.md")"

touch "$TMPDIR/exists.md"
assert_eq "present prompt runs" "run" \
    "$(check_prompt "$TMPDIR/exists.md")"

# ============================================================
echo ""
echo "=== 9. prepare-commit-msg hook appends trailers ==="

# Mirrors the hook installed by harness.sh. Exercises it against
# a real git repo so we test actual commit behaviour.
HOOK_REPO="$TMPDIR/hook-repo"
mkdir -p "$HOOK_REPO"
git init -q "$HOOK_REPO"
git -C "$HOOK_REPO" config user.name "test"
git -C "$HOOK_REPO" config user.email "test@test"

mkdir -p "$HOOK_REPO/.git/hooks"
cat > "$HOOK_REPO/.git/hooks/prepare-commit-msg" <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: swarm %s, %s %s\n' \
        "$SWARM_MODEL" "$SWARM_VERSION" "$AGENT_CLI_NAME" "$AGENT_CLI_VERSION" >> "$1"
    printf '> Run: %s\n' "$SWARM_RUN_CONTEXT" >> "$1"
    cfg="$SWARM_CFG_PROMPT"
    [ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
    printf '> Cfg: %s\n' "$cfg" >> "$1"
    ctx_label="$SWARM_CONTEXT"
    [ "$ctx_label" = "none" ] && ctx_label="bare"
    [ "$SWARM_CONTEXT" != "full" ] && \
        printf '> Ctx: %s\n' "$ctx_label" >> "$1" || true
fi
HOOK
chmod +x "$HOOK_REPO/.git/hooks/prepare-commit-msg"

# Commit with prompt + setup (full context = no context trailer).
touch "$HOOK_REPO/file.txt"
git -C "$HOOK_REPO" add file.txt
SWARM_MODEL="claude-opus-4-6" AGENT_CLI_NAME="Claude Code" AGENT_CLI_VERSION="1.0.32" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="netherfuzz@a3f8c21 (main)" \
    SWARM_CFG_PROMPT="prompts/task.md" SWARM_CFG_SETUP="scripts/setup.sh" \
    SWARM_CONTEXT="full" \
    git -C "$HOOK_REPO" commit -m "test commit" --quiet

MSG=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer" \
    "Model: claude-opus-4-6" \
    "$(echo "$MSG" | grep '^Model:')"
assert_eq "hook tools trailer" \
    "Tools: swarm 0.1.0, Claude Code 1.0.32" \
    "$(echo "$MSG" | grep '^Tools:')"
assert_eq "hook run trailer" \
    "> Run: netherfuzz@a3f8c21 (main)" \
    "$(echo "$MSG" | grep '^> Run:')"
assert_eq "hook cfg trailer" \
    "> Cfg: prompts/task.md, scripts/setup.sh" \
    "$(echo "$MSG" | grep '^> Cfg:')"
assert_eq "hook no ctx trailer (full)" \
    "0" \
    "$(echo "$MSG" | grep -c '> Ctx:' || true)"
assert_eq "hook subject preserved" \
    "test commit" \
    "$(echo "$MSG" | head -1)"

# Second commit with bare context (context=none trailer should appear).
echo "x" > "$HOOK_REPO/file2.txt"
git -C "$HOOK_REPO" add file2.txt
SWARM_MODEL="MiniMax-M2.5" AGENT_CLI_NAME="Claude Code" AGENT_CLI_VERSION="1.0.30" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="gethfuzz@b4e9d12 (develop)" \
    SWARM_CFG_PROMPT="prompts/fuzz.md" SWARM_CFG_SETUP="" \
    SWARM_CONTEXT="none" \
    git -C "$HOOK_REPO" commit -m "second commit" --quiet

MSG2=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer 2" \
    "Model: MiniMax-M2.5" \
    "$(echo "$MSG2" | grep '^Model:')"
assert_eq "hook tools trailer 2" \
    "Tools: swarm 0.1.0, Claude Code 1.0.30" \
    "$(echo "$MSG2" | grep '^Tools:')"
assert_eq "hook run trailer 2" \
    "> Run: gethfuzz@b4e9d12 (develop)" \
    "$(echo "$MSG2" | grep '^> Run:')"
assert_eq "hook cfg no setup" \
    "> Cfg: prompts/fuzz.md" \
    "$(echo "$MSG2" | grep '^> Cfg:')"
assert_eq "hook ctx trailer (none)" \
    "> Ctx: bare" \
    "$(echo "$MSG2" | grep '^> Ctx:')"

# Idempotent: if trailers already present, hook does not duplicate.
echo "y" > "$HOOK_REPO/file3.txt"
git -C "$HOOK_REPO" add file3.txt
SWARM_MODEL="claude-opus-4-6" AGENT_CLI_NAME="Claude Code" AGENT_CLI_VERSION="1.0.32" SWARM_VERSION="0.1.0" \
    SWARM_RUN_CONTEXT="test@abc1234 (main)" \
    SWARM_CFG_PROMPT="p.md" SWARM_CFG_SETUP="" \
    SWARM_CONTEXT="full" \
    git -C "$HOOK_REPO" commit -m "$(printf 'manual trailers\n\nModel: already-set')" --quiet

MSG3=$(git -C "$HOOK_REPO" log -1 --format='%B')
MODEL_COUNT=$(echo "$MSG3" | grep -c '^Model:' || true)
assert_eq "hook no duplicate" "1" "$MODEL_COUNT"

# ============================================================
echo ""
echo "=== 10. Version string stripping ==="

# Mirrors the CLAUDE_VERSION="${CLAUDE_VERSION%% *}" in harness.sh.
strip_version() { local v="$1"; echo "${v%% *}"; }

assert_eq "strip suffix"   "2.1.52"  "$(strip_version '2.1.52 (Claude Code)')"
assert_eq "no suffix"      "2.1.52"  "$(strip_version '2.1.52')"
assert_eq "unknown"         "unknown" "$(strip_version 'unknown')"

# ============================================================
echo ""
echo "=== 11. Attribution settings file ==="

# Mirrors the .claude/settings.local.json written by harness.sh.
ATTR_JSON='{"attribution":{"commit":"","pr":""},"env":{"CLAUDE_CODE_ATTRIBUTION_HEADER":"0","CLAUDE_CODE_ENABLE_TELEMETRY":"0","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"}}'
echo "$ATTR_JSON" > "$TMPDIR/settings.local.json"

assert_eq "attr valid JSON" "true" \
    "$(jq empty "$TMPDIR/settings.local.json" 2>/dev/null && echo true || echo false)"
assert_eq "attr commit empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.commit')"
assert_eq "attr pr empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.pr')"
assert_eq "env attribution header" "0" \
    "$(echo "$ATTR_JSON" | jq -r '.env.CLAUDE_CODE_ATTRIBUTION_HEADER')"
assert_eq "env telemetry off" "0" \
    "$(echo "$ATTR_JSON" | jq -r '.env.CLAUDE_CODE_ENABLE_TELEMETRY')"
assert_eq "env nonessential off" "1" \
    "$(echo "$ATTR_JSON" | jq -r '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')"

# ============================================================
echo ""
echo "=== 12. hlog output format ==="

# Mirrors the log functions from harness.sh.
GREEN=$'\033[32m'
RED=$'\033[31m'
RST=$'\033[0m'

hlog() {
    printf '%s%s harness[%s] %s%s\n' \
        "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_err() {
    printf '%s%s harness[%s] %s%s\n' \
        "$RED" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_pipe() {
    while IFS= read -r line; do
        printf '%s%s harness[%s] %s%s\n' \
            "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$line" "$RST"
    done
}

AGENT_ID=3
OUT=$(hlog "test message")
PLAIN=$(echo "$OUT" | strip_ansi)

assert_contains "hlog timestamp" \
    "$(date +%H:%M:%S)" "$PLAIN"
assert_contains "hlog prefix" "harness[3]" "$PLAIN"
assert_contains "hlog body" "test message" "$PLAIN"

# Green wrapping.
assert_contains "hlog green" $'\033[32m' "$OUT"
assert_contains "hlog reset" $'\033[0m' "$OUT"

# key=value style preserved.
AGENT_ID=1
OUT2=$(hlog "session end cost=\$0.18 in=777 out=691 turns=5 time=21s")
PLAIN2=$(echo "$OUT2" | strip_ansi)
assert_contains "hlog kv cost" "cost=\$0.18" "$PLAIN2"
assert_contains "hlog kv in" "in=777" "$PLAIN2"
assert_contains "hlog kv turns" "turns=5" "$PLAIN2"

# Idle message preserves dashboard-parseable pattern.
AGENT_ID=2
OUT3=$(hlog "no commits (idle 1/3)")
IDLE_MATCH=$(echo "$OUT3" | grep -o 'idle [0-9]*/[0-9]*' || true)
assert_eq "hlog idle pattern" "idle 1/3" "$IDLE_MATCH"

# hlog_err uses red.
OUT_ERR=$(hlog_err "prompt file not found")
assert_contains "hlog_err red" $'\033[31m' "$OUT_ERR"
assert_contains "hlog_err reset" $'\033[0m' "$OUT_ERR"
PLAIN_ERR=$(echo "$OUT_ERR" | strip_ansi)
assert_contains "hlog_err body" "prompt file not found" "$PLAIN_ERR"

# hlog_pipe timestamps and colors each line.
PIPE_OUT=$(printf 'line one\nline two\n' | AGENT_ID=7 hlog_pipe)
PIPE_PLAIN=$(echo "$PIPE_OUT" | strip_ansi)
PIPE_LINES=$(echo "$PIPE_PLAIN" | wc -l | tr -d ' ')
assert_eq "hlog_pipe two lines" "2" "$PIPE_LINES"
assert_contains "hlog_pipe line1" "harness[7] line one" "$PIPE_PLAIN"
assert_contains "hlog_pipe line2" "harness[7] line two" "$PIPE_PLAIN"
assert_contains "hlog_pipe green" $'\033[32m' "$PIPE_OUT"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
