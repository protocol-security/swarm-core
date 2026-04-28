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

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Use the shared JSONL stats helper (same code path as production).
source "$TESTS_DIR/../lib/drivers/_common.sh"

# Wraps the shared helper with a timestamp column to match harness output.
extract_stats() {
    local stats
    stats=$(_extract_jsonl_stats "$1")
    printf "%s\t%s" "$(date +%s)" "$stats"
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
git -C "$HOOK_REPO" config commit.gpgsign false

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

# Mirrors the .claude/settings.local.json written by the claude-code driver.
ATTR_JSON='{"attribution":{"commit":"","pr":""},"showThinkingSummaries":true,"env":{"CLAUDE_CODE_ATTRIBUTION_HEADER":"0","CLAUDE_CODE_ENABLE_TELEMETRY":"0","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1"}}'
echo "$ATTR_JSON" > "$TMPDIR/settings.local.json"

assert_eq "attr valid JSON" "true" \
    "$(jq empty "$TMPDIR/settings.local.json" 2>/dev/null && echo true || echo false)"
assert_eq "attr commit empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.commit')"
assert_eq "attr pr empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.pr')"
assert_eq "show thinking summaries on" "true" \
    "$(echo "$ATTR_JSON" | jq -r '.showThinkingSummaries')"
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
echo "=== 13. Pricing-based cost computation ==="

# Mirrors the cost computation logic in harness.sh:
# if cost=0 and SWARM_PRICE_INPUT is set, compute from tokens.
compute_cost() {
    local cost="$1" tok_in="$2" tok_out="$3" cache_rd="$4"
    local price_in="${5:-}" price_out="${6:-}" price_cached="${7:-0}"
    if [ -n "$price_in" ]; then
        cost=$(awk "BEGIN {printf \"%.6f\",
            (${tok_in} * ${price_in} + ${tok_out} * ${price_out} + ${cache_rd} * ${price_cached}) / 1000000}")
    fi
    echo "$cost"
}

# Gemini 2.5 Pro: 100k in, 5k out, 80k cached.
# 100000*1.25 + 5000*10.00 + 80000*0.13 = 125000+50000+10400 = 185400 / 1M = 0.1854
assert_eq "gemini pricing basic" "0.185400" \
    "$(compute_cost 0 100000 5000 80000 1.25 10.00 0.13)"

# Gemini 3.1 Pro: 500k in, 10k out, 200k cached.
assert_eq "gemini 3.1 pricing" "1.160000" \
    "$(compute_cost 0 500000 10000 200000 2.00 12.00 0.20)"

# Flash model: cheaper rates.
# 1000*0.50 + 5000*3.00 + 100*0 = 500+15000+0 = 15500 / 1M = 0.0155
assert_eq "flash pricing" "0.015500" \
    "$(compute_cost 0 1000 5000 100 0.50 3.00 0.0)"

# No cached pricing provided (defaults to 0).
# 100000*0.50 + 5000*10.00 + 80000*0 = 50000+50000 = 100000 / 1M = 0.10
assert_eq "no cached pricing" "0.100000" \
    "$(compute_cost 0 100000 5000 80000 0.50 10.00)"

# Driver reports cost but config pricing overrides it.
assert_eq "config pricing overrides driver" "0.185400" \
    "$(compute_cost 5.55 100000 5000 80000 1.25 10.00 0.13)"

# No pricing configured — cost stays 0.
assert_eq "no pricing stays zero" "0" \
    "$(compute_cost 0 100000 5000 80000)"

# Zero tokens with pricing — cost should be 0.
assert_eq "zero tokens zero cost" "0.000000" \
    "$(compute_cost 0 0 0 0 2.00 12.00 0.20)"

# ============================================================
echo ""
echo "=== 14. Retry backoff logic ==="

# Mirrors the retry decision in harness.sh: when MAX_RETRY_WAIT > 0
# and agent_is_retriable returns non-empty, harness retries instead
# of exiting.
simulate_retry_decision() {
    local fatal_msg="$1" max_retry="$2" retriable="$3"
    if [ -n "$fatal_msg" ]; then
        if [ -n "$retriable" ] && [ "$max_retry" -gt 0 ]; then
            echo "retry"
        else
            echo "exit"
        fi
    else
        echo "ok"
    fi
}

assert_eq "no error → ok" "ok" \
    "$(simulate_retry_decision "" 0 "")"
assert_eq "fatal, no retry → exit" "exit" \
    "$(simulate_retry_decision "rate limited" 0 "")"
assert_eq "fatal, retry disabled → exit" "exit" \
    "$(simulate_retry_decision "rate limited" 0 "rate_limited")"
assert_eq "fatal, retriable, retry on → retry" "retry" \
    "$(simulate_retry_decision "rate limited" 25200 "rate_limited")"
assert_eq "fatal, not retriable, retry on → exit" "exit" \
    "$(simulate_retry_decision "auth error" 25200 "")"

# Zero-token exits become retriable when retry is enabled.
simulate_zero_token_decision() {
    local fatal_msg="$1" max_retry="$2" retriable="$3"
    local zero_token="$4"
    if [ -n "$fatal_msg" ]; then
        local eff_retriable="$retriable"
        if [ -z "$eff_retriable" ] && [ "$zero_token" = true ] \
                && [ "$max_retry" -gt 0 ]; then
            eff_retriable="zero_tokens"
        fi
        if [ -n "$eff_retriable" ] && [ "$max_retry" -gt 0 ]; then
            echo "retry"
        else
            echo "exit"
        fi
    else
        echo "ok"
    fi
}

assert_eq "zero tok, retry on → retry" "retry" \
    "$(simulate_zero_token_decision "exit code 1" 25200 "" true)"
assert_eq "zero tok, retry off → exit" "exit" \
    "$(simulate_zero_token_decision "exit code 1" 0 "" true)"
assert_eq "non-zero tok, no driver match → exit" "exit" \
    "$(simulate_zero_token_decision "some error" 25200 "" false)"

# Backoff doubling with cap at 1800s.
simulate_backoff() {
    local backoff=30 iterations="$1" cap=1800
    for _ in $(seq 1 "$iterations"); do
        backoff=$((backoff * 2))
        if [ "$backoff" -gt "$cap" ]; then
            backoff=$cap
        fi
    done
    echo "$backoff"
}

assert_eq "backoff after 1 double" "60" "$(simulate_backoff 1)"
assert_eq "backoff after 2 doubles" "120" "$(simulate_backoff 2)"
assert_eq "backoff after 3 doubles" "240" "$(simulate_backoff 3)"
assert_eq "backoff capped at 1800" "1800" "$(simulate_backoff 10)"

# --- 14b. codex-cli agent_is_retriable classification ---
#
# Regression guard: 0.20.6's pattern only matched rate-limit /
# quota signals, so an SSE stream drop ("fatal: Reconnecting... N/5
# (stream disconnected before completion)") was classified as
# fatal and the harness exited immediately despite
# MAX_RETRY_WAIT > 0.  0.20.7 adds a transient class covering
# SSE/5xx/connection-reset so the backoff loop gets a chance.
(
    # Subshell so sourcing the driver doesn't clobber earlier
    # assertions' shell state.
    source "$TESTS_DIR/../lib/drivers/codex-cli.sh"

    probe_retriable() {
        local log="$TMPDIR/codex-retriable-$$-${RANDOM}.log"
        printf '%s\n' "$1" > "$log"
        agent_is_retriable "$log" 1
        rm -f "$log"
    }

    # Rate-limit class (existing behaviour) stays intact.
    assert_eq "retriable: 429 response" "rate_limited" \
        "$(probe_retriable 'HTTP 429 Too Many Requests')"
    assert_eq "retriable: quota exhaustion" "rate_limited" \
        "$(probe_retriable 'You have hit your usage limit')"

    # Transient class (new in 0.20.7) — each pattern is the
    # actual wording codex-cli emits on the respective failure.
    assert_eq "retriable: SSE stream drop" "transient" \
        "$(probe_retriable 'fatal: Reconnecting... 2/5 (stream disconnected before completion)')"
    assert_eq "retriable: OpenAI generic retry hint" "transient" \
        "$(probe_retriable 'An error occurred while processing your request')"
    assert_eq "retriable: 502 bad gateway" "transient" \
        "$(probe_retriable 'HTTP 502 Bad Gateway')"
    assert_eq "retriable: 503 service unavailable" "transient" \
        "$(probe_retriable 'HTTP 503 Service Unavailable')"
    assert_eq "retriable: connection reset" "transient" \
        "$(probe_retriable 'connection reset by peer')"
    assert_eq "retriable: request timeout" "transient" \
        "$(probe_retriable 'request timed out after 60s')"

    # Capacity-throttle (#85): OpenAI's fleet-saturation
    # response is a genuine transient -- short-lived, retrying
    # in seconds-to-minutes generally succeeds.  Pre-fix, the
    # codex-cli driver fell through to non-retriable on this
    # message and killed the agent at quota-reset boundaries
    # when many clients contended for the same fleet.  The
    # full message and either substring alone must classify as
    # transient so future OpenAI wording tweaks don't regress
    # the fix.
    assert_eq "retriable: at-capacity full message" "transient" \
        "$(probe_retriable '{"message": "Selected model is at capacity. Please try a different model."}')"
    assert_eq "retriable: at-capacity substring" "transient" \
        "$(probe_retriable 'Selected model is at capacity.')"
    assert_eq "retriable: try-different-model substring" "transient" \
        "$(probe_retriable 'Please try a different model.')"

    # Genuinely fatal errors must NOT be reclassified as
    # transient.  Auth failures, model-not-found, invalid-key etc.
    # need to fail fast so operators see the configuration bug.
    assert_eq "non-retriable: auth error" "" \
        "$(probe_retriable 'invalid_api_key: incorrect credentials')"
    assert_eq "non-retriable: model not found" "" \
        "$(probe_retriable 'model_not_found: gpt-unknown is not available')"
)

# ============================================================
echo ""
echo "=== 12. SSH signing config ==="

# shellcheck source=../lib/signing.sh
source "$TESTS_DIR/../lib/signing.sh"

# Exercises configure_git_signing from lib/signing.sh against
# a sandboxed $HOME so --global writes land in a scratch dir
# instead of the tester's real ~/.gitconfig.
run_signing_config() {
    local create_key="$1"
    local sandbox="$TMPDIR/sign-sandbox-$$-${RANDOM}"
    local key_path="$sandbox/signing_key"
    local dst_path="$sandbox/dst_key"
    mkdir -p "$sandbox"

    if [ "$create_key" = "true" ]; then
        touch "$key_path"
    fi

    HOME="$sandbox" configure_git_signing "$key_path" "$dst_path"

    local format gpgsign
    format=$(HOME="$sandbox" git config --global --get gpg.format \
        2>/dev/null || echo "none")
    gpgsign=$(HOME="$sandbox" git config --global --get commit.gpgsign)
    echo "${format}|${gpgsign}"
    rm -rf "$sandbox"
}

assert_eq "signing key present -> ssh signing" \
    "ssh|true" \
    "$(run_signing_config true)"
assert_eq "signing key absent -> gpgsign false" \
    "none|false" \
    "$(run_signing_config false)"

# Source key is world-readable (e.g. 0644 from a host bind
# mount); the function must copy it to a swarm-owned scratch
# path with 0600 perms and point user.signingkey at the copy,
# so ssh-keygen does not reject it as "UNPROTECTED PRIVATE KEY
# FILE".
copy_sandbox="$TMPDIR/sign-copy-$$-${RANDOM}"
mkdir -p "$copy_sandbox"
copy_src="$copy_sandbox/src_key"
copy_dst="$copy_sandbox/dst_key"
echo "fake-key-bytes" > "$copy_src"
chmod 644 "$copy_src"
HOME="$copy_sandbox" configure_git_signing "$copy_src" "$copy_dst"
assert_eq "key copied to scratch location" \
    "yes" \
    "$([ -f "$copy_dst" ] && echo yes || echo no)"
assert_eq "key copy has 0600 perms" \
    "600" \
    "$(stat -c '%a' "$copy_dst" 2>/dev/null \
        || stat -f '%Lp' "$copy_dst" 2>/dev/null)"
assert_eq "user.signingkey points at copy" \
    "$copy_dst" \
    "$(HOME="$copy_sandbox" git config --global --get user.signingkey)"
assert_eq "no swarm key written under \$HOME" \
    "no" \
    "$([ -e "$copy_sandbox/.ssh/swarm-signing-key" ] && echo yes || echo no)"
rm -rf "$copy_sandbox"

# When install fails (dst dir missing), the function must return
# non-zero AND must NOT poison user.signingkey with a path that
# doesn't exist -- otherwise every later commit silently fails
# to sign.
fail_sandbox="$TMPDIR/sign-fail-$$-${RANDOM}"
mkdir -p "$fail_sandbox"
fail_src="$fail_sandbox/src_key"
fail_dst="$fail_sandbox/no/such/dir/dst_key"
touch "$fail_src"
fail_rc=0
HOME="$fail_sandbox" configure_git_signing "$fail_src" "$fail_dst" \
    >/dev/null 2>&1 || fail_rc=$?
assert_eq "install failure -> non-zero return" \
    "1" \
    "$fail_rc"
assert_eq "install failure -> user.signingkey not set" \
    "" \
    "$(HOME="$fail_sandbox" git config --global --get user.signingkey \
        2>/dev/null)"
rm -rf "$fail_sandbox"

# Defaults to /etc/swarm/signing_key when called with no arg;
# verify by pointing HOME at a sandbox where that path doesn't
# exist and expecting the "absent" branch.
default_path_sandbox="$TMPDIR/sign-default-$$-${RANDOM}"
mkdir -p "$default_path_sandbox"
HOME="$default_path_sandbox" configure_git_signing
assert_eq "default key path absent -> gpgsign false" \
    "false" \
    "$(HOME="$default_path_sandbox" git config --global --get commit.gpgsign)"
rm -rf "$default_path_sandbox"

# ============================================================
echo ""
echo "=== 13. Push safety net — unpushed commit detection ==="

# Create a bare repo and a working clone to simulate the
# harness post-session state where an agent committed locally
# but failed to push.
BARE="$TMPDIR/safety-bare.git"
WORK="$TMPDIR/safety-work"
git init -q --bare "$BARE"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.name "test"
git -C "$WORK" config user.email "test@test"
git -C "$WORK" config commit.gpgsign false

# Seed the bare repo with an initial commit on agent-work.
touch "$WORK/init.txt"
git -C "$WORK" add init.txt
git -C "$WORK" commit -q -m "initial"
git -C "$WORK" checkout -q -b agent-work
git -C "$WORK" push -q origin agent-work

BEFORE=$(git -C "$WORK" rev-parse origin/agent-work)

# Simulate agent committing but failing to push.
echo "work" > "$WORK/result.txt"
git -C "$WORK" add result.txt
git -C "$WORK" commit -q -m "agent work"

LOCAL_HEAD=$(git -C "$WORK" rev-parse HEAD)
UNPUSHED=$(git -C "$WORK" rev-list origin/agent-work..HEAD | wc -l | tr -d ' ')
assert_eq "local ahead of origin" "1" "$UNPUSHED"

# Safety net detects and pushes.
if [ "$LOCAL_HEAD" != "$BEFORE" ] && [ "$UNPUSHED" -gt 0 ]; then
    git -C "$WORK" push -q origin agent-work
fi

git -C "$WORK" fetch -q origin
AFTER=$(git -C "$WORK" rev-parse origin/agent-work)
assert_eq "origin advanced after push" "$LOCAL_HEAD" "$AFTER"

# When no unpushed commits, safety net is a no-op.
NOOP_UNPUSHED=$(git -C "$WORK" rev-list origin/agent-work..HEAD | wc -l | tr -d ' ')
assert_eq "no unpushed after push" "0" "$NOOP_UNPUSHED"

# Concurrent push simulation: second clone pushes first,
# then the first clone rebases and retries.
WORK2="$TMPDIR/safety-work2"
git clone -q "$BARE" "$WORK2"
git -C "$WORK2" config user.name "test2"
git -C "$WORK2" config user.email "test2@test"
git -C "$WORK2" config commit.gpgsign false
git -C "$WORK2" checkout -q agent-work

echo "agent2" > "$WORK2/agent2.txt"
git -C "$WORK2" add agent2.txt
git -C "$WORK2" commit -q -m "agent 2 work"
git -C "$WORK2" push -q origin agent-work

# First clone now has a local commit that diverges from origin.
echo "agent1-late" > "$WORK/late.txt"
git -C "$WORK" add late.txt
git -C "$WORK" commit -q -m "agent 1 late work"

LATE_UNPUSHED=$(git -C "$WORK" rev-list origin/agent-work..HEAD 2>/dev/null | wc -l | tr -d ' ')
assert_eq "diverged clone has unpushed" "1" "$LATE_UNPUSHED"

# Rebase and push (mirrors the safety net retry).
git -C "$WORK" pull -q --rebase origin agent-work
git -C "$WORK" push -q origin agent-work
git -C "$WORK" fetch -q origin
FINAL=$(git -C "$WORK" rev-parse origin/agent-work)
FINAL_LOCAL=$(git -C "$WORK" rev-parse HEAD)
assert_eq "rebase+push reconciled" "$FINAL_LOCAL" "$FINAL"

# ============================================================
echo ""
echo "=== 15. Context stripping hooks survive git pull ==="

# Build a bare + working clone with .claude/ context files.
CTX_BARE="$TMPDIR/ctx-bare.git"
CTX_WORK="$TMPDIR/ctx-work"
CTX_WORK2="$TMPDIR/ctx-work2"
git init -q --bare "$CTX_BARE"
git clone -q "$CTX_BARE" "$CTX_WORK"
git -C "$CTX_WORK" config user.name "test"
git -C "$CTX_WORK" config user.email "test@test"
git -C "$CTX_WORK" config commit.gpgsign false

mkdir -p "$CTX_WORK/.claude/skills" "$CTX_WORK/.claude/references"
echo "# CLAUDE" > "$CTX_WORK/.claude/CLAUDE.md"
echo "skill data" > "$CTX_WORK/.claude/skills/triage.md"
echo "ref data" > "$CTX_WORK/.claude/references/known.md"
echo "code" > "$CTX_WORK/main.go"
git -C "$CTX_WORK" add -A
git -C "$CTX_WORK" commit -q -m "initial with .claude context"
git -C "$CTX_WORK" checkout -q -b agent-work
git -C "$CTX_WORK" push -q origin agent-work

# Install _strip_context hook for slim mode (mirrors harness).
mkdir -p "$CTX_WORK/.git/hooks"
cat > "$CTX_WORK/.git/hooks/_strip_context" <<'CTXHOOK'
#!/bin/bash
case "slim" in
    none) rm -rf .claude 2>/dev/null ;;
    slim) [ -d .claude ] && find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} + 2>/dev/null ;;
esac
CTXHOOK
chmod +x "$CTX_WORK/.git/hooks/_strip_context"
for _hook in post-merge post-checkout; do
    printf '#!/bin/bash\n.git/hooks/_strip_context\n' \
        > "$CTX_WORK/.git/hooks/$_hook"
    chmod +x "$CTX_WORK/.git/hooks/$_hook"
done

# Strip context (simulates the harness initial strip).
(cd "$CTX_WORK" && find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} +)

assert_eq "slim: CLAUDE.md kept" "true" \
    "$([ -f "$CTX_WORK/.claude/CLAUDE.md" ] && echo true || echo false)"
assert_eq "slim: skills/ removed" "false" \
    "$([ -d "$CTX_WORK/.claude/skills" ] && echo true || echo false)"

# Second clone pushes a change (simulates another agent committing).
git clone -q "$CTX_BARE" "$CTX_WORK2"
git -C "$CTX_WORK2" config user.name "test2"
git -C "$CTX_WORK2" config user.email "test2@test"
git -C "$CTX_WORK2" config commit.gpgsign false
git -C "$CTX_WORK2" checkout -q agent-work
echo "new code" >> "$CTX_WORK2/main.go"
git -C "$CTX_WORK2" add main.go
git -C "$CTX_WORK2" commit -q -m "other agent work"
git -C "$CTX_WORK2" push -q origin agent-work

# First clone pulls — post-merge hook should re-strip.
git -C "$CTX_WORK" pull -q origin agent-work

assert_eq "slim post-merge: CLAUDE.md still kept" "true" \
    "$([ -f "$CTX_WORK/.claude/CLAUDE.md" ] && echo true || echo false)"
assert_eq "slim post-merge: skills/ re-stripped" "false" \
    "$([ -d "$CTX_WORK/.claude/skills" ] && echo true || echo false)"
assert_eq "slim post-merge: references/ re-stripped" "false" \
    "$([ -d "$CTX_WORK/.claude/references" ] && echo true || echo false)"

# Now test context=none mode.
CTX_NONE="$TMPDIR/ctx-none"
git clone -q "$CTX_BARE" "$CTX_NONE"
git -C "$CTX_NONE" config user.name "test"
git -C "$CTX_NONE" config user.email "test@test"
git -C "$CTX_NONE" config commit.gpgsign false
git -C "$CTX_NONE" checkout -q agent-work

mkdir -p "$CTX_NONE/.git/hooks"
cat > "$CTX_NONE/.git/hooks/_strip_context" <<'CTXHOOK'
#!/bin/bash
case "none" in
    none) rm -rf .claude 2>/dev/null ;;
    slim) [ -d .claude ] && find .claude -mindepth 1 -maxdepth 1 ! -name CLAUDE.md -exec rm -rf {} + 2>/dev/null ;;
esac
CTXHOOK
chmod +x "$CTX_NONE/.git/hooks/_strip_context"
for _hook in post-merge post-checkout; do
    printf '#!/bin/bash\n.git/hooks/_strip_context\n' \
        > "$CTX_NONE/.git/hooks/$_hook"
    chmod +x "$CTX_NONE/.git/hooks/$_hook"
done

rm -rf "$CTX_NONE/.claude"
assert_eq "none: .claude/ removed" "false" \
    "$([ -d "$CTX_NONE/.claude" ] && echo true || echo false)"

# Push another change from work2 to trigger a merge.
echo "more code" >> "$CTX_WORK2/main.go"
git -C "$CTX_WORK2" add main.go
git -C "$CTX_WORK2" commit -q -m "yet more work"
git -C "$CTX_WORK2" push -q origin agent-work

git -C "$CTX_NONE" pull -q origin agent-work

assert_eq "none post-merge: .claude/ re-removed" "false" \
    "$([ -d "$CTX_NONE/.claude" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 16. Setup hook preserves env through sudo ==="

# The setup hook runs as root via `sudo -E` so the container env
# (including anything passed via `docker_args -e`) crosses the
# sudo boundary into setup.sh. Default Debian sudoers' env_reset
# otherwise strips everything except PATH, so dropping -E would
# silently break any setup script that reads env vars. Pin the
# exact invocation against the harness source.
HARNESS_FILE="$TESTS_DIR/../lib/harness.sh"

assert_eq "setup hook uses sudo -E" \
    "1" \
    "$(grep -cE '^[[:space:]]*sudo -E bash "\$SWARM_SETUP"' "$HARNESS_FILE")"

assert_eq "setup hook does not drop -E" \
    "0" \
    "$(grep -cE '^[[:space:]]*sudo bash "\$SWARM_SETUP"' "$HARNESS_FILE" || true)"

# ============================================================
echo ""
echo "=== 17. Session-end push cleans dirty tree before rebase ==="

# Session-end push path rebases onto origin/agent-work before pushing.
# v0.20.2 used `rebase.autoStash=true`, but autoStash has three
# documented gaps that caused real push failures on multi-agent
# codex-cli swarms:
#
#   (1) `git stash` defaults to not stashing untracked files, so
#       `?? <path>` survives and the rebase still refuses.
#   (2) `git stash` does NOT capture submodule pointer drift
#       (`M <submodule>`) -- regardless of flags.  The superproject
#       gitlink diff is invisible to stash's default traversal.
#   (3) The auto-pop step can conflict mid-rebase on
#       "skipped previously applied commit".
#
# v0.20.4 replaces autoStash with an explicit pre-stash (with
# --include-untracked), a `submodule update --force` to clear
# gitlink drift, and a bare `git pull --rebase` against a
# guaranteed-clean tree.  The stash is intentionally NOT popped;
# the next session's opening `git reset --hard origin/agent-work`
# wipes whatever was in-flight.
#
# Pin all four invariants against the harness source -- grep
# technique from §16.

# (1) Positive: explicit pre-stash including untracked files.
assert_eq "push path pre-stashes with --include-untracked" \
    "1" \
    "$(grep -cE '^[[:space:]]*git stash push --include-untracked --quiet' "$HARNESS_FILE")"

# (2) Positive: submodule update --init --recursive --force after stash.
assert_eq "push path force-syncs submodules" \
    "1" \
    "$(grep -cE '^[[:space:]]*git submodule update --init --recursive --force' "$HARNESS_FILE")"

# (3) Positive: bare rebase -- pre-stashed state guarantees a clean tree.
# The leading `-c core.hooksPath=/dev/null` override was added in the
# 0.20.10 fix for issue #82 and is now part of the bare-form shape.
assert_eq "push-path pull is the bare form (no autoStash)" \
    "1" \
    "$(grep -cE '^[[:space:]]*if git( -c core\.hooksPath=/dev/null)? pull --rebase origin agent-work' "$HARNESS_FILE")"

# (4) Negative: autoStash must NOT come back as an invocation -- it
# was the root cause of the failures this patch closes.  Match the
# actual `git -c rebase.autoStash=...` pattern so mentions in
# comments or commit-message-style prose don't trip the regression
# test.
assert_eq "push-path pull does not re-introduce autoStash" \
    "0" \
    "$(grep -cE 'git -c rebase\.autoStash' "$HARNESS_FILE" || true)"

# (5) Negative: the pre-push stash is intentionally NOT popped in the
# push block -- pop is where autoStash failed, and the next session's
# hard-reset wipes the tree anyway.  The regex allows `git stash pop`
# to appear elsewhere in the file for legitimate reasons if ever added.
assert_eq "push path does not pop the pre-push stash" \
    "0" \
    "$(awk '/^[[:space:]]*hlog "found unpushed local commits/,/^[[:space:]]*fi$/' "$HARNESS_FILE" | grep -cE 'git stash pop' || true)"

# (6) Observability: operators need to see what uncommitted state the
# agent left behind, so the harness logs `git status --porcelain=v1`
# once before the stash.  Auditable dirty-tree surprises.
assert_eq "push path logs porcelain status for observability" \
    "1" \
    "$(grep -cE 'git status --porcelain=v1' "$HARNESS_FILE")"

# (7) Observability: when the stash actually captures something, the
# stash ref is logged so an operator can `git stash show stash@{N}`
# from the reflog.
assert_eq "push path logs the pre-push stash ref when created" \
    "1" \
    "$(grep -cE 'pre-push stash: ' "$HARNESS_FILE")"

# ============================================================
echo ""
echo "=== 18. Session-end scratch-worktree push fallback ==="

# When the in-place `git pull --rebase && git push` retry loop
# exhausts all three attempts, the harness falls back to a scratch
# worktree: cherry-pick unpushed commits onto a fresh detached
# checkout of origin/agent-work, push from that worktree, then
# tear it down.  The fallback sidesteps every failure pattern
# documented in CHANGELOG 0.20.5 because it ignores the main
# worktree's state entirely -- submodule drift, context-stripping
# hooks firing during rebase-merge checkouts, and "skipped
# previously applied commit" all become irrelevant when the push
# goes through a pristine checkout of origin/agent-work.
#
# §18a pins the key invariants of `_scratch_worktree_push` against
# the harness source.  §18b rehearses the cherry-pick-onto-scratch
# dance against a real bare repo with an arbitrarily dirty main
# worktree, confirming the pattern actually succeeds where the
# in-place rebase would refuse.

# --- §18a. Structural pins against lib/harness.sh ---

assert_eq "fallback function is defined in harness.sh" \
    "1" \
    "$(grep -cE '^_scratch_worktree_push\(\) \{' "$HARNESS_FILE")"

assert_eq "fallback creates a detached worktree" \
    "1" \
    "$(grep -cE 'worktree add --detach --quiet' "$HARNESS_FILE")"

# Regression guard for the 0.20.5 "scratch push: worktree add failed"
# bug: the `git worktree add` invocation must suppress hooks, because
# in a linked worktree `.git` is a gitfile (not a directory), so any
# post-checkout hook that references `.git/hooks/*` by relative path
# fails with "Not a directory" during worktree creation. Without this
# flag, every fallback attempt fails in consumers that install such
# a hook (§18d exercises this end-to-end).
assert_eq "worktree add suppresses hooks (0.20.5 regression guard)" \
    "1" \
    "$(grep -cE 'git -c core\.hooksPath=/dev/null worktree add' "$HARNESS_FILE")"

# Two-step cherry-pick: apply without committing first, then
# detect "no net change" as the git <2.45 substitute for
# --empty=drop, then commit with original metadata via commit -C.
# Pinning all three lines: if a future refactor collapses them
# back to `cherry-pick --empty=drop` the test breaks, because the
# collapsed form only works on git 2.45+ but the base image ships
# git 2.39 (bug report Pattern A regression guard).
assert_eq "fallback cherry-picks with --no-commit" \
    "1" \
    "$(grep -cE 'cherry-pick -n "\$sha"' "$HARNESS_FILE")"

assert_eq "fallback detects empty applies via diff --cached" \
    "1" \
    "$(grep -cE 'diff --cached --quiet' "$HARNESS_FILE")"

assert_eq "fallback commits with -C to keep author metadata" \
    "1" \
    "$(grep -cE 'commit --allow-empty-message -C "\$sha"' "$HARNESS_FILE")"

# Hooks must be suppressed at every code site where git operates
# on the scratch worktree AND on the primary session-end rebase
# path so consumer-installed post-checkout / post-rewrite hooks
# cannot interfere.  Nine hits total across comments and code:
#   - preamble comment (§_scratch_worktree_push docstring)
#   - worktree-add inline comment
#   - `git worktree add` (0.20.6 fix for "worktree add failed")
#   - cherry-pick -n
#   - cherry-pick's follow-up commit
#   - primary rebase-path preamble comment (0.20.10 #82 fix)
#   - primary rebase-path inline reference
#   - `git pull --rebase` on the primary path
#   - `git push` on the primary path
assert_eq "fallback disables hooks in the scratch worktree" \
    "9" \
    "$(grep -cE 'core\.hooksPath=/dev/null' "$HARNESS_FILE")"
# Tighter pin: count only the actual `git -c core.hooksPath=/dev/null`
# invocations (ignore comment prose).  Five on the primary+scratch
# code paths.
assert_eq "five git -c core.hooksPath=/dev/null invocations total" \
    "5" \
    "$(grep -cE 'git (-C "[^"]+" )?-c core\.hooksPath=/dev/null' "$HARNESS_FILE")"

# Preamble comment references the push target once; the actual
# `git -C "$_scratch" push` invocation is the second hit.
assert_eq "fallback pushes scratch HEAD to agent-work" \
    "2" \
    "$(grep -cE 'push origin HEAD:agent-work' "$HARNESS_FILE")"

assert_eq "fallback tears the scratch worktree down" \
    "1" \
    "$(grep -cE 'git worktree remove --force' "$HARNESS_FILE")"

# The push block must reach the fallback *after* the three-retry
# rebase loop has exhausted, not in place of it -- rebase still
# works most of the time and is cheaper than a worktree transplant.
assert_eq "push block invokes fallback after retries exhaust" \
    "1" \
    "$(grep -cE 'if _scratch_worktree_push; then' "$HARNESS_FILE")"

assert_eq "fallback entry log line present" \
    "1" \
    "$(grep -cE 'rebase path exhausted, trying scratch worktree fallback' "$HARNESS_FILE")"

# The final error message was updated to reflect the new
# fallback -- pin it so a future refactor doesn't regress the
# diagnosability of a terminal push failure.
assert_eq "terminal error message mentions both paths" \
    "1" \
    "$(grep -cE 'push failed after 3 retries and scratch fallback' "$HARNESS_FILE")"

# --- §18b. Behavioral: cherry-pick-onto-scratch push succeeds
# even when the main worktree is arbitrarily dirty.

# Local reimplementation of _scratch_worktree_push mirroring the
# harness function line-for-line.  We cannot source harness.sh
# directly because its top-level requires SWARM_PROMPT and loads a
# driver; any divergence from the production logic below would
# still be caught by §18a's structural pins above.
sc_hlog()      { :; }
sc_hlog_err()  { :; }
sc_hlog_pipe() { cat >/dev/null; }

_test_scratch_push() {
    local _scratch _shas _n_shas sha _rc=0
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        git rebase --abort 2>/dev/null \
            || rm -rf .git/rebase-merge .git/rebase-apply
    fi
    git fetch --no-recurse-submodules origin agent-work 2>&1 \
        | sc_hlog_pipe || true

    _shas=$(git rev-list --reverse origin/agent-work..HEAD 2>/dev/null)
    if [ -z "$_shas" ]; then
        sc_hlog "no unpushed"
        return 0
    fi
    _n_shas=$(printf '%s\n' "$_shas" | wc -l | tr -d ' ')
    sc_hlog "transplanting ${_n_shas} commits"

    _scratch="$TMPDIR/scratch-$$-${RANDOM}"
    rm -rf "$_scratch" 2>/dev/null || true

    if ! git -c core.hooksPath=/dev/null worktree add --detach --quiet \
            "$_scratch" origin/agent-work 2>&1 | sc_hlog_pipe; then
        sc_hlog_err "worktree add failed"
        rm -rf "$_scratch" 2>/dev/null || true
        git worktree prune 2>/dev/null || true
        return 1
    fi

    for sha in $_shas; do
        if ! git -C "$_scratch" -c core.hooksPath=/dev/null \
                cherry-pick -n "$sha" 2>&1 | sc_hlog_pipe; then
            sc_hlog_err "cherry-pick failed for ${sha}"
            git -C "$_scratch" reset --hard HEAD 2>/dev/null || true
            _rc=1
            break
        fi
        if git -C "$_scratch" diff --cached --quiet 2>/dev/null \
                && git -C "$_scratch" diff --quiet 2>/dev/null; then
            sc_hlog "dropping redundant commit ${sha:0:12}"
            continue
        fi
        if ! git -C "$_scratch" -c core.hooksPath=/dev/null \
                commit --allow-empty-message -C "$sha" 2>&1 \
                | sc_hlog_pipe; then
            sc_hlog_err "commit failed for ${sha}"
            git -C "$_scratch" reset --hard HEAD 2>/dev/null || true
            _rc=1
            break
        fi
    done

    if [ "$_rc" -eq 0 ]; then
        if git -C "$_scratch" push origin HEAD:agent-work 2>&1 \
                | sc_hlog_pipe; then
            sc_hlog "push succeeded"
        else
            sc_hlog_err "push rejected"
            _rc=1
        fi
    fi

    git worktree remove --force "$_scratch" 2>/dev/null \
        || rm -rf "$_scratch" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    return "$_rc"
}

SC_BARE="$TMPDIR/scratch-bare.git"
SC_WORK="$TMPDIR/scratch-work"
git init -q --bare "$SC_BARE"
git clone -q "$SC_BARE" "$SC_WORK"
git -C "$SC_WORK" config user.name "test"
git -C "$SC_WORK" config user.email "test@test"
git -C "$SC_WORK" config commit.gpgsign false

echo "init" > "$SC_WORK/init.txt"
git -C "$SC_WORK" add init.txt
git -C "$SC_WORK" commit -q -m "initial"
git -C "$SC_WORK" checkout -q -b agent-work
git -C "$SC_WORK" push -q origin agent-work

# Two local commits ahead of origin (the "unpushed" state the
# harness push block is triggered by).
echo "A" > "$SC_WORK/a.txt"
git -C "$SC_WORK" add a.txt
git -C "$SC_WORK" commit -q -m "agent commit A"
echo "B" > "$SC_WORK/b.txt"
git -C "$SC_WORK" add b.txt
git -C "$SC_WORK" commit -q -m "agent commit B"
SC_LOCAL_HEAD=$(git -C "$SC_WORK" rev-parse HEAD)

# Dirty the worktree in three of the shapes the bug report
# documented: tracked mod, tracked deletion, untracked scratch.
# Any one of these is enough to make `git pull --rebase` refuse.
echo "dirty" >> "$SC_WORK/init.txt"
rm -f "$SC_WORK/a.txt"
echo "scratch" > "$SC_WORK/untracked.txt"
DIRTY_BEFORE=$(git -C "$SC_WORK" status --porcelain=v1 | wc -l | tr -d ' ')
assert_eq "worktree dirty pre-fallback" "3" "$DIRTY_BEFORE"

# The fallback must succeed despite that dirtiness.
SC_RC=0
( cd "$SC_WORK" && _test_scratch_push ) || SC_RC=$?
assert_eq "fallback exits cleanly on dirty tree" "0" "$SC_RC"

# Origin now holds both agent commits in order.
git -C "$SC_BARE" log agent-work --format='%s' > "$TMPDIR/sc-bare-log.txt"
assert_eq "commit A landed on origin" "1" \
    "$(grep -cE '^agent commit A$' "$TMPDIR/sc-bare-log.txt")"
assert_eq "commit B landed on origin" "1" \
    "$(grep -cE '^agent commit B$' "$TMPDIR/sc-bare-log.txt")"

# Main worktree's dirty state must survive unchanged -- the whole
# point of the scratch approach is that it doesn't touch the main
# worktree.  Local HEAD is unchanged too (we transplanted, not
# rebased).
DIRTY_AFTER=$(git -C "$SC_WORK" status --porcelain=v1 | wc -l | tr -d ' ')
assert_eq "main worktree dirt survives fallback" "3" "$DIRTY_AFTER"
assert_eq "main worktree HEAD untouched" "$SC_LOCAL_HEAD" \
    "$(git -C "$SC_WORK" rev-parse HEAD)"

# The scratch worktree must be cleaned up -- both the on-disk
# path and the worktree registry.  The ephemeral worktree name
# in _test_scratch_push is "scratch-<pid>-<rand>"; SC_WORK itself
# lives at "scratch-work" so we anchor against the exact pattern
# (one dash-separated digit chunk, then another) to avoid matching
# the main worktree.
SC_ORPHANS=$(git -C "$SC_WORK" worktree list --porcelain \
    2>/dev/null | grep -cE '^worktree .*/scratch-[0-9]+-[0-9]+$' \
    || true)
assert_eq "scratch worktree registry cleaned" "0" "$SC_ORPHANS"
SC_DIR_ORPHANS=$(find "$TMPDIR" -maxdepth 1 -name 'scratch-*-*' \
    -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "scratch worktree dir removed" "0" "$SC_DIR_ORPHANS"

# --- §18c. Behavioral: redundant-commit drop handles the
# "skipped previously applied commit" regression from Pattern A.
# Scenario: SC_WORK has commit D locally (so D is in its HEAD
# graph, not in origin's), but origin already holds a
# patch-equivalent D' published via a different agent.  Applying
# D on top of origin's tip produces no net change, which in git
# <2.45 makes a plain cherry-pick stop with "The previous
# cherry-pick is now empty".  Our manual "cherry-pick -n + diff
# check + commit -C" dance has to silently drop D and let the
# push happen anyway.

# Reset SC_WORK to match origin so §18b's cruft doesn't bleed in.
( cd "$SC_WORK" && git clean -qfd && git checkout -q -- . )
git -C "$SC_WORK" fetch -q origin agent-work
git -C "$SC_WORK" reset --hard -q origin/agent-work

# SC_WORK commits D locally (unpushed).
echo "D" > "$SC_WORK/d.txt"
git -C "$SC_WORK" add d.txt
git -C "$SC_WORK" commit -q -m "agent commit D"
SC_D_SHA=$(git -C "$SC_WORK" rev-parse HEAD)

# A sibling clone publishes a patch-equivalent D' to origin,
# arriving via a different SHA (simulating "the other agent
# already pushed this change through its own route").  SC_WORK3
# can't cherry-pick SC_D_SHA directly -- origin hasn't seen it
# yet -- so we recreate the same tree change as an independent
# commit, which guarantees a distinct SHA and identical patch.
SC_WORK3="$TMPDIR/sibling-work3"
git clone -q "$SC_BARE" "$SC_WORK3"
git -C "$SC_WORK3" config user.name "test3"
git -C "$SC_WORK3" config user.email "test3@test"
git -C "$SC_WORK3" config commit.gpgsign false
git -C "$SC_WORK3" checkout -q agent-work
echo "D" > "$SC_WORK3/d.txt"
git -C "$SC_WORK3" add d.txt
git -C "$SC_WORK3" commit -q -m "agent commit D (via sibling)"
SC_D_PRIME_SHA=$(git -C "$SC_WORK3" rev-parse HEAD)
git -C "$SC_WORK3" push -q origin agent-work

# Guard: D and D' must be distinct SHAs (different message =
# different commit SHA), otherwise §18c would be vacuous.
assert_eq "sibling D' has a distinct SHA" "1" \
    "$(test "$SC_D_SHA" != "$SC_D_PRIME_SHA" && echo 1 || echo 0)"

# Run the fallback.  SC_WORK thinks it has one unpushed commit,
# but applying it produces no net change, so the drop-redundant
# branch triggers, and the push completes cleanly as a no-op.
SC_RC=0
( cd "$SC_WORK" && _test_scratch_push ) || SC_RC=$?
assert_eq "fallback succeeds with already-applied commit" "0" "$SC_RC"

# Origin's HEAD should still point to the sibling's D' -- the
# fallback dropped SC_WORK's local D as redundant instead of
# stamping a new commit on top of D'.  The commit count on the
# branch is the other half of the check: exactly one commit
# whose subject starts with "agent commit D".
SC_BARE_HEAD=$(git -C "$SC_BARE" rev-parse agent-work)
assert_eq "origin HEAD still at sibling D'" "$SC_D_PRIME_SHA" "$SC_BARE_HEAD"

git -C "$SC_BARE" log agent-work --format='%s' > "$TMPDIR/sc-bare-log2.txt"
assert_eq "no duplicate D-shaped commit on origin" "1" \
    "$(grep -cE '^agent commit D( \(via sibling\))?$' "$TMPDIR/sc-bare-log2.txt")"

# --- §18d. Behavioral: worktree add must survive a consumer-
# installed post-checkout hook. 0.20.5 regression: if the consumer
# repo has a post-checkout hook that references another hook via
# a relative path (e.g. `.git/hooks/<script>`), the reference
# resolves against the linked worktree's gitfile `.git`, not a
# real directory, and fails with "Not a directory". Without
# `-c core.hooksPath=/dev/null` on the `git worktree add`, the
# hook fires and fails the entire worktree creation, and the
# fallback bombs with "worktree add failed".

# Reset to a clean state between §18c and §18d.
( cd "$SC_WORK" && git clean -qfd && git checkout -q -- . )
git -C "$SC_WORK" fetch -q origin agent-work
git -C "$SC_WORK" reset --hard -q origin/agent-work

# Install a hostile post-checkout hook that references a relative
# path under `.git/hooks/`. In the superproject this works fine
# because `.git` is a directory; in a linked worktree `.git` is a
# gitfile, so `.git/hooks/<anything>` errors with "Not a directory"
# and tanks the checkout.
cat > "$SC_WORK/.git/hooks/post-checkout" <<'HOOK'
#!/bin/bash
# Simulates a consumer-installed post-checkout that chains to
# another hook via a relative path. Works in the superproject
# (`.git` is a directory), fails in any linked worktree (`.git`
# is a gitfile).
.git/hooks/relative-ref-that-does-not-exist
HOOK
chmod +x "$SC_WORK/.git/hooks/post-checkout"

# Queue one unpushed commit so the fallback has something to do.
echo "E" > "$SC_WORK/e.txt"
git -C "$SC_WORK" add e.txt
git -C "$SC_WORK" commit -q -m "agent commit E"

# The fallback must still succeed -- the fix suppresses hooks at
# worktree-add time so the hostile hook never runs.
SC_RC=0
( cd "$SC_WORK" && _test_scratch_push ) || SC_RC=$?
assert_eq "fallback succeeds despite hostile post-checkout hook" \
    "0" "$SC_RC"

git -C "$SC_BARE" log agent-work --format='%s' > "$TMPDIR/sc-bare-log3.txt"
assert_eq "commit E landed on origin via hook-hostile path" "1" \
    "$(grep -cE '^agent commit E$' "$TMPDIR/sc-bare-log3.txt")"

# Negative control: with the hook-suppression flag removed, the
# same setup must fail. This guards against a future refactor
# that silently drops `-c core.hooksPath=/dev/null` -- the
# structural pin above would still match a misplaced flag, but
# this behavioral check confirms the flag is actually working.
_test_scratch_push_no_suppress() {
    local _scratch
    _scratch="$TMPDIR/scratch-nosuppress-$$-${RANDOM}"
    rm -rf "$_scratch" 2>/dev/null || true
    if git worktree add --detach --quiet "$_scratch" \
            origin/agent-work 2>/dev/null; then
        rm -rf "$_scratch" 2>/dev/null || true
        git worktree prune 2>/dev/null || true
        return 0
    fi
    git worktree prune 2>/dev/null || true
    return 1
}

# Queue another commit so the control has a fresh unpushed state.
echo "F" > "$SC_WORK/f.txt"
git -C "$SC_WORK" add f.txt
git -C "$SC_WORK" commit -q -m "agent commit F"

SC_RC=0
( cd "$SC_WORK" && _test_scratch_push_no_suppress ) || SC_RC=$?
assert_eq "negative control: plain worktree add fails under hostile hook" \
    "1" "$SC_RC"

rm -f "$SC_WORK/.git/hooks/post-checkout"

# --- §18e. Behavioral: cherry-pick conflict parks the local
# commits on origin so they are not lost.  0.20.6 regression:
# when the scratch cherry-pick hits a real textual conflict with
# upstream, `_scratch_worktree_push` reset the scratch, returned 1,
# and the caller moved on — the agent's commits survived only in
# its local repo and were erased by the next session's pre-session
# `git reset --hard origin/agent-work`.  0.20.7 adds a salvage
# push to `refs/heads/agent-parked/<agent>-<ts>` so the original
# SHAs land on origin before the scratch is torn down.

# Mirrors the production `_scratch_worktree_push` with the 0.20.7
# parking step appended.  Kept in-file (rather than sourcing
# harness.sh) for the same reason as _test_scratch_push above:
# harness.sh's top-level needs SWARM_PROMPT and a driver.
_test_scratch_push_with_park() {
    local agent_id="$1"
    local _scratch _shas _n_shas sha _rc=0
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        git rebase --abort 2>/dev/null \
            || rm -rf .git/rebase-merge .git/rebase-apply
    fi
    git fetch --no-recurse-submodules origin agent-work 2>&1 \
        | sc_hlog_pipe || true
    _shas=$(git rev-list --reverse origin/agent-work..HEAD 2>/dev/null)
    if [ -z "$_shas" ]; then return 0; fi
    _n_shas=$(printf '%s\n' "$_shas" | wc -l | tr -d ' ')
    _scratch="$TMPDIR/scratch-$$-${RANDOM}"
    rm -rf "$_scratch" 2>/dev/null || true
    if ! git -c core.hooksPath=/dev/null worktree add --detach --quiet \
            "$_scratch" origin/agent-work 2>&1 | sc_hlog_pipe; then
        rm -rf "$_scratch" 2>/dev/null || true
        git worktree prune 2>/dev/null || true
        return 1
    fi
    for sha in $_shas; do
        if ! git -C "$_scratch" -c core.hooksPath=/dev/null \
                cherry-pick -n "$sha" 2>&1 | sc_hlog_pipe; then
            git -C "$_scratch" reset --hard HEAD 2>/dev/null || true
            _rc=1; break
        fi
        if git -C "$_scratch" diff --cached --quiet 2>/dev/null \
                && git -C "$_scratch" diff --quiet 2>/dev/null; then
            continue
        fi
        if ! git -C "$_scratch" -c core.hooksPath=/dev/null \
                commit --allow-empty-message -C "$sha" 2>&1 \
                | sc_hlog_pipe; then
            git -C "$_scratch" reset --hard HEAD 2>/dev/null || true
            _rc=1; break
        fi
    done
    if [ "$_rc" -eq 0 ]; then
        git -C "$_scratch" push origin HEAD:agent-work 2>&1 \
            | sc_hlog_pipe || _rc=1
    fi
    if [ "$_rc" -ne 0 ] && [ -n "$_shas" ]; then
        local _park_ref
        _park_ref="refs/heads/agent-parked/${agent_id}-$(date -u +%Y%m%dT%H%M%SZ)"
        git push origin "HEAD:${_park_ref}" 2>&1 | sc_hlog_pipe || true
    fi
    git worktree remove --force "$_scratch" 2>/dev/null \
        || rm -rf "$_scratch" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    return "$_rc"
}

# Reset SC_WORK to origin, then engineer a cherry-pick conflict:
# local commit on file g.txt, a patch-incompatible sibling commit
# on the same file published to origin.
( cd "$SC_WORK" && git clean -qfd && git checkout -q -- . )
git -C "$SC_WORK" fetch -q origin agent-work
git -C "$SC_WORK" reset --hard -q origin/agent-work

# Sibling publishes an initial g.txt first.
SC_WORK4="$TMPDIR/sibling-work4"
git clone -q "$SC_BARE" "$SC_WORK4"
git -C "$SC_WORK4" config user.name "test4"
git -C "$SC_WORK4" config user.email "test4@test"
git -C "$SC_WORK4" config commit.gpgsign false
git -C "$SC_WORK4" checkout -q agent-work
printf 'upstream line 1\nupstream line 2\n' > "$SC_WORK4/g.txt"
git -C "$SC_WORK4" add g.txt
git -C "$SC_WORK4" commit -q -m "sibling seeds g.txt"
git -C "$SC_WORK4" push -q origin agent-work

# Local agent also creates g.txt with incompatible content, based
# on the older origin tip (before the sibling push).  The scratch
# worktree will fetch the fresh origin and try to cherry-pick the
# local commit onto the sibling's tip, which fails — both sides
# added the same file with different content ("both added" conflict).
printf 'local line 1\nlocal line 2\n' > "$SC_WORK/g.txt"
git -C "$SC_WORK" add g.txt
git -C "$SC_WORK" commit -q -m "agent commit G (will conflict)"
SC_G_SHA=$(git -C "$SC_WORK" rev-parse HEAD)

# Run the fallback: cherry-pick must fail (real conflict), then
# the parking step must push local HEAD to an agent-parked ref.
SC_RC=0
( cd "$SC_WORK" && _test_scratch_push_with_park "agent-99" ) \
    || SC_RC=$?
assert_eq "fallback returns 1 on genuine cherry-pick conflict" \
    "1" "$SC_RC"

# Origin should now have exactly one `agent-parked/agent-99-*`
# branch, and its tip must be the local SHA that failed to apply.
SC_PARK_REFS=$(git -C "$SC_BARE" for-each-ref \
    --format='%(refname:short)' 'refs/heads/agent-parked/agent-99-*' \
    | wc -l | tr -d ' ')
assert_eq "exactly one parked ref created" "1" "$SC_PARK_REFS"

SC_PARK_REF=$(git -C "$SC_BARE" for-each-ref \
    --format='%(refname:short)' 'refs/heads/agent-parked/agent-99-*' \
    | head -1)
SC_PARK_HEAD=$(git -C "$SC_BARE" rev-parse "$SC_PARK_REF")
assert_eq "parked ref tip is the agent's local SHA" \
    "$SC_G_SHA" "$SC_PARK_HEAD"

# And origin/agent-work must NOT contain the conflicting commit —
# parking is a side-channel, the integration branch stays clean.
git -C "$SC_BARE" log agent-work --format='%H' > "$TMPDIR/sc-bare-log4.txt"
assert_eq "conflicting commit did not land on agent-work" \
    "0" "$(grep -c "^${SC_G_SHA}$" "$TMPDIR/sc-bare-log4.txt")"

# Structural pin: the harness function must contain the parking
# step, not just the test's local copy.
assert_eq "harness parks unpushed commits on transplant failure" \
    "1" \
    "$(grep -cE 'refs/heads/agent-parked/' "$HARNESS_FILE")"
assert_eq "harness logs the parked ref name" \
    "1" \
    "$(grep -cE 'scratch push: parked .* commit\(s\) at' "$HARNESS_FILE")"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
