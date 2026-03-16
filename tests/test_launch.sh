#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for launch.sh parsing logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    jq -r '.driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // ""), (.driver // $dd // "")] | join("|")' "$1"
}

# Mirrors the per-agent credential selection in launch.sh.
resolve_agent_creds() {
    local agent_auth="$1" agent_api_key="$2" global_api_key="$3" global_oauth="$4"
    local resolved_key="" oauth_env=""
    case "${agent_auth}" in
        oauth)
            resolved_key=""
            oauth_env="CLAUDE_CODE_OAUTH_TOKEN=${global_oauth}"
            ;;
        apikey)
            resolved_key="${agent_api_key:-${global_api_key}}"
            oauth_env=""
            ;;
        *)
            resolved_key="${agent_api_key:-${global_api_key}}"
            [ -n "$global_oauth" ] && oauth_env="CLAUDE_CODE_OAUTH_TOKEN=${global_oauth}"
            ;;
    esac
    echo "${resolved_key}|${oauth_env}"
}

# Mirrors the auth_label computation in launch.sh (after credential resolution).
# Args: agent_auth agent_api_key agent_auth_token resolved_api_key global_oauth
resolve_auth_label() {
    local agent_auth="$1" agent_api_key="$2" agent_auth_token="$3"
    local resolved_api_key="$4" global_oauth="$5"
    local auth_label=""
    if [ -n "$agent_auth_token" ]; then
        auth_label="token"
    elif [ "$agent_auth" = "oauth" ]; then
        auth_label="oauth"
    elif [ "$agent_auth" = "apikey" ]; then
        auth_label="key"
    elif [ -n "$agent_api_key" ]; then
        auth_label="key"
    elif [ -n "$resolved_api_key" ] && [ -n "$global_oauth" ]; then
        auth_label="auto"
    elif [ -n "$resolved_api_key" ]; then
        auth_label="key"
    elif [ -n "$global_oauth" ]; then
        auth_label="oauth"
    fi
    echo "$auth_label"
}

# Mirrors the validation guard in cmd_start().
check_auth() {
    local api_key="$1" oauth_token="$2" config_file="$3"
    if [ -z "$api_key" ] && [ -z "$oauth_token" ] && [ -z "$config_file" ]; then
        echo "fail"
    else
        echo "pass"
    fi
}

# Mirrors the EXTRA_ENV construction for CLAUDE_CODE_OAUTH_TOKEN.
build_oauth_extra_env() {
    local token="$1"
    local -a EXTRA_ENV=()
    [ -n "$token" ] \
        && EXTRA_ENV+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${token}")
    echo "${EXTRA_ENV[*]+"${EXTRA_ENV[*]}"}"
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

SWARM_MODEL="claude-opus-4-6"
EFFORT_LEVEL="medium"
NUM_AGENTS=3
: > "$TMPDIR/env-agents.cfg"
for _i in $(seq 1 "$NUM_AGENTS"); do
    printf '%s|||%s||||||\n' "$SWARM_MODEL" "$EFFORT_LEVEL" >> "$TMPDIR/env-agents.cfg"
done

assert_eq "line count" "3" "$(wc -l < "$TMPDIR/env-agents.cfg" | tr -d ' ')"

IFS='|' read -r m u k e a c p t g d < "$TMPDIR/env-agents.cfg"
assert_eq "model"    "claude-opus-4-6" "$m"
assert_eq "base_url" ""               "$u"
assert_eq "api_key"  ""               "$k"
assert_eq "effort"   "medium"         "$e"
assert_eq "auth"     ""               "$a"
assert_eq "context"  ""               "$c"

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
echo "=== 5. Git user name is clean (no model tag) ==="

GIT_USER_NAME="swarm-agent"
assert_eq "default name clean" "swarm-agent" "$GIT_USER_NAME"

GIT_USER_NAME="Nikos Baxevanis"
assert_eq "custom name clean" "Nikos Baxevanis" "$GIT_USER_NAME"

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

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "opus effort"  "high"   "$e1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 g2 d2 <<< "$LINE2"
assert_eq "sonnet effort" "medium" "$e2"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 g4 d4 <<< "$LINE4"
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
printf '%s|||%s||||||\n' "claude-opus-4-6" "$EFFORT_LEVEL" >> "$TMPDIR/env-no-effort.cfg"

IFS='|' read -r m u k e a c p t g d < "$TMPDIR/env-no-effort.cfg"
assert_eq "no effort" "" "$e"

# ============================================================
echo ""
echo "=== 9. OAuth auth validation ==="

assert_eq "api_key only"        "pass" "$(check_auth "sk-key" "" "")"
assert_eq "oauth only"          "pass" "$(check_auth "" "sk-ant-oat01-tok" "")"
assert_eq "both set"            "pass" "$(check_auth "sk-key" "sk-ant-oat01-tok" "")"
assert_eq "config only"         "pass" "$(check_auth "" "" "swarm.json")"
assert_eq "nothing set"         "fail" "$(check_auth "" "" "")"
assert_eq "oauth + config"      "pass" "$(check_auth "" "sk-ant-oat01-tok" "swarm.json")"

# ============================================================
echo ""
echo "=== 10. OAuth EXTRA_ENV construction ==="

assert_eq "oauth env set" \
    "-e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test" \
    "$(build_oauth_extra_env "sk-ant-oat01-test")"
assert_eq "oauth env empty" "" "$(build_oauth_extra_env "")"

# ============================================================
echo ""
echo "=== 11. Per-agent auth field in TSV ==="

cat > "$TMPDIR/auth_mixed.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "auth": "apikey" },
    { "count": 1, "model": "claude-opus-4-6", "auth": "oauth" },
    { "count": 1, "model": "MiniMax-M2.5", "base_url": "https://api.minimax.io", "api_key": "sk-mm" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/auth_mixed.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE2=$(echo "$CFG" | sed -n '2p')
LINE3=$(echo "$CFG" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "auth apikey"  "apikey"  "$a1"
assert_eq "auth apikey model" "claude-opus-4-6" "$m1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 g2 d2 <<< "$LINE2"
assert_eq "auth oauth"   "oauth"   "$a2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 g3 d3 <<< "$LINE3"
assert_eq "auth custom (empty)" "" "$a3"
assert_eq "auth custom key" "sk-mm" "$k3"

# ============================================================
echo ""
echo "=== 12. Per-agent credential resolution ==="

RESULT=$(resolve_agent_creds "oauth" "" "sk-global" "sk-oat-tok")
IFS='|' read -r rk re <<< "$RESULT"
assert_eq "oauth: api_key cleared"  ""  "$rk"
assert_eq "oauth: token passed" "CLAUDE_CODE_OAUTH_TOKEN=sk-oat-tok" "$re"

RESULT=$(resolve_agent_creds "apikey" "" "sk-global" "sk-oat-tok")
IFS='|' read -r rk re <<< "$RESULT"
assert_eq "apikey: api_key set"   "sk-global" "$rk"
assert_eq "apikey: no token"      ""           "$re"

RESULT=$(resolve_agent_creds "" "" "sk-global" "sk-oat-tok")
IFS='|' read -r rk re <<< "$RESULT"
assert_eq "default: api_key set"  "sk-global" "$rk"
assert_eq "default: token passed" "CLAUDE_CODE_OAUTH_TOKEN=sk-oat-tok" "$re"

RESULT=$(resolve_agent_creds "" "sk-agent" "sk-global" "sk-oat-tok")
IFS='|' read -r rk re <<< "$RESULT"
assert_eq "custom key overrides"  "sk-agent" "$rk"

RESULT=$(resolve_agent_creds "" "" "sk-global" "")
IFS='|' read -r rk re <<< "$RESULT"
assert_eq "no oauth: api_key set" "sk-global" "$rk"
assert_eq "no oauth: no token"    ""           "$re"

# ============================================================
echo ""
echo "=== 13. Context field in agent TSV ==="

cat > "$TMPDIR/context.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "claude-opus-4-6", "context": "none" },
    { "count": 1, "model": "claude-sonnet-4-6", "context": "slim" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/context.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE2=$(echo "$CFG" | sed -n '2p')
LINE3=$(echo "$CFG" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "context default (empty)" "" "$c1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 g2 d2 <<< "$LINE2"
assert_eq "context none" "none" "$c2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 g3 d3 <<< "$LINE3"
assert_eq "context slim" "slim" "$c3"

# ============================================================
echo ""
echo "=== 14. Prompt field in agent TSV ==="

cat > "$TMPDIR/per_prompt.json" <<'EOF'
{
  "prompt": "tasks/default.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-opus-4-6", "prompt": "tasks/review.md" },
    { "count": 1, "model": "claude-sonnet-4-6", "prompt": "tasks/explore.md", "context": "none" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/per_prompt.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE2=$(echo "$CFG" | sed -n '2p')
LINE3=$(echo "$CFG" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "prompt default (empty)" "" "$p1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 g2 d2 <<< "$LINE2"
assert_eq "prompt override" "tasks/review.md" "$p2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 g3 d3 <<< "$LINE3"
assert_eq "prompt + context" "tasks/explore.md" "$p3"
assert_eq "context preserved" "none" "$c3"

# ============================================================
echo ""
echo "=== 15. Tag field in agent TSV ==="

cat > "$TMPDIR/tagged.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 2, "model": "claude-opus-4-6", "tag": "explore" },
    { "count": 1, "model": "claude-sonnet-4-6", "tag": "review" },
    { "count": 1, "model": "claude-haiku-4-5" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/tagged.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE3=$(echo "$CFG" | sed -n '3p')
LINE4=$(echo "$CFG" | sed -n '4p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "tag explore" "explore" "$g1"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 g3 d3 <<< "$LINE3"
assert_eq "tag review" "review" "$g3"

IFS='|' read -r m4 u4 k4 e4 a4 c4 p4 t4 g4 d4 <<< "$LINE4"
assert_eq "tag empty" "" "$g4"

# ============================================================
echo ""
echo "=== 16. parse_start_args — basic flags ==="

# Source the function from launch.sh without executing the
# case statement.  We extract it with sed to avoid side effects
# (git rev-parse, docker, etc.).
_LAUNCH="$TESTS_DIR/../launch.sh"
eval "$(sed -n '/^parse_start_args()/,/^}/p' "$_LAUNCH")"

# Reset variables to known state before each sub-test.
reset_vars() {
    SWARM_PROMPT="orig.md"
    SWARM_MODEL="orig-model"
    NUM_AGENTS=1
    MAX_IDLE=3
    EFFORT_LEVEL=""
    SWARM_SETUP=""
    INJECT_GIT_RULES="true"
    OPEN_DASHBOARD=false
    AGENTS_CLI_OVERRIDE=false
}

reset_vars
parse_start_args --prompt new.md --model new-model --agents 5
assert_eq "cli prompt"  "new.md"    "$SWARM_PROMPT"
assert_eq "cli model"   "new-model" "$SWARM_MODEL"
assert_eq "cli agents"  "5"         "$NUM_AGENTS"

reset_vars
parse_start_args --max-idle 7 --effort high --setup s.sh
assert_eq "cli max-idle" "7"    "$MAX_IDLE"
assert_eq "cli effort"   "high" "$EFFORT_LEVEL"
assert_eq "cli setup"    "s.sh" "$SWARM_SETUP"

reset_vars
parse_start_args --no-inject-git-rules
assert_eq "cli no-inject" "false" "$INJECT_GIT_RULES"

reset_vars
parse_start_args --dashboard
assert_eq "cli dashboard" "true" "$OPEN_DASHBOARD"

# ============================================================
echo ""
echo "=== 17. parse_start_args — no args leaves defaults ==="

reset_vars
parse_start_args
assert_eq "default prompt"  "orig.md"    "$SWARM_PROMPT"
assert_eq "default model"   "orig-model" "$SWARM_MODEL"
assert_eq "default agents"  "1"          "$NUM_AGENTS"
assert_eq "default idle"    "3"          "$MAX_IDLE"
assert_eq "default effort"  ""           "$EFFORT_LEVEL"
assert_eq "default inject"  "true"       "$INJECT_GIT_RULES"
assert_eq "default dash"    "false"      "$OPEN_DASHBOARD"

# ============================================================
echo ""
echo "=== 18. parse_start_args — CLI overrides env vars ==="

SWARM_PROMPT="env.md"
SWARM_MODEL="env-model"
NUM_AGENTS=2
parse_start_args --prompt cli.md --model cli-model --agents 8
assert_eq "cli > env prompt" "cli.md"    "$SWARM_PROMPT"
assert_eq "cli > env model"  "cli-model" "$SWARM_MODEL"
assert_eq "cli > env agents" "8"         "$NUM_AGENTS"

# ============================================================
echo ""
echo "=== 19. parse_start_args — unknown flag errors ==="

reset_vars
if (parse_start_args --bogus 2>/dev/null); then
    echo "  FAIL: unknown flag should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: unknown flag rejected"
    PASS=$((PASS + 1))
fi

# ============================================================
echo ""
echo "=== 20. parse_start_args — combined flags ==="

reset_vars
parse_start_args --prompt p.md --model m --agents 4 \
    --max-idle 2 --effort low --setup x.sh \
    --no-inject-git-rules --dashboard
assert_eq "combo prompt"  "p.md"  "$SWARM_PROMPT"
assert_eq "combo model"   "m"     "$SWARM_MODEL"
assert_eq "combo agents"  "4"     "$NUM_AGENTS"
assert_eq "combo idle"    "2"     "$MAX_IDLE"
assert_eq "combo effort"  "low"   "$EFFORT_LEVEL"
assert_eq "combo setup"   "x.sh"  "$SWARM_SETUP"
assert_eq "combo inject"  "false" "$INJECT_GIT_RULES"
assert_eq "combo dash"    "true"  "$OPEN_DASHBOARD"

# ============================================================
echo ""
echo "=== 21. --agents sets AGENTS_CLI_OVERRIDE flag ==="

reset_vars
parse_start_args --agents 5
assert_eq "override flag set" "true" "$AGENTS_CLI_OVERRIDE"

reset_vars
parse_start_args --model m
assert_eq "override flag unset" "false" "$AGENTS_CLI_OVERRIDE"

# ============================================================
echo ""
echo "=== 22. Auth label — credential source labels ==="

# auth_token set → "token"
assert_eq "auth_token → token" \
    "token" \
    "$(resolve_auth_label "" "" "sk-or-key" "" "")"

# auth_token set with auth field → still "token" (takes priority)
assert_eq "auth_token + auth:apikey → token" \
    "token" \
    "$(resolve_auth_label "apikey" "" "sk-or-key" "" "")"

# auth: "oauth" → "oauth"
assert_eq "auth:oauth → oauth" \
    "oauth" \
    "$(resolve_auth_label "oauth" "" "" "" "sk-oat-tok")"

# custom api_key (no auth field) → "key"
assert_eq "custom api_key → key" \
    "key" \
    "$(resolve_auth_label "" "sk-custom" "" "" "")"

# auth: "apikey" with resolved key → "key"
assert_eq "auth:apikey → key" \
    "key" \
    "$(resolve_auth_label "apikey" "" "" "sk-global" "")"

# auth: "apikey" with both host creds → still "key" (OAuth not forwarded)
assert_eq "auth:apikey + host oauth → key" \
    "key" \
    "$(resolve_auth_label "apikey" "" "" "sk-global" "sk-oat-tok")"

# default with both key + OAuth → "auto"
assert_eq "default key+oauth → auto" \
    "auto" \
    "$(resolve_auth_label "" "" "" "sk-global" "sk-oat-tok")"

# default with key only → "key"
assert_eq "default key only → key" \
    "key" \
    "$(resolve_auth_label "" "" "" "sk-global" "")"

# default with OAuth only → "oauth"
assert_eq "default oauth only → oauth" \
    "oauth" \
    "$(resolve_auth_label "" "" "" "" "sk-oat-tok")"

# nothing at all → empty
assert_eq "no creds → empty" \
    "" \
    "$(resolve_auth_label "" "" "" "" "")"

# ============================================================
# check_deps tests
# ============================================================
echo ""
echo "--- check_deps ---"

source "$TESTS_DIR/../lib/check-deps.sh"

# Present tools should pass silently.
out=$(check_deps bash git 2>&1) || true
assert_eq "present deps succeed" "" "$out"

# Missing tool should print error and list the tool name.
out=$(check_deps __no_such_tool__ 2>&1) || true
assert_eq "missing dep mentions tool" "true" \
    "$([[ "$out" == *"__no_such_tool__"* ]] && echo true || echo false)"
assert_eq "missing dep says ERROR" "true" \
    "$([[ "$out" == *"ERROR"* ]] && echo true || echo false)"
assert_eq "missing dep mentions README" "true" \
    "$([[ "$out" == *"README"* ]] && echo true || echo false)"

# Mixed present and missing reports only the missing one.
out=$(check_deps bash __no_such_tool__ git 2>&1) || true
assert_eq "mixed deps lists missing" "true" \
    "$([[ "$out" == *"__no_such_tool__"* ]] && echo true || echo false)"
assert_eq "mixed deps omits present" "false" \
    "$([[ "$out" == *"bash"* ]] && echo true || echo false)"

# ============================================================
# Script-level dependency guard integration tests.
# Build a minimal PATH with only basic utilities so that
# jq, docker, bc, tput are genuinely absent.
# ============================================================
echo ""
echo "--- check_deps integration ---"

FAKE_BIN=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN"' EXIT
for cmd in bash dirname basename cat date git; do
    p=$(command -v "$cmd" 2>/dev/null) && ln -s "$p" "$FAKE_BIN/"
done

# launch.sh --help should exit 0 even without jq/docker.
out=$(PATH="$FAKE_BIN" bash "$TESTS_DIR/../launch.sh" --help 2>&1) \
    && rc=0 || rc=$?
assert_eq "launch --help exits 0 without jq" "0" "$rc"

# dashboard.sh --help should exit 0 even without jq/docker/tput/bc.
out=$(PATH="$FAKE_BIN" bash "$TESTS_DIR/../dashboard.sh" --help 2>&1) \
    && rc=0 || rc=$?
assert_eq "dashboard --help exits 0 without jq" "0" "$rc"

# launch.sh start should fail and mention missing tools.
out=$(PATH="$FAKE_BIN" bash "$TESTS_DIR/../launch.sh" start 2>&1) \
    && rc=0 || rc=$?
assert_eq "launch start exits nonzero without jq" "1" "$rc"
assert_eq "launch start error mentions jq" "true" \
    "$([[ "$out" == *"jq"* ]] && echo true || echo false)"

# dashboard.sh (no args) should fail and mention missing tools.
out=$(PATH="$FAKE_BIN" bash "$TESTS_DIR/../dashboard.sh" 2>&1) \
    && rc=0 || rc=$?
assert_eq "dashboard exits nonzero without jq" "1" "$rc"
assert_eq "dashboard error mentions jq" "true" \
    "$([[ "$out" == *"jq"* ]] && echo true || echo false)"

rm -rf "$FAKE_BIN"
trap 'rm -rf "$TMPDIR"' EXIT

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
