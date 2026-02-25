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

# --- Helpers: same jq expressions used in harness.sh ---

extract_stats() {
    local logfile="$1"
    local cost dur api_ms turns tok_in tok_out cache_rd cache_cr
    cost=$(jq -r '.total_cost_usd // 0' "$logfile" 2>/dev/null || true)
    cost="${cost:-0}"
    dur=$(jq -r '.duration_ms // 0' "$logfile" 2>/dev/null || true)
    dur="${dur:-0}"
    api_ms=$(jq -r '.duration_api_ms // 0' "$logfile" 2>/dev/null || true)
    api_ms="${api_ms:-0}"
    turns=$(jq -r '.num_turns // 0' "$logfile" 2>/dev/null || true)
    turns="${turns:-0}"
    tok_in=$(jq -r '.usage.input_tokens // 0' "$logfile" 2>/dev/null || true)
    tok_in="${tok_in:-0}"
    tok_out=$(jq -r '.usage.output_tokens // 0' "$logfile" 2>/dev/null || true)
    tok_out="${tok_out:-0}"
    cache_rd=$(jq -r '.usage.cache_read_input_tokens // 0' "$logfile" 2>/dev/null || true)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(jq -r '.usage.cache_creation_input_tokens // 0' "$logfile" 2>/dev/null || true)
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
echo "=== 5. TSV line format ==="

LINE=$(extract_stats "$TMPDIR/full.json")
FIELD_COUNT=$(echo "$LINE" | awk -F'\t' '{print NF}')
assert_eq "9 tab-separated fields" "9" "$FIELD_COUNT"

# ============================================================
echo ""
echo "=== 6. INJECT_GIT_RULES logic ==="

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
echo "=== 7. Idle counter logic ==="

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
echo "=== 8. prepare-commit-msg hook appends trailers ==="

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
    printf '\nModel: %s\nAgent: Claude Code %s\n' \
        "$CLAUDE_MODEL" "$CLAUDE_VERSION" >> "$1"
fi
HOOK
chmod +x "$HOOK_REPO/.git/hooks/prepare-commit-msg"

touch "$HOOK_REPO/file.txt"
git -C "$HOOK_REPO" add file.txt
CLAUDE_MODEL="claude-opus-4-6" CLAUDE_VERSION="1.0.32" \
    git -C "$HOOK_REPO" commit -m "test commit" --quiet

MSG=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer" \
    "Model: claude-opus-4-6" \
    "$(echo "$MSG" | grep '^Model:')"
assert_eq "hook agent trailer" \
    "Agent: Claude Code 1.0.32" \
    "$(echo "$MSG" | grep '^Agent:')"
assert_eq "hook subject preserved" \
    "test commit" \
    "$(echo "$MSG" | head -1)"

# Second commit with different model — trailers update.
echo "x" > "$HOOK_REPO/file2.txt"
git -C "$HOOK_REPO" add file2.txt
CLAUDE_MODEL="MiniMax-M2.5" CLAUDE_VERSION="1.0.30" \
    git -C "$HOOK_REPO" commit -m "second commit" --quiet

MSG2=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer 2" \
    "Model: MiniMax-M2.5" \
    "$(echo "$MSG2" | grep '^Model:')"
assert_eq "hook agent trailer 2" \
    "Agent: Claude Code 1.0.30" \
    "$(echo "$MSG2" | grep '^Agent:')"

# Idempotent: if trailers already present, hook does not duplicate.
echo "y" > "$HOOK_REPO/file3.txt"
git -C "$HOOK_REPO" add file3.txt
CLAUDE_MODEL="claude-opus-4-6" CLAUDE_VERSION="1.0.32" \
    git -C "$HOOK_REPO" commit -m "$(printf 'manual trailers\n\nModel: already-set')" --quiet

MSG3=$(git -C "$HOOK_REPO" log -1 --format='%B')
MODEL_COUNT=$(echo "$MSG3" | grep -c '^Model:' || true)
assert_eq "hook no duplicate" "1" "$MODEL_COUNT"

# ============================================================
echo ""
echo "=== 9. Version string stripping ==="

# Mirrors the CLAUDE_VERSION="${CLAUDE_VERSION%% *}" in harness.sh.
strip_version() { local v="$1"; echo "${v%% *}"; }

assert_eq "strip suffix"   "2.1.52"  "$(strip_version '2.1.52 (Claude Code)')"
assert_eq "no suffix"      "2.1.52"  "$(strip_version '2.1.52')"
assert_eq "unknown"         "unknown" "$(strip_version 'unknown')"

# ============================================================
echo ""
echo "=== 10. Attribution settings file ==="

# Mirrors the .claude/settings.local.json written by harness.sh.
ATTR_JSON='{"attribution":{"commit":"","pr":""}}'
echo "$ATTR_JSON" > "$TMPDIR/settings.local.json"

assert_eq "attr valid JSON" "true" \
    "$(jq empty "$TMPDIR/settings.local.json" 2>/dev/null && echo true || echo false)"
assert_eq "attr commit empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.commit')"
assert_eq "attr pr empty" "" \
    "$(echo "$ATTR_JSON" | jq -r '.attribution.pr')"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
