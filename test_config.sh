#!/bin/bash
set -euo pipefail

# Unit tests for swarm.json config parsing.
# No Docker or API key required -- validates jq expressions only.

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

# --- Helpers: same jq expressions used in launch.sh ---

parse_prompt()     { jq -r '.prompt // empty' "$1"; }
parse_setup()      { jq -r '.setup // empty' "$1"; }
parse_max_idle()   { jq -r '.max_idle // 3' "$1"; }
parse_git_name()   { jq -r '.git_user.name // "swarm-agent"' "$1"; }
parse_git_email()  { jq -r '.git_user.email // "agent@claude-swarm.local"' "$1"; }
parse_num_agents() { jq '[.agents[].count] | add' "$1"; }

parse_agents_tsv() {
    jq -r '.agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // "")] | @tsv' "$1"
}

# ============================================================
echo "=== 1. Mixed-model config ==="

cat > "$TMPDIR/mixed.json" <<'EOF'
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 5,
  "git_user": { "name": "test-agent", "email": "test@example.com" },
  "agents": [
    { "count": 2, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-5" },
    { "count": 3, "model": "openrouter/custom", "base_url": "https://openrouter.ai/api/v1", "api_key": "sk-or-test" }
  ]
}
EOF

assert_eq "prompt"    "prompts/task.md"  "$(parse_prompt "$TMPDIR/mixed.json")"
assert_eq "setup"     "scripts/setup.sh" "$(parse_setup "$TMPDIR/mixed.json")"
assert_eq "max_idle"  "5"                "$(parse_max_idle "$TMPDIR/mixed.json")"
assert_eq "git name"  "test-agent"       "$(parse_git_name "$TMPDIR/mixed.json")"
assert_eq "git email" "test@example.com" "$(parse_git_email "$TMPDIR/mixed.json")"
assert_eq "total agents" "6"             "$(parse_num_agents "$TMPDIR/mixed.json")"

TSV=$(parse_agents_tsv "$TMPDIR/mixed.json")
assert_eq "line count" "6" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE3=$(echo "$TSV" | sed -n '3p')
LINE4=$(echo "$TSV" | sed -n '4p')
LINE6=$(echo "$TSV" | sed -n '6p')

IFS=$'\t' read -r m1 u1 k1 <<< "$LINE1"
assert_eq "agent 1 model"   "claude-opus-4-6" "$m1"
assert_eq "agent 1 base_url" ""               "$u1"
assert_eq "agent 1 api_key"  ""               "$k1"

IFS=$'\t' read -r m3 u3 k3 <<< "$LINE3"
assert_eq "agent 3 model" "claude-sonnet-4-5" "$m3"

IFS=$'\t' read -r m4 u4 k4 <<< "$LINE4"
assert_eq "agent 4 model"    "openrouter/custom"                "$m4"
assert_eq "agent 4 base_url" "https://openrouter.ai/api/v1"     "$u4"
assert_eq "agent 4 api_key"  "sk-or-test"                       "$k4"

IFS=$'\t' read -r m6 u6 k6 <<< "$LINE6"
assert_eq "agent 6 model"    "openrouter/custom"                "$m6"
assert_eq "agent 6 base_url" "https://openrouter.ai/api/v1"     "$u6"
assert_eq "agent 6 api_key"  "sk-or-test"                       "$k6"

# ============================================================
echo ""
echo "=== 2. Minimal config (defaults) ==="

cat > "$TMPDIR/minimal.json" <<'EOF'
{
  "prompt": "task.md",
  "agents": [
    { "count": 2, "model": "claude-sonnet-4-5" }
  ]
}
EOF

assert_eq "prompt"      "task.md"                    "$(parse_prompt "$TMPDIR/minimal.json")"
assert_eq "setup empty" ""                           "$(parse_setup "$TMPDIR/minimal.json")"
assert_eq "max_idle default" "3"                     "$(parse_max_idle "$TMPDIR/minimal.json")"
assert_eq "git name default" "swarm-agent"           "$(parse_git_name "$TMPDIR/minimal.json")"
assert_eq "git email default" "agent@claude-swarm.local" "$(parse_git_email "$TMPDIR/minimal.json")"
assert_eq "total agents" "2"                         "$(parse_num_agents "$TMPDIR/minimal.json")"

TSV=$(parse_agents_tsv "$TMPDIR/minimal.json")
assert_eq "all same model" "2" "$(echo "$TSV" | grep -c 'claude-sonnet-4-5')"

# ============================================================
echo ""
echo "=== 3. Missing prompt field ==="

cat > "$TMPDIR/noprompt.json" <<'EOF'
{
  "agents": [{ "count": 1, "model": "claude-opus-4-6" }]
}
EOF

assert_eq "prompt is empty" "" "$(parse_prompt "$TMPDIR/noprompt.json")"

# ============================================================
echo ""
echo "=== 4. Env-var fallback (synthetic TSV) ==="

CLAUDE_MODEL="claude-opus-4-6"
NUM_AGENTS=3
: > "$TMPDIR/env-agents.tsv"
for _i in $(seq 1 "$NUM_AGENTS"); do
    printf '%s\t\t\n' "$CLAUDE_MODEL" >> "$TMPDIR/env-agents.tsv"
done

assert_eq "line count" "3" "$(wc -l < "$TMPDIR/env-agents.tsv" | tr -d ' ')"

AGENT_IDX=0
while IFS=$'\t' read -r m u k; do
    AGENT_IDX=$((AGENT_IDX + 1))
done < "$TMPDIR/env-agents.tsv"
assert_eq "agents iterated" "3" "$AGENT_IDX"

IFS=$'\t' read -r m u k < "$TMPDIR/env-agents.tsv"
assert_eq "env model"    "claude-opus-4-6" "$m"
assert_eq "env base_url" ""               "$u"
assert_eq "env api_key"  ""               "$k"

# ============================================================
echo ""
echo "=== 5. Single agent ==="

cat > "$TMPDIR/single.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "claude-opus-4-6" }]
}
EOF

assert_eq "total agents" "1" "$(parse_num_agents "$TMPDIR/single.json")"
TSV=$(parse_agents_tsv "$TMPDIR/single.json")
assert_eq "line count" "1" "$(echo "$TSV" | wc -l | tr -d ' ')"

# ============================================================
echo ""
echo "=== 6. All custom endpoints (no inherited key) ==="

cat > "$TMPDIR/allcustom.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "m1", "base_url": "https://a.com", "api_key": "k1" },
    { "count": 2, "model": "m2", "base_url": "https://b.com", "api_key": "k2" }
  ]
}
EOF

assert_eq "total agents" "3" "$(parse_num_agents "$TMPDIR/allcustom.json")"
TSV=$(parse_agents_tsv "$TMPDIR/allcustom.json")
assert_eq "no empty keys" "0" "$(echo "$TSV" | awk -F'\t' '$3 == ""' | wc -l | tr -d ' ')"

# ============================================================
echo ""
echo "=== 7. Large count ==="

cat > "$TMPDIR/large.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 20, "model": "claude-opus-4-6" }]
}
EOF

assert_eq "total agents" "20" "$(parse_num_agents "$TMPDIR/large.json")"
TSV=$(parse_agents_tsv "$TMPDIR/large.json")
assert_eq "line count" "20" "$(echo "$TSV" | wc -l | tr -d ' ')"

# ============================================================
echo ""
echo "=== 8. Partial git_user (only name) ==="

cat > "$TMPDIR/partialuser.json" <<'EOF'
{
  "prompt": "p.md",
  "git_user": { "name": "custom-name" },
  "agents": [{ "count": 1, "model": "claude-opus-4-6" }]
}
EOF

assert_eq "git name override"  "custom-name"              "$(parse_git_name "$TMPDIR/partialuser.json")"
assert_eq "git email fallback" "agent@claude-swarm.local"  "$(parse_git_email "$TMPDIR/partialuser.json")"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
