#!/bin/bash
# shellcheck disable=SC2034
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
parse_git_email()  { jq -r '.git_user.email // "agent@swarm.local"' "$1"; }
parse_num_agents()       { jq '[.agents[].count] | add' "$1"; }
parse_inject_git_rules() { jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$1"; }
parse_title()            { jq -r '.title // empty' "$1"; }
parse_pp_prompt()        { jq -r '.post_process.prompt // empty' "$1"; }
parse_pp_model()         { jq -r '.post_process.model // "claude-opus-4-6"' "$1"; }

parse_agents_cfg() {
    jq -r '.driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.driver // $dd // "")] | join("|")' "$1"
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

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "agent 1 model"   "claude-opus-4-6" "$m1"
assert_eq "agent 1 base_url" ""               "$u1"
assert_eq "agent 1 api_key"  ""               "$k1"
assert_eq "agent 1 effort"   ""               "$e1"
assert_eq "agent 1 auth"     ""               "$a1"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 d3 <<< "$LINE3"
assert_eq "agent 3 model" "claude-sonnet-4-5" "$m3"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 d4 <<< "$LINE4"
assert_eq "agent 4 model"    "openrouter/custom"                "$m4"
assert_eq "agent 4 base_url" "https://openrouter.ai/api/v1"     "$u4"
assert_eq "agent 4 api_key"  "sk-or-test"                       "$k4"

IFS='|' read -r m6 u6 k6 e6 a6 c6 p6 t6 d6 <<< "$LINE6"
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
assert_eq "git email default" "agent@swarm.local" "$(parse_git_email "$TMPDIR/minimal.json")"
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
    printf '%s|||%s||||\n' "$CLAUDE_MODEL" "$EFFORT_LEVEL" >> "$TMPDIR/env-agents.cfg"
done

assert_eq "line count" "3" "$(wc -l < "$TMPDIR/env-agents.cfg" | tr -d ' ')"

AGENT_IDX=0
while IFS='|' read -r m u k e a c p t d; do
    AGENT_IDX=$((AGENT_IDX + 1))
done < "$TMPDIR/env-agents.cfg"
assert_eq "agents iterated" "3" "$AGENT_IDX"

IFS='|' read -r m u k e a c p t d < "$TMPDIR/env-agents.cfg"
assert_eq "env model"      "claude-opus-4-6" "$m"
assert_eq "env base_url"   ""               "$u"
assert_eq "env api_key"    ""               "$k"
assert_eq "env effort"     "medium"         "$e"
assert_eq "env auth"       ""               "$a"
assert_eq "env context"    ""               "$c"
assert_eq "env auth_token" ""               "$t"

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
assert_eq "git email fallback" "agent@swarm.local"  "$(parse_git_email "$TMPDIR/partialuser.json")"

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

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "opus effort"   "high"   "$e1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 d2 <<< "$LINE2"
assert_eq "sonnet effort" "medium" "$e2"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 d4 <<< "$LINE4"
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

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "auth apikey"     "apikey" "$a1"
assert_eq "apikey model"    "claude-opus-4-6" "$m1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 d2 <<< "$LINE2"
assert_eq "auth oauth"      "oauth"  "$a2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 d3 <<< "$LINE3"
assert_eq "auth custom"     ""       "$a3"
assert_eq "custom base_url" "https://api.minimax.io" "$u3"
assert_eq "custom api_key"  "sk-mm"  "$k3"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 d4 <<< "$LINE4"
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
echo "=== 16. context field in agents ==="

cat > "$TMPDIR/context.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "claude-opus-4-6", "effort": "high", "context": "none" },
    { "count": 1, "model": "claude-sonnet-4-6", "context": "slim" }
  ]
}
EOF

TSV=$(parse_agents_cfg "$TMPDIR/context.json")
assert_eq "context line count" "3" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE2=$(echo "$TSV" | sed -n '2p')
LINE3=$(echo "$TSV" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "context default (empty)" "" "$c1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 d2 <<< "$LINE2"
assert_eq "context none"   "none" "$c2"
assert_eq "bare model"     "claude-opus-4-6" "$m2"
assert_eq "bare effort"    "high" "$e2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 d3 <<< "$LINE3"
assert_eq "context slim"   "slim" "$c3"
assert_eq "slim model"     "claude-sonnet-4-6" "$m3"

# ============================================================
echo ""
echo "=== 17. prompt field in agents ==="

cat > "$TMPDIR/per_prompt.json" <<'EOF'
{
  "prompt": "tasks/default.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-opus-4-6", "prompt": "tasks/review.md" },
    { "count": 2, "model": "claude-sonnet-4-6", "prompt": "tasks/explore.md", "context": "none" }
  ]
}
EOF

TSV=$(parse_agents_cfg "$TMPDIR/per_prompt.json")
assert_eq "prompt line count" "4" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE2=$(echo "$TSV" | sed -n '2p')
LINE3=$(echo "$TSV" | sed -n '3p')
LINE4=$(echo "$TSV" | sed -n '4p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "prompt default (empty)" "" "$p1"
assert_eq "prompt default model"   "claude-opus-4-6" "$m1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 d2 <<< "$LINE2"
assert_eq "prompt override"  "tasks/review.md" "$p2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 d3 <<< "$LINE3"
assert_eq "prompt + context" "tasks/explore.md" "$p3"
assert_eq "context with prompt" "none" "$c3"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 d4 <<< "$LINE4"
assert_eq "prompt same group" "tasks/explore.md" "$p4"

# ============================================================
echo ""
echo "=== 18. auth_token field (OpenRouter-style Bearer auth) ==="

cat > "$TMPDIR/auth_token.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "openai/gpt-5.4", "base_url": "https://openrouter.ai/api", "auth_token": "sk-or-test" },
    { "count": 1, "model": "MiniMax-M2.5", "base_url": "https://api.minimax.io/anthropic", "api_key": "sk-mm" },
    { "count": 1, "model": "claude-opus-4-6", "auth": "oauth" }
  ]
}
EOF

TSV=$(parse_agents_cfg "$TMPDIR/auth_token.json")
assert_eq "auth_token line count" "3" "$(echo "$TSV" | wc -l | tr -d ' ')"

LINE1=$(echo "$TSV" | sed -n '1p')
LINE2=$(echo "$TSV" | sed -n '2p')
LINE3=$(echo "$TSV" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 d1 <<< "$LINE1"
assert_eq "or model"      "openai/gpt-5.4"          "$m1"
assert_eq "or base_url"   "https://openrouter.ai/api" "$u1"
assert_eq "or api_key"    ""                          "$k1"
assert_eq "or auth_token" "sk-or-test"                "$t1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 d2 <<< "$LINE2"
assert_eq "mm api_key"    "sk-mm" "$k2"
assert_eq "mm auth_token" ""      "$t2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 d3 <<< "$LINE3"
assert_eq "oauth auth_token" "" "$t3"

# ============================================================
echo ""
echo "=== 19. Kitchen sink — every auth, model, effort, context, prompt combination ==="

cat > "$TMPDIR/kitchen_sink.json" <<'EOF'
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 1234567,
  "agents": [
    { "count": 1, "model": "openai/gpt-5.4",     "base_url": "https://openrouter.ai/api",       "auth_token": "$OPENROUTER_API_KEY" },
    { "count": 1, "model": "openai/gpt-5.4-pro",  "base_url": "https://openrouter.ai/api",       "auth_token": "$OPENROUTER_API_KEY" },
    { "count": 1, "model": "MiniMax-M2.5",         "base_url": "https://api.minimax.io/anthropic", "api_key": "$MINIMAX_API_KEY" },
    { "count": 1, "model": "claude-sonnet-4-6",    "effort": "high",   "auth": "oauth" },
    { "count": 1, "model": "claude-opus-4-6",      "effort": "high",   "auth": "oauth", "context": "none" },
    { "count": 1, "model": "claude-opus-4-6",      "effort": "high",   "auth": "oauth", "context": "slim" },
    { "count": 1, "model": "claude-opus-4-6",      "effort": "medium", "auth": "apikey" },
    { "count": 1, "model": "claude-opus-4-6",      "auth": "apikey" },
    { "count": 1, "model": "claude-sonnet-4-6",    "effort": "low",    "auth": "oauth", "prompt": "prompts/reconcile.md" },
    { "count": 1, "model": "claude-sonnet-4-6" },
    { "count": 1, "model": "claude-opus-4-6",      "effort": "high",   "auth": "oauth", "prompt": "prompts/review.md" },
    { "count": 1, "model": "openai/gpt-5.4",       "base_url": "https://openrouter.ai/api", "auth_token": "$OPENROUTER_API_KEY", "effort": "low", "prompt": "prompts/explore.md" }
  ],
  "post_process": {
    "prompt": "prompts/post.md",
    "model": "claude-sonnet-4-6",
    "effort": "high",
    "auth": "oauth"
  }
}
EOF

assert_eq "ks prompt"     "prompts/task.md"  "$(parse_prompt "$TMPDIR/kitchen_sink.json")"
assert_eq "ks setup"      "scripts/setup.sh" "$(parse_setup "$TMPDIR/kitchen_sink.json")"
assert_eq "ks max_idle"   "1234567"            "$(parse_max_idle "$TMPDIR/kitchen_sink.json")"
assert_eq "ks total"      "12"                 "$(parse_num_agents "$TMPDIR/kitchen_sink.json")"

TSV=$(parse_agents_cfg "$TMPDIR/kitchen_sink.json")
assert_eq "ks line count" "12" "$(echo "$TSV" | wc -l | tr -d ' ')"

# Agent 1: OpenRouter GPT-5.4 via auth_token
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '1p')"
assert_eq "ks1 model"      "openai/gpt-5.4"            "$m"
assert_eq "ks1 base_url"   "https://openrouter.ai/api"  "$u"
assert_eq "ks1 api_key"    ""                            "$k"
assert_eq "ks1 effort"     ""                            "$e"
assert_eq "ks1 auth"       ""                            "$a"
assert_eq "ks1 context"    ""                            "$c"
assert_eq "ks1 prompt"     ""                            "$p"
assert_eq "ks1 auth_token" "\$OPENROUTER_API_KEY"        "$t"

# Agent 2: OpenRouter GPT-5.4-pro via auth_token
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '2p')"
assert_eq "ks2 model"      "openai/gpt-5.4-pro"         "$m"
assert_eq "ks2 base_url"   "https://openrouter.ai/api"  "$u"
assert_eq "ks2 api_key"    ""                            "$k"
assert_eq "ks2 auth_token" "\$OPENROUTER_API_KEY"        "$t"

# Agent 3: MiniMax via api_key
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '3p')"
assert_eq "ks3 model"      "MiniMax-M2.5"                         "$m"
assert_eq "ks3 base_url"   "https://api.minimax.io/anthropic"     "$u"
assert_eq "ks3 api_key"    "\$MINIMAX_API_KEY"                     "$k"
assert_eq "ks3 auth_token" ""                                      "$t"

# Agent 4: Claude Sonnet, oauth, high effort
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '4p')"
assert_eq "ks4 model"      "claude-sonnet-4-6" "$m"
assert_eq "ks4 base_url"   ""                  "$u"
assert_eq "ks4 api_key"    ""                  "$k"
assert_eq "ks4 effort"     "high"              "$e"
assert_eq "ks4 auth"       "oauth"             "$a"
assert_eq "ks4 context"    ""                  "$c"
assert_eq "ks4 prompt"     ""                  "$p"
assert_eq "ks4 auth_token" ""                  "$t"

# Agent 5: Claude Opus, oauth, high effort, context=none
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '5p')"
assert_eq "ks5 model"   "claude-opus-4-6" "$m"
assert_eq "ks5 effort"  "high"            "$e"
assert_eq "ks5 auth"    "oauth"           "$a"
assert_eq "ks5 context" "none"            "$c"
assert_eq "ks5 prompt"  ""                "$p"

# Agent 6: Claude Opus, oauth, high effort, context=slim
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '6p')"
assert_eq "ks6 model"   "claude-opus-4-6" "$m"
assert_eq "ks6 effort"  "high"            "$e"
assert_eq "ks6 auth"    "oauth"           "$a"
assert_eq "ks6 context" "slim"            "$c"

# Agent 7: Claude Opus, apikey, medium effort
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '7p')"
assert_eq "ks7 model"  "claude-opus-4-6" "$m"
assert_eq "ks7 effort" "medium"          "$e"
assert_eq "ks7 auth"   "apikey"          "$a"
assert_eq "ks7 context" ""               "$c"

# Agent 8: Claude Opus, apikey, no effort
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '8p')"
assert_eq "ks8 model"  "claude-opus-4-6" "$m"
assert_eq "ks8 effort" ""                "$e"
assert_eq "ks8 auth"   "apikey"          "$a"

# Agent 9: Claude Sonnet, oauth, low effort, per-group reconcile prompt
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '9p')"
assert_eq "ks9 model"  "claude-sonnet-4-6"              "$m"
assert_eq "ks9 effort" "low"                             "$e"
assert_eq "ks9 auth"   "oauth"                           "$a"
assert_eq "ks9 prompt" "prompts/reconcile.md"            "$p"

# Agent 10: Claude Sonnet, all defaults (no auth, no effort, no context)
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '10p')"
assert_eq "ks10 model"      "claude-sonnet-4-6" "$m"
assert_eq "ks10 base_url"   ""                  "$u"
assert_eq "ks10 api_key"    ""                  "$k"
assert_eq "ks10 effort"     ""                  "$e"
assert_eq "ks10 auth"       ""                  "$a"
assert_eq "ks10 context"    ""                  "$c"
assert_eq "ks10 prompt"     ""                  "$p"
assert_eq "ks10 auth_token" ""                  "$t"

# Agent 11: Claude Opus, oauth, high effort, per-group alt prompt
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '11p')"
assert_eq "ks11 model"  "claude-opus-4-6" "$m"
assert_eq "ks11 effort" "high"            "$e"
assert_eq "ks11 auth"   "oauth"           "$a"
assert_eq "ks11 prompt" "prompts/review.md" "$p"

# Agent 12: OpenRouter GPT-5.4 + auth_token + effort + per-group prompt
IFS='|' read -r m u k e a c p t d <<< "$(echo "$TSV" | sed -n '12p')"
assert_eq "ks12 model"      "openai/gpt-5.4"            "$m"
assert_eq "ks12 base_url"   "https://openrouter.ai/api"  "$u"
assert_eq "ks12 effort"     "low"                         "$e"
assert_eq "ks12 auth_token" "\$OPENROUTER_API_KEY"        "$t"
assert_eq "ks12 prompt"     "prompts/explore.md"          "$p"

# Post-process section
assert_eq "ks pp prompt" "prompts/post.md"         "$(parse_pp_prompt "$TMPDIR/kitchen_sink.json")"
assert_eq "ks pp model"  "claude-sonnet-4-6"       "$(parse_pp_model "$TMPDIR/kitchen_sink.json")"
assert_eq "ks pp effort" "high"                    "$(parse_pp_effort "$TMPDIR/kitchen_sink.json")"
assert_eq "ks pp auth"   "oauth"                   "$(parse_pp_auth "$TMPDIR/kitchen_sink.json")"

# ============================================================
echo ""
echo "=== 20. Post-process auth variants ==="

# pp with auth_token (OpenRouter-style)
cat > "$TMPDIR/pp_auth_token.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "openai/gpt-5.4",
    "base_url": "https://openrouter.ai/api",
    "auth_token": "$OPENROUTER_API_KEY"
  }
}
EOF

assert_eq "pp or model"      "openai/gpt-5.4"          "$(parse_pp_model "$TMPDIR/pp_auth_token.json")"
assert_eq "pp or auth_token" "\$OPENROUTER_API_KEY"     "$(jq -r '.post_process.auth_token // empty' "$TMPDIR/pp_auth_token.json")"
assert_eq "pp or base_url"   "https://openrouter.ai/api" "$(jq -r '.post_process.base_url // empty' "$TMPDIR/pp_auth_token.json")"
assert_eq "pp or api_key"    ""                         "$(jq -r '.post_process.api_key // empty' "$TMPDIR/pp_auth_token.json")"

# pp with api_key (MiniMax-style)
cat > "$TMPDIR/pp_apikey_custom.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "MiniMax-M2.5",
    "base_url": "https://api.minimax.io/anthropic",
    "api_key": "$MINIMAX_API_KEY"
  }
}
EOF

assert_eq "pp mm model"    "MiniMax-M2.5"                     "$(parse_pp_model "$TMPDIR/pp_apikey_custom.json")"
assert_eq "pp mm api_key"  "\$MINIMAX_API_KEY"                 "$(jq -r '.post_process.api_key // empty' "$TMPDIR/pp_apikey_custom.json")"
assert_eq "pp mm base_url" "https://api.minimax.io/anthropic" "$(jq -r '.post_process.base_url // empty' "$TMPDIR/pp_apikey_custom.json")"

# pp with apikey auth (Claude API key)
cat > "$TMPDIR/pp_apikey.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "claude-opus-4-6",
    "auth": "apikey"
  }
}
EOF

assert_eq "pp apikey auth"  "apikey"          "$(parse_pp_auth "$TMPDIR/pp_apikey.json")"
assert_eq "pp apikey model" "claude-opus-4-6" "$(parse_pp_model "$TMPDIR/pp_apikey.json")"

# pp with default auth (no auth field)
cat > "$TMPDIR/pp_default.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "claude-sonnet-4-6"
  }
}
EOF

assert_eq "pp default auth"  ""                 "$(parse_pp_auth "$TMPDIR/pp_default.json")"
assert_eq "pp default model" "claude-sonnet-4-6" "$(parse_pp_model "$TMPDIR/pp_default.json")"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
