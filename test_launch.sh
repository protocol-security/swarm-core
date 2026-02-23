#!/bin/bash
set -euo pipefail

# Unit tests for launch.sh parsing logic.
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

# --- Helpers: same logic used in launch.sh ---

shorten_model() {
    local m="$1"
    local short="${m/claude-/}"
    short="${short//\//-}"
    echo "$short"
}

parse_inject_git_rules() { jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$1"; }

parse_pp_prompt()   { jq -r '.post_process.prompt // empty' "$1"; }
parse_pp_model()    { jq -r '.post_process.model // "claude-opus-4-6"' "$1"; }
parse_pp_base_url() { jq -r '.post_process.base_url // empty' "$1"; }
parse_pp_api_key()  { jq -r '.post_process.api_key // empty' "$1"; }
parse_pp_effort()   { jq -r '.post_process.effort // empty' "$1"; }

parse_agents_cfg() {
    jq -r '.agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // "")] | join("|")' "$1"
}

# ============================================================
echo "=== 1. Model name shortening ==="

assert_eq "opus"        "opus-4-6"          "$(shorten_model "claude-opus-4-6")"
assert_eq "sonnet"      "sonnet-4-5"        "$(shorten_model "claude-sonnet-4-5")"
assert_eq "haiku"       "haiku-4-5"         "$(shorten_model "claude-haiku-4-5")"
assert_eq "openrouter"  "openrouter-custom" "$(shorten_model "openrouter/custom")"
assert_eq "no prefix"   "MiniMax-M2.5"      "$(shorten_model "MiniMax-M2.5")"
assert_eq "double slash" "a-b-c"            "$(shorten_model "a/b/c")"

# ============================================================
echo ""
echo "=== 2. TSV generation (env var path) ==="

CLAUDE_MODEL="claude-opus-4-6"
EFFORT_LEVEL="medium"
NUM_AGENTS=3
: > "$TMPDIR/env-agents.cfg"
for _i in $(seq 1 "$NUM_AGENTS"); do
    printf '%s|||%s\n' "$CLAUDE_MODEL" "$EFFORT_LEVEL" >> "$TMPDIR/env-agents.cfg"
done

assert_eq "line count" "3" "$(wc -l < "$TMPDIR/env-agents.cfg" | tr -d ' ')"

IFS='|' read -r m u k e < "$TMPDIR/env-agents.cfg"
assert_eq "model"    "claude-opus-4-6" "$m"
assert_eq "base_url" ""               "$u"
assert_eq "api_key"  ""               "$k"
assert_eq "effort"   "medium"         "$e"

# ============================================================
echo ""
echo "=== 3. inject_git_rules config ==="

cat > "$TMPDIR/default.json" <<'EOF'
{ "prompt": "p.md", "agents": [{ "count": 1, "model": "m" }] }
EOF

cat > "$TMPDIR/inject_false.json" <<'EOF'
{ "prompt": "p.md", "inject_git_rules": false, "agents": [{ "count": 1, "model": "m" }] }
EOF

cat > "$TMPDIR/inject_true.json" <<'EOF'
{ "prompt": "p.md", "inject_git_rules": true, "agents": [{ "count": 1, "model": "m" }] }
EOF

assert_eq "default is true"   "true"  "$(parse_inject_git_rules "$TMPDIR/default.json")"
assert_eq "explicit false"    "false" "$(parse_inject_git_rules "$TMPDIR/inject_false.json")"
assert_eq "explicit true"     "true"  "$(parse_inject_git_rules "$TMPDIR/inject_true.json")"

# ============================================================
echo ""
echo "=== 4. Post-process config parsing ==="

cat > "$TMPDIR/pp_full.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "claude-sonnet-4-5",
    "base_url": "https://example.com",
    "api_key": "sk-pp-test"
  }
}
EOF

assert_eq "pp prompt"   "review.md"           "$(parse_pp_prompt "$TMPDIR/pp_full.json")"
assert_eq "pp model"    "claude-sonnet-4-5"    "$(parse_pp_model "$TMPDIR/pp_full.json")"
assert_eq "pp base_url" "https://example.com"  "$(parse_pp_base_url "$TMPDIR/pp_full.json")"
assert_eq "pp api_key"  "sk-pp-test"           "$(parse_pp_api_key "$TMPDIR/pp_full.json")"

cat > "$TMPDIR/pp_minimal.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "review.md" }
}
EOF

assert_eq "pp model default"    "claude-opus-4-6" "$(parse_pp_model "$TMPDIR/pp_minimal.json")"
assert_eq "pp base_url empty"   ""                 "$(parse_pp_base_url "$TMPDIR/pp_minimal.json")"
assert_eq "pp api_key empty"    ""                 "$(parse_pp_api_key "$TMPDIR/pp_minimal.json")"

cat > "$TMPDIR/no_pp.json" <<'EOF'
{ "prompt": "p.md", "agents": [{ "count": 1, "model": "m" }] }
EOF

assert_eq "no pp prompt" "" "$(parse_pp_prompt "$TMPDIR/no_pp.json")"

# ============================================================
echo ""
echo "=== 5. Git user name with model tag ==="

GIT_USER_NAME="swarm-agent"
agent_model="claude-opus-4-6"
short_model="${agent_model/claude-/}"
short_model="${short_model//\//-}"
agent_git_name="${GIT_USER_NAME} [${short_model}]"
assert_eq "git name tag" "swarm-agent [opus-4-6]" "$agent_git_name"

GIT_USER_NAME="Nikos Baxevanis"
agent_model="MiniMax-M2.5"
short_model="${agent_model/claude-/}"
short_model="${short_model//\//-}"
agent_git_name="${GIT_USER_NAME} [${short_model}]"
assert_eq "custom name tag" "Nikos Baxevanis [MiniMax-M2.5]" "$agent_git_name"

# ============================================================
echo ""
echo "=== 6. Effort in agent TSV (config path) ==="

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

CFG=$(parse_agents_cfg "$TMPDIR/effort.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE2=$(echo "$CFG" | sed -n '2p')
LINE4=$(echo "$CFG" | sed -n '4p')

IFS='|' read -r m1 u1 k1 e1 <<< "$LINE1"
assert_eq "opus effort"  "high"   "$e1"

IFS='|' read -r m2 u2 k2 e2 <<< "$LINE2"
assert_eq "sonnet effort" "medium" "$e2"

IFS='|' read -r m4 u4 k4 e4 <<< "$LINE4"
assert_eq "haiku effort (empty)" "" "$e4"

# ============================================================
echo ""
echo "=== 7. Effort in post-process ==="

cat > "$TMPDIR/pp_effort.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": {
    "prompt": "review.md",
    "model": "claude-opus-4-6",
    "effort": "low"
  }
}
EOF

assert_eq "pp effort"       "low" "$(parse_pp_effort "$TMPDIR/pp_effort.json")"
assert_eq "pp effort absent" ""   "$(parse_pp_effort "$TMPDIR/no_pp.json")"

# ============================================================
echo ""
echo "=== 8. Effort env var fallback (no effort set) ==="

EFFORT_LEVEL=""
: > "$TMPDIR/env-no-effort.cfg"
printf '%s|||%s\n' "claude-opus-4-6" "$EFFORT_LEVEL" >> "$TMPDIR/env-no-effort.cfg"

IFS='|' read -r m u k e < "$TMPDIR/env-no-effort.cfg"
assert_eq "no effort" "" "$e"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
