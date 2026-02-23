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
parse_num_agents()       { jq '[.agents[].count] | add' "$1"; }
parse_inject_git_rules() { jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$1"; }
parse_title()            { jq -r '.title // empty' "$1"; }
parse_pp_prompt()        { jq -r '.post_process.prompt // empty' "$1"; }
parse_pp_model()         { jq -r '.post_process.model // "claude-opus-4-6"' "$1"; }

parse_agents_cfg() {
    jq -r '.agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // "")] | join("|")' "$1"
}

parse_pp_auth() { jq -r '.post_process.auth // empty' "$1"; }

parse_pp_effort() { jq -r '.post_process.effort // empty' "$1"; }

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

TSV=$(parse_agents_cfg "$TMPDIR/mixed.json")
assert_eq "line count" "6" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE3=$(echo "$TSV" | sed -n '3p')
LINE4=$(echo "$TSV" | sed -n '4p')
LINE6=$(echo "$TSV" | sed -n '6p')

IFS='|' read -r m1 u1 k1 e1 a1 <<< "$LINE1"
assert_eq "agent 1 model"   "claude-opus-4-6" "$m1"
assert_eq "agent 1 base_url" ""               "$u1"
assert_eq "agent 1 api_key"  ""               "$k1"
assert_eq "agent 1 effort"   ""               "$e1"
assert_eq "agent 1 auth"     ""               "$a1"

IFS='|' read -r m3 u3 k3 e3 a3 <<< "$LINE3"
assert_eq "agent 3 model" "claude-sonnet-4-5" "$m3"

IFS='|' read -r m4 u4 k4 e4 a4 <<< "$LINE4"
assert_eq "agent 4 model"    "openrouter/custom"                "$m4"
assert_eq "agent 4 base_url" "https://openrouter.ai/api/v1"     "$u4"
assert_eq "agent 4 api_key"  "sk-or-test"                       "$k4"

IFS='|' read -r m6 u6 k6 e6 a6 <<< "$LINE6"
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

TSV=$(parse_agents_cfg "$TMPDIR/minimal.json")
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
EFFORT_LEVEL="medium"
NUM_AGENTS=3
: > "$TMPDIR/env-agents.cfg"
for _i in $(seq 1 "$NUM_AGENTS"); do
    printf '%s|||%s|\n' "$CLAUDE_MODEL" "$EFFORT_LEVEL" >> "$TMPDIR/env-agents.cfg"
done

assert_eq "line count" "3" "$(wc -l < "$TMPDIR/env-agents.cfg" | tr -d ' ')"

AGENT_IDX=0
while IFS='|' read -r m u k e a; do
    AGENT_IDX=$((AGENT_IDX + 1))
done < "$TMPDIR/env-agents.cfg"
assert_eq "agents iterated" "3" "$AGENT_IDX"

IFS='|' read -r m u k e a < "$TMPDIR/env-agents.cfg"
assert_eq "env model"    "claude-opus-4-6" "$m"
assert_eq "env base_url" ""               "$u"
assert_eq "env api_key"  ""               "$k"
assert_eq "env effort"   "medium"         "$e"
assert_eq "env auth"     ""               "$a"

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
TSV=$(parse_agents_cfg "$TMPDIR/single.json")
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
TSV=$(parse_agents_cfg "$TMPDIR/allcustom.json")
assert_eq "no empty keys" "0" "$(echo "$TSV" | awk -F'|' '$3 == ""' | wc -l | tr -d ' ')"

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
TSV=$(parse_agents_cfg "$TMPDIR/large.json")
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
echo "=== 9. inject_git_rules field ==="

cat > "$TMPDIR/inject_default.json" <<'EOF'
{ "prompt": "p.md", "agents": [{ "count": 1, "model": "m" }] }
EOF

cat > "$TMPDIR/inject_false.json" <<'EOF'
{ "prompt": "p.md", "inject_git_rules": false, "agents": [{ "count": 1, "model": "m" }] }
EOF

cat > "$TMPDIR/inject_true.json" <<'EOF'
{ "prompt": "p.md", "inject_git_rules": true, "agents": [{ "count": 1, "model": "m" }] }
EOF

assert_eq "inject default"  "true"  "$(parse_inject_git_rules "$TMPDIR/inject_default.json")"
assert_eq "inject false"    "false" "$(parse_inject_git_rules "$TMPDIR/inject_false.json")"
assert_eq "inject true"     "true"  "$(parse_inject_git_rules "$TMPDIR/inject_true.json")"

# ============================================================
echo ""
echo "=== 10. title field ==="

cat > "$TMPDIR/title.json" <<'EOF'
{ "prompt": "p.md", "title": "My Project", "agents": [{ "count": 1, "model": "m" }] }
EOF

assert_eq "title present" "My Project" "$(parse_title "$TMPDIR/title.json")"
assert_eq "title missing" ""           "$(parse_title "$TMPDIR/inject_default.json")"

# ============================================================
echo ""
echo "=== 11. post_process section ==="

cat > "$TMPDIR/pp.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "claude-sonnet-4-5"
  }
}
EOF

assert_eq "pp prompt"       "review.md"         "$(parse_pp_prompt "$TMPDIR/pp.json")"
assert_eq "pp model"        "claude-sonnet-4-5"  "$(parse_pp_model "$TMPDIR/pp.json")"
assert_eq "pp prompt absent" ""                  "$(parse_pp_prompt "$TMPDIR/inject_default.json")"
assert_eq "pp model default" "claude-opus-4-6"   "$(parse_pp_model "$TMPDIR/inject_default.json")"

# ============================================================
echo ""
echo "=== 12. effort field in agents ==="

cat > "$TMPDIR/effort.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 2, "model": "claude-sonnet-4-6", "effort": "medium" },
    { "count": 1, "model": "claude-haiku-4-5" }
  ]
}
EOF

TSV=$(parse_agents_cfg "$TMPDIR/effort.json")
assert_eq "effort line count" "4" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE2=$(echo "$TSV" | sed -n '2p')
LINE4=$(echo "$TSV" | sed -n '4p')

IFS='|' read -r m1 u1 k1 e1 a1 <<< "$LINE1"
assert_eq "opus effort"   "high"   "$e1"

IFS='|' read -r m2 u2 k2 e2 a2 <<< "$LINE2"
assert_eq "sonnet effort" "medium" "$e2"

IFS='|' read -r m4 u4 k4 e4 a4 <<< "$LINE4"
assert_eq "haiku effort (empty)" "" "$e4"

# ============================================================
echo ""
echo "=== 13. effort in post_process ==="

cat > "$TMPDIR/pp_effort.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "effort": "low"
  }
}
EOF

assert_eq "pp effort"        "low" "$(parse_pp_effort "$TMPDIR/pp_effort.json")"
assert_eq "pp effort absent" ""    "$(parse_pp_effort "$TMPDIR/inject_default.json")"

# ============================================================
echo ""
echo "=== 14. auth field in agents ==="

cat > "$TMPDIR/auth.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "auth": "apikey" },
    { "count": 1, "model": "claude-opus-4-6", "auth": "oauth" },
    { "count": 1, "model": "MiniMax-M2.5", "base_url": "https://api.minimax.io", "api_key": "sk-mm" },
    { "count": 1, "model": "claude-opus-4-6" }
  ]
}
EOF

TSV=$(parse_agents_cfg "$TMPDIR/auth.json")
assert_eq "auth line count" "4" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE2=$(echo "$TSV" | sed -n '2p')
LINE3=$(echo "$TSV" | sed -n '3p')
LINE4=$(echo "$TSV" | sed -n '4p')

IFS='|' read -r m1 u1 k1 e1 a1 <<< "$LINE1"
assert_eq "auth apikey"     "apikey" "$a1"
assert_eq "apikey model"    "claude-opus-4-6" "$m1"

IFS='|' read -r m2 u2 k2 e2 a2 <<< "$LINE2"
assert_eq "auth oauth"      "oauth"  "$a2"

IFS='|' read -r m3 u3 k3 e3 a3 <<< "$LINE3"
assert_eq "auth custom"     ""       "$a3"
assert_eq "custom base_url" "https://api.minimax.io" "$u3"
assert_eq "custom api_key"  "sk-mm"  "$k3"

IFS='|' read -r m4 u4 k4 e4 a4 <<< "$LINE4"
assert_eq "auth default"    ""       "$a4"

# ============================================================
echo ""
echo "=== 15. auth in post_process ==="

cat > "$TMPDIR/pp_auth.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "auth": "oauth"
  }
}
EOF

assert_eq "pp auth"        "oauth" "$(parse_pp_auth "$TMPDIR/pp_auth.json")"
assert_eq "pp auth absent" ""      "$(parse_pp_auth "$TMPDIR/inject_default.json")"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
