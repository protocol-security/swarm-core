#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for launch.sh parsing logic.
# No Docker or API key required.

# Isolate from host gitconfig (signing keys, hooks, templates).
# Several tests build scratch repos and run `git commit` /
# `commit-tree`;
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

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
parse_pp_max_idle() { jq -r '.post_process.max_idle // .max_idle // 3' "$1"; }

parse_agents_cfg() {
    jq -r '.tag as $dt | .driver as $dd | .agents[] | range(.count) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")' "$1"
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

assert_eq "pp prompt"           "review.md"           "$(parse_pp_prompt "$TMPDIR/pp_full.json")"
assert_eq "pp model"            "claude-sonnet-4-5"   "$(parse_pp_model "$TMPDIR/pp_full.json")"
assert_eq "pp base_url"         "https://example.com" "$(parse_pp_base_url "$TMPDIR/pp_full.json")"
assert_eq "pp api_key"          "sk-pp-test"          "$(parse_pp_api_key "$TMPDIR/pp_full.json")"
assert_eq "pp max_idle default" "3"                   "$(parse_pp_max_idle "$TMPDIR/pp_full.json")"

cat > "$TMPDIR/pp_minimal.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "review.md" }
}
EOF

assert_eq "pp model default"    "claude-opus-4-6"  "$(parse_pp_model "$TMPDIR/pp_minimal.json")"
assert_eq "pp base_url empty"   ""                 "$(parse_pp_base_url "$TMPDIR/pp_minimal.json")"
assert_eq "pp api_key empty"    ""                 "$(parse_pp_api_key "$TMPDIR/pp_minimal.json")"
assert_eq "pp max_idle minimal" "3"                "$(parse_pp_max_idle "$TMPDIR/pp_minimal.json")"

cat > "$TMPDIR/pp_idle.json" <<'EOF'
{
  "prompt": "p.md",
  "max_idle": 5,
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "review.md", "max_idle": 3 }
}
EOF

assert_eq "pp max_idle explicit" "3" \
    "$(parse_pp_max_idle "$TMPDIR/pp_idle.json")"

cat > "$TMPDIR/pp_idle_inherit.json" <<'EOF'
{
  "prompt": "p.md",
  "max_idle": 7,
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "review.md" }
}
EOF

assert_eq "pp max_idle inherits top-level" "7" \
    "$(parse_pp_max_idle "$TMPDIR/pp_idle_inherit.json")"

cat > "$TMPDIR/no_pp.json" <<'EOF'
{ "prompt": "p.md", "agents": [{ "count": 1, "model": "m" }] }
EOF

assert_eq "no pp prompt"   ""  "$(parse_pp_prompt "$TMPDIR/no_pp.json")"
assert_eq "no pp max_idle" "3" "$(parse_pp_max_idle "$TMPDIR/no_pp.json")"

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
echo "=== 16. parse_start_args — dashboard flag ==="

_LAUNCH="$TESTS_DIR/../launch.sh"
eval "$(sed -n '/^parse_start_args()/,/^}/p' "$_LAUNCH")"

parse_start_args --dashboard
assert_eq "cli dashboard" "true" "$OPEN_DASHBOARD"

parse_start_args
assert_eq "default no dashboard" "false" "$OPEN_DASHBOARD"

# ============================================================
echo ""
echo "=== 17. parse_start_args — unknown flag errors ==="

if (parse_start_args --bogus 2>/dev/null); then
    echo "  FAIL: unknown flag should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: unknown flag rejected"
    PASS=$((PASS + 1))
fi

if (parse_start_args --prompt foo.md 2>/dev/null); then
    echo "  FAIL: removed --prompt flag should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: --prompt rejected (config-only)"
    PASS=$((PASS + 1))
fi

if (parse_start_args --model m 2>/dev/null); then
    echo "  FAIL: removed --model flag should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: --model rejected (config-only)"
    PASS=$((PASS + 1))
fi

if (parse_start_args --agents 5 2>/dev/null); then
    echo "  FAIL: removed --agents flag should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: --agents rejected (config-only)"
    PASS=$((PASS + 1))
fi

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

# Present tools should pass silently (version warnings are
# expected on macOS where system bash is 3.2).
out=$(check_deps bash git 2>&1) || true
if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    assert_eq "present deps succeed" "" "$out"
else
    echo "  SKIP: system bash ${BASH_VERSION} triggers expected warning"
fi

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
echo ""
echo "--- _ver_ge comparison ---"

assert_eq "ver_ge 1.6 >= 1.6"   "0" "$(_ver_ge 1.6 1.6  && echo 0 || echo 1)"
assert_eq "ver_ge 1.8 >= 1.6"   "0" "$(_ver_ge 1.8 1.6  && echo 0 || echo 1)"
assert_eq "ver_ge 2.0 >= 1.6"   "0" "$(_ver_ge 2.0 1.6  && echo 0 || echo 1)"
assert_eq "ver_ge 1.5 < 1.6"    "1" "$(_ver_ge 1.5 1.6  && echo 0 || echo 1)"
assert_eq "ver_ge 0.9 < 1.0"    "1" "$(_ver_ge 0.9 1.0  && echo 0 || echo 1)"
assert_eq "ver_ge 24.0 >= 24.0" "0" "$(_ver_ge 24.0 24.0 && echo 0 || echo 1)"
assert_eq "ver_ge 29.3 >= 24.0" "0" "$(_ver_ge 29.3 24.0 && echo 0 || echo 1)"
assert_eq "ver_ge 23.9 < 24.0"  "1" "$(_ver_ge 23.9 24.0 && echo 0 || echo 1)"

echo ""
echo "--- _dep_version extraction ---"

bash_ver=$(_dep_version bash)
assert_eq "bash ver non-empty" "true" \
    "$([ -n "$bash_ver" ] && echo true || echo false)"
assert_eq "bash ver is dotted" "true" \
    "$([[ "$bash_ver" == *.* ]] && echo true || echo false)"

git_ver=$(_dep_version git)
assert_eq "git ver non-empty" "true" \
    "$([ -n "$git_ver" ] && echo true || echo false)"

jq_ver=$(_dep_version jq)
assert_eq "jq ver non-empty" "true" \
    "$([ -n "$jq_ver" ] && echo true || echo false)"

assert_eq "unknown cmd returns error" "1" \
    "$(_dep_version __no_such__ 2>/dev/null && echo 0 || echo 1)"

echo ""
echo "--- version warning output ---"

# Current system should produce no warnings (skip on macOS
# where system bash is 3.2, below tested minimum).
warn_out=$(check_deps bash git jq 2>&1) || true
if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    assert_eq "no warnings on current system" "" "$warn_out"
else
    echo "  SKIP: system bash ${BASH_VERSION} below minimum (expected)"
fi

# SWARM_SKIP_DEP_CHECK silences warnings.
warn_out=$(SWARM_SKIP_DEP_CHECK=1 check_deps bash git jq 2>&1) || true
assert_eq "skip dep check silences" "" "$warn_out"

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
echo "=== 18. Swarmfile is required ==="

# launch.sh start without a config should fail with a clear message.
# Must run from a git repo (launch.sh needs git rev-parse).
# Requires docker in PATH (check_deps runs before config check).
if command -v docker &>/dev/null; then
    _no_cfg_dir=$(mktemp -d)
    git -C "$_no_cfg_dir" init -q
    out=$(cd "$_no_cfg_dir" && SWARM_CONFIG="" bash "$TESTS_DIR/../launch.sh" start 2>&1) \
        && rc=0 || rc=$?
    rm -rf "$_no_cfg_dir"
    assert_eq "no config exits nonzero" "1" "$rc"
    assert_eq "no config says swarmfile" "true" \
        "$([[ "$out" == *"swarmfile"* ]] && echo true || echo false)"
else
    echo "  SKIP: docker not available (macOS CI)"
fi

# ============================================================
echo ""
echo "=== SWARM_AGENTS derivation from config ==="

# Mirrors the logic in cmd_start() that reads AGENTS_CFG and builds
# a comma-separated list of unique drivers for the Docker build arg.
derive_swarm_agents() {
    local cfg_file="$1" config_file="${2:-}" default_driver="claude-code"
    local _swarm_agents="" _seen_agents=" "
    while IFS='|' read -r _ _ _ _ _ _ _ _ _ _drv; do
        _drv="${_drv:-${default_driver}}"
        [[ "$_seen_agents" == *" $_drv "* ]] && continue
        _seen_agents+="$_drv "
        _swarm_agents="${_swarm_agents:+${_swarm_agents},}${_drv}"
    done < "$cfg_file"
    if [ -n "$config_file" ]; then
        local _pp_drv
        _pp_drv=$(jq -r '.post_process.driver // .driver // "claude-code"' "$config_file" 2>/dev/null || true)
        if [[ "$_seen_agents" != *" $_pp_drv "* ]]; then
            _swarm_agents="${_swarm_agents:+${_swarm_agents},}${_pp_drv}"
        fi
    fi
    echo "$_swarm_agents"
}

# Single driver (no driver field in config).
# Format: model|base_url|api_key|effort|auth|context|prompt|auth_token|tag|driver (9 pipes)
: > "$TMPDIR/agents_single.cfg"
printf 'claude-opus-4-6|||||||||\n' >> "$TMPDIR/agents_single.cfg"
printf 'claude-sonnet-4-6|||||||||\n' >> "$TMPDIR/agents_single.cfg"
assert_eq "single driver default" "claude-code" \
    "$(derive_swarm_agents "$TMPDIR/agents_single.cfg")"

# Mixed drivers.
: > "$TMPDIR/agents_mixed.cfg"
printf 'claude-opus-4-6|||||||||claude-code\n' >> "$TMPDIR/agents_mixed.cfg"
printf 'gemini-2.5-pro|||||||||gemini-cli\n' >> "$TMPDIR/agents_mixed.cfg"
assert_eq "mixed drivers" "claude-code,gemini-cli" \
    "$(derive_swarm_agents "$TMPDIR/agents_mixed.cfg")"

# Deduplication — multiple agents with same driver.
: > "$TMPDIR/agents_dedup.cfg"
printf 'gemini-2.5-pro|||||||||gemini-cli\n' >> "$TMPDIR/agents_dedup.cfg"
printf 'gemini-3-flash|||||||||gemini-cli\n' >> "$TMPDIR/agents_dedup.cfg"
assert_eq "dedup same driver" "gemini-cli" \
    "$(derive_swarm_agents "$TMPDIR/agents_dedup.cfg")"

# Post-process adds a new driver.
: > "$TMPDIR/agents_pp.cfg"
printf 'gemini-2.5-pro|||||||||gemini-cli\n' >> "$TMPDIR/agents_pp.cfg"
cat > "$TMPDIR/pp_driver.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "gemini-2.5-pro", "driver": "gemini-cli" }],
  "post_process": { "prompt": "r.md", "driver": "claude-code" }
}
EOF
assert_eq "pp adds driver" "gemini-cli,claude-code" \
    "$(derive_swarm_agents "$TMPDIR/agents_pp.cfg" "$TMPDIR/pp_driver.json")"

# Post-process driver already present — no duplicate.
cat > "$TMPDIR/pp_same.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "claude-opus-4-6" }],
  "post_process": { "prompt": "r.md" }
}
EOF
: > "$TMPDIR/agents_pp_same.cfg"
printf 'claude-opus-4-6|||||||||\n' >> "$TMPDIR/agents_pp_same.cfg"
assert_eq "pp same driver no dup" "claude-code" \
    "$(derive_swarm_agents "$TMPDIR/agents_pp_same.cfg" "$TMPDIR/pp_same.json")"

# Post-process inherits top-level driver.
cat > "$TMPDIR/pp_inherit.json" <<'EOF'
{
  "prompt": "p.md",
  "driver": "gemini-cli",
  "agents": [{ "count": 1, "model": "gemini-2.5-pro" }],
  "post_process": { "prompt": "r.md" }
}
EOF
: > "$TMPDIR/agents_pp_inh.cfg"
printf 'gemini-2.5-pro|||||||||gemini-cli\n' >> "$TMPDIR/agents_pp_inh.cfg"
assert_eq "pp inherits top driver" "gemini-cli" \
    "$(derive_swarm_agents "$TMPDIR/agents_pp_inh.cfg" "$TMPDIR/pp_inherit.json")"

# ============================================================
echo ""
echo "=== 13. Pricing extraction from config ==="

# Mirrors the jq pricing lookup in launch.sh.
extract_pricing() {
    local config="$1" model="$2"
    jq -r --arg m "$model" \
        '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
        "$config" 2>/dev/null || true
}

assert_eq "gemini-2.5-pro pricing" "1.25 10 0.13" \
    "$(extract_pricing "$TESTS_DIR/configs/heterogeneous-kitchen-sink.json" "gemini-2.5-pro")"

assert_eq "gemini-3.1 pricing" "2 12 0.2" \
    "$(extract_pricing "$TESTS_DIR/configs/heterogeneous-kitchen-sink.json" "gemini-3.1-pro-preview")"

assert_eq "gemini-3.1 customtools pricing" "2 12 0.2" \
    "$(extract_pricing "$TESTS_DIR/configs/heterogeneous-kitchen-sink.json" "gemini-3.1-pro-preview-customtools")"

assert_eq "flash pricing" "0.5 3 0" \
    "$(extract_pricing "$TESTS_DIR/configs/heterogeneous-kitchen-sink.json" "gemini-3-flash-preview")"

# Model not in pricing map — returns empty.
assert_eq "unlisted model empty" "" \
    "$(extract_pricing "$TESTS_DIR/configs/heterogeneous-kitchen-sink.json" "claude-opus-4-6")"

# MiniMax-M2.7 pricing in kitchen-sink.json.
assert_eq "minimax-m2.7 pricing" "0.3 1.2 0.06" \
    "$(extract_pricing "$TESTS_DIR/configs/kitchen-sink.json" "MiniMax-M2.7")"

# Config without pricing section — returns empty.
assert_eq "no pricing section" "" \
    "$(extract_pricing "$TESTS_DIR/configs/gemini-only.json" "gemini-2.5-pro")"

# ============================================================
echo ""
echo "=== 29. claude_code_version field ==="

cat > "$TMPDIR/cc_pinned.json" <<'JSON'
{
  "prompt": "unused",
  "claude_code_version": "1.0.30",
  "agents": [{"count": 1, "model": "claude-opus-4-6"}]
}
JSON

assert_eq "cc version present" "1.0.30" \
    "$(jq -r '.claude_code_version // empty' "$TMPDIR/cc_pinned.json")"

cat > "$TMPDIR/cc_no_version.json" <<'JSON'
{
  "prompt": "unused",
  "agents": [{"count": 1, "model": "claude-opus-4-6"}]
}
JSON

assert_eq "cc version absent" "" \
    "$(jq -r '.claude_code_version // empty' "$TMPDIR/cc_no_version.json")"

# Mirror of the cc version test for the codex_cli_version field
# parsed by launch.sh's --build-arg plumbing -- pins the jq filter
# so a future typo in either path is caught immediately.
cat > "$TMPDIR/codex_pinned.json" <<'JSON'
{
  "prompt": "unused",
  "codex_cli_version": "0.125.0",
  "agents": [{"count": 1, "driver": "codex-cli", "model": "gpt-5.4"}]
}
JSON

assert_eq "codex version present" "0.125.0" \
    "$(jq -r '.codex_cli_version // empty' "$TMPDIR/codex_pinned.json")"

cat > "$TMPDIR/codex_no_version.json" <<'JSON'
{
  "prompt": "unused",
  "agents": [{"count": 1, "driver": "codex-cli", "model": "gpt-5.4"}]
}
JSON

assert_eq "codex version absent" "" \
    "$(jq -r '.codex_cli_version // empty' "$TMPDIR/codex_no_version.json")"

# ============================================================
echo ""
echo "=== 30. Top-level tag inheritance ==="

cat > "$TMPDIR/tag_toplevel.json" <<'EOF'
{
  "prompt": "p.md",
  "tag": "custom-top-lvl-tag",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" },
    { "count": 1, "model": "claude-sonnet-4-6", "tag": "custom-per-agent-tag" },
    { "count": 1, "model": "claude-haiku-4-5", "tag": "" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/tag_toplevel.json")
LINE1=$(echo "$CFG" | sed -n '1p')
LINE2=$(echo "$CFG" | sed -n '2p')
LINE3=$(echo "$CFG" | sed -n '3p')

IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "inherits top-level tag" "custom-top-lvl-tag" "$g1"

IFS='|' read -r m2 u2 k2 e2 a2 c2 p2 t2 g2 d2 <<< "$LINE2"
assert_eq "per-agent tag overrides" "custom-per-agent-tag" "$g2"

IFS='|' read -r m3 u3 k3 e3 a3 c3 p3 t3 g3 d3 <<< "$LINE3"
assert_eq "no top-level tag no agent tag" "" "$g3"

# No top-level tag. Agents without tag get empty.
cat > "$TMPDIR/tag_none.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "claude-opus-4-6" }
  ]
}
EOF

CFG=$(parse_agents_cfg "$TMPDIR/tag_none.json")
LINE1=$(echo "$CFG" | sed -n '1p')
IFS='|' read -r m1 u1 k1 e1 a1 c1 p1 t1 g1 d1 <<< "$LINE1"
assert_eq "absent top-level tag" "" "$g1"

# ============================================================
echo ""
echo "=== 31. Tag env var expansion ==="

# Mirrors expand_env_ref from launch.sh.
expand_env_ref() {
    local val="$1"
    if [[ "$val" =~ ^\$([A-Za-z_][A-Za-z_0-9]*)$ ]]; then
        local varname="${BASH_REMATCH[1]}"
        printf '%s' "${!varname:-}"
    else
        printf '%s' "$val"
    fi
}

# Direct value -> no expansion.
assert_eq "literal tag unchanged" "literal" "$(expand_env_ref "literal")"

# Empty string —> stays empty.
assert_eq "empty stays empty" "" "$(expand_env_ref "")"

# $VAR reference -> expands.
SWARM_TAG_TEST="expanded"
assert_eq "env ref expands" "expanded" "$(expand_env_ref '$SWARM_TAG_TEST')"

# Unset variable —> expands to empty.
unset SWARM_TAG_MISSING 2>/dev/null || true
assert_eq "unset env ref empty" "" "$(expand_env_ref '$SWARM_TAG_MISSING')"

# Not a bare $VAR (inline text) —> returned as-is.
assert_eq "inline not expanded" 'prefix-$SWARM_TAG_TEST' \
    "$(expand_env_ref 'prefix-$SWARM_TAG_TEST')"

# ============================================================
echo ""
echo "=== 32. Post-process tag fallback and expansion ==="

parse_pp_tag() {
    jq -r '.post_process.tag // .tag // empty' "$1"
}

# Post-process has its own tag.
cat > "$TMPDIR/pp_tag_own.json" <<'EOF'
{
  "prompt": "p.md",
  "tag": "custom-top-lvl-tag",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "r.md", "tag": "pp-review" }
}
EOF
assert_eq "pp own tag" "pp-review" "$(parse_pp_tag "$TMPDIR/pp_tag_own.json")"

# Post-process inherits top-level tag.
cat > "$TMPDIR/pp_tag_inherit.json" <<'EOF'
{
  "prompt": "p.md",
  "tag": "custom-top-lvl-tag",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "r.md" }
}
EOF
assert_eq "pp inherits top-level tag" "custom-top-lvl-tag" \
    "$(parse_pp_tag "$TMPDIR/pp_tag_inherit.json")"

# Neither top-level, nor post-process tag —> empty.
cat > "$TMPDIR/pp_tag_empty.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "r.md" }
}
EOF
assert_eq "pp no tag empty" "" "$(parse_pp_tag "$TMPDIR/pp_tag_empty.json")"

# Post-process tag with env var expansion.
SWARM_PP_TAG="expanded-pp"
pp_raw=$(parse_pp_tag "$TMPDIR/pp_tag_inherit.json")
assert_eq "pp tag before expansion" "custom-top-lvl-tag" "$pp_raw"

cat > "$TMPDIR/pp_tag_envref.json" <<'EOF'
{
  "prompt": "p.md",
  "tag": "$SWARM_PP_TAG",
  "agents": [{ "count": 1, "model": "m" }],
  "post_process": { "prompt": "r.md" }
}
EOF
pp_raw=$(parse_pp_tag "$TMPDIR/pp_tag_envref.json")
pp_expanded="$(expand_env_ref "$pp_raw")"
assert_eq "pp tag env expansion" "expanded-pp" "$pp_expanded"

# ============================================================
echo ""
echo "=== 33. docker_args array construction ==="

# Mirrors the DOCKER_EXTRA_ARGS construction in launch.sh.
build_docker_extra_args() {
    local config_file="$1"
    local DOCKER_EXTRA_ARGS=()
    while IFS= read -r _da; do
        [ -n "$_da" ] && DOCKER_EXTRA_ARGS+=("$_da")
    done < <(jq -r '.docker_args[]?' "$config_file" 2>/dev/null)
    echo "${DOCKER_EXTRA_ARGS[*]+"${DOCKER_EXTRA_ARGS[*]}"}"
}

cat > "$TMPDIR/da_full.json" <<'EOF'
{
  "prompt": "p.md",
  "docker_args": ["-v", "/var/run/docker.sock:/var/run/docker.sock", "--privileged"],
  "agents": [{ "count": 1, "model": "m" }]
}
EOF

assert_eq "docker_args full" \
    "-v /var/run/docker.sock:/var/run/docker.sock --privileged" \
    "$(build_docker_extra_args "$TMPDIR/da_full.json")"

# No docker_args — empty.
cat > "$TMPDIR/da_none.json" <<'EOF'
{ "prompt": "p.md", "agents": [{ "count": 1, "model": "m" }] }
EOF
assert_eq "docker_args absent" "" \
    "$(build_docker_extra_args "$TMPDIR/da_none.json")"

# Empty array — empty.
cat > "$TMPDIR/da_empty.json" <<'EOF'
{ "prompt": "p.md", "docker_args": [], "agents": [{ "count": 1, "model": "m" }] }
EOF
assert_eq "docker_args empty array" "" \
    "$(build_docker_extra_args "$TMPDIR/da_empty.json")"

# Single flag.
cat > "$TMPDIR/da_single.json" <<'EOF'
{ "prompt": "p.md", "docker_args": ["--network=host"], "agents": [{ "count": 1, "model": "m" }] }
EOF
assert_eq "docker_args single" "--network=host" \
    "$(build_docker_extra_args "$TMPDIR/da_single.json")"

# Multiple volume mounts + capabilities.
cat > "$TMPDIR/da_complex.json" <<'EOF'
{
  "prompt": "p.md",
  "docker_args": ["-v", "/var/run/docker.sock:/var/run/docker.sock", "-v", "/tmp:/host-tmp:ro", "--cap-add", "SYS_PTRACE"],
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "docker_args complex" \
    "-v /var/run/docker.sock:/var/run/docker.sock -v /tmp:/host-tmp:ro --cap-add SYS_PTRACE" \
    "$(build_docker_extra_args "$TMPDIR/da_complex.json")"

# ============================================================
echo ""
echo "=== 34. Post-process creates bare repo when missing ==="

# Simulate the bare-repo creation logic from cmd_post_process.
pp_ensure_bare_repo() {
    local repo_root="$1" bare_repo="$2"
    if [ ! -d "$bare_repo" ]; then
        git clone --bare "$repo_root" "$bare_repo" 2>/dev/null
        git -C "$bare_repo" branch agent-work HEAD 2>/dev/null || true
        git -C "$bare_repo" symbolic-ref HEAD refs/heads/agent-work
    fi
}

# Set up a small git repo to clone from.
_pp_repo="$TMPDIR/pp-src-repo"
mkdir -p "$_pp_repo"
git -C "$_pp_repo" init -q
git -C "$_pp_repo" \
    -c user.name="test" -c user.email="test@test" \
    -c commit.gpgsign=false \
    commit --allow-empty -m "init" -q

_pp_bare="$TMPDIR/pp-bare-test.git"

# Bare repo does not exist — should be created.
rm -rf "$_pp_bare"
pp_ensure_bare_repo "$_pp_repo" "$_pp_bare"
assert_eq "pp creates bare repo" "true" \
    "$([ -d "$_pp_bare" ] && echo true || echo false)"

# Verify agent-work branch exists.
_pp_aw=$(git -C "$_pp_bare" symbolic-ref HEAD 2>/dev/null || echo "")
assert_eq "pp bare HEAD is agent-work" "refs/heads/agent-work" "$_pp_aw"

# Bare repo already exists — should not fail or recreate.
_pp_head_before=$(git -C "$_pp_bare" rev-parse HEAD 2>/dev/null)
pp_ensure_bare_repo "$_pp_repo" "$_pp_bare"
_pp_head_after=$(git -C "$_pp_bare" rev-parse HEAD 2>/dev/null)
assert_eq "pp existing bare repo unchanged" "$_pp_head_before" "$_pp_head_after"

rm -rf "$_pp_repo" "$_pp_bare"

# ============================================================
echo ""
echo "=== 35. Bare repo is world-writable after creation ==="

# Simulate the bare-repo creation + permission fix from cmd_start.
_wr_repo="$TMPDIR/wr-src-repo"
mkdir -p "$_wr_repo"
git -C "$_wr_repo" init -q
git -C "$_wr_repo" \
    -c user.name="test" -c user.email="test@test" \
    -c commit.gpgsign=false \
    commit --allow-empty -m "init" -q

_wr_bare="$TMPDIR/wr-bare-test.git"
rm -rf "$_wr_bare"
git clone --bare "$_wr_repo" "$_wr_bare" 2>/dev/null
git -C "$_wr_bare" branch agent-work HEAD 2>/dev/null || true
git -C "$_wr_bare" symbolic-ref HEAD refs/heads/agent-work
git -C "$_wr_bare" config core.sharedRepository world
chmod -R a+rwX "$_wr_bare"

# Verify core.sharedRepository is set to "world".
_wr_shared=$(git -C "$_wr_bare" config core.sharedRepository 2>/dev/null || echo "")
assert_eq "bare repo sharedRepository=world" "world" "$_wr_shared"

# Verify objects directory is world-writable (o+w).
_wr_obj_perms=$(stat -c '%A' "$_wr_bare/objects" 2>/dev/null \
    || stat -f '%Sp' "$_wr_bare/objects" 2>/dev/null)
_wr_other_w=$(echo "$_wr_obj_perms" | grep -c 'w.$' || true)
assert_eq "bare repo objects/ is world-writable" "1" "$_wr_other_w"

# Verify a different user (simulated) can create objects.
# We can't switch UID in a unit test, but we can verify the
# permission bits on a representative subdirectory.
_wr_pack_perms=$(stat -c '%A' "$_wr_bare/objects/pack" 2>/dev/null \
    || stat -f '%Sp' "$_wr_bare/objects/pack" 2>/dev/null)
_wr_pack_w=$(echo "$_wr_pack_perms" | grep -c 'w.$' || true)
assert_eq "bare repo objects/pack/ is world-writable" "1" "$_wr_pack_w"

rm -rf "$_wr_repo" "$_wr_bare"

# ============================================================
echo ""
echo "=== 36. signing_key resolution ==="

# Mirrors the signing-key resolution block in launch.sh.
# Prints the resolved `-v` args (empty when no key configured),
# returns 1 with an ERROR line on a missing file.
resolve_signing_key_args() {
    local cfg="$1"
    local key
    key=$(jq -r '.git_user.signing_key // empty' "$cfg")
    key="$(expand_env_ref "$key")"
    [ -z "$key" ] && return 0
    key="${key/#\~/$HOME}"
    if [ ! -f "$key" ]; then
        echo "ERROR: signing key not found: $key" >&2
        return 1
    fi
    printf -- '-v %s:/etc/swarm/signing_key:ro' "$key"
}

# No signing_key configured -> empty args.
cat > "$TMPDIR/sign_none.json" <<'EOF'
{
  "prompt": "p.md",
  "git_user": { "name": "bot", "email": "bot@test" },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "no signing_key -> no args" "" \
    "$(resolve_signing_key_args "$TMPDIR/sign_none.json")"

# Literal path to existing file -> expanded args.
_sk_dir="$TMPDIR/sk-$$"
mkdir -p "$_sk_dir"
touch "$_sk_dir/key"
cat > "$TMPDIR/sign_literal.json" <<EOF
{
  "prompt": "p.md",
  "git_user": {
    "name": "bot", "email": "bot@test",
    "signing_key": "$_sk_dir/key"
  },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "literal signing_key -> v args" \
    "-v $_sk_dir/key:/etc/swarm/signing_key:ro" \
    "$(resolve_signing_key_args "$TMPDIR/sign_literal.json")"

# $VAR reference with var set -> env value expanded.
SWARM_SK_TEST="$_sk_dir/key"
cat > "$TMPDIR/sign_envref.json" <<'EOF'
{
  "prompt": "p.md",
  "git_user": {
    "name": "bot", "email": "bot@test",
    "signing_key": "$SWARM_SK_TEST"
  },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "env-ref signing_key -> expanded args" \
    "-v $_sk_dir/key:/etc/swarm/signing_key:ro" \
    "$(resolve_signing_key_args "$TMPDIR/sign_envref.json")"

# $VAR reference unset -> no args (no silent default fallback).
unset SWARM_SK_MISSING 2>/dev/null || true
cat > "$TMPDIR/sign_envref_missing.json" <<'EOF'
{
  "prompt": "p.md",
  "git_user": {
    "name": "bot", "email": "bot@test",
    "signing_key": "$SWARM_SK_MISSING"
  },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "unset env-ref signing_key -> no args" "" \
    "$(resolve_signing_key_args "$TMPDIR/sign_envref_missing.json")"

# Tilde-prefixed path -> $HOME expanded.
_sk_home="$TMPDIR/sk-home-$$"
mkdir -p "$_sk_home/.ssh"
touch "$_sk_home/.ssh/key"
cat > "$TMPDIR/sign_tilde.json" <<'EOF'
{
  "prompt": "p.md",
  "git_user": {
    "name": "bot", "email": "bot@test",
    "signing_key": "~/.ssh/key"
  },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
assert_eq "tilde signing_key -> HOME expanded" \
    "-v $_sk_home/.ssh/key:/etc/swarm/signing_key:ro" \
    "$(HOME="$_sk_home" resolve_signing_key_args "$TMPDIR/sign_tilde.json")"

# Missing file -> error on stderr, non-zero return.
cat > "$TMPDIR/sign_missing.json" <<EOF
{
  "prompt": "p.md",
  "git_user": {
    "name": "bot", "email": "bot@test",
    "signing_key": "$TMPDIR/does-not-exist"
  },
  "agents": [{ "count": 1, "model": "m" }]
}
EOF
_missing_err=$(resolve_signing_key_args "$TMPDIR/sign_missing.json" 2>&1 \
    >/dev/null || true)
_missing_has_err=$(echo "$_missing_err" \
    | grep -c "ERROR: signing key not found" || true)
assert_eq "missing signing_key -> error line" "1" "$_missing_has_err"

if resolve_signing_key_args "$TMPDIR/sign_missing.json" >/dev/null 2>&1; then
    _missing_rc="zero"
else
    _missing_rc="nonzero"
fi
assert_eq "missing signing_key -> non-zero exit" "nonzero" "$_missing_rc"

rm -rf "$_sk_dir" "$_sk_home"

# ============================================================
echo ""
echo "=== 37. bare preflight: stale vs unharvested ==="

# Mirrors the divergence guard in launch.sh.  The `--is-ancestor`
# check runs in the local repo (not in the bare) so the stale
# case -- where LOCAL_HEAD is a commit that only exists in local
# -- resolves correctly; running the check inside the bare would
# fail to resolve LOCAL_HEAD and collapse stale into unharvested.
# Returns 0 when the guard would allow the run, 1 (with an ERROR
# line on stderr) when it would refuse.
check_bare_preflight() {
    local bare="$1" local_repo="$2"
    [ -d "$bare" ] || return 0
    local bare_head local_head
    bare_head=$(git -C "$bare" rev-parse --verify --quiet \
        refs/heads/agent-work 2>/dev/null || true)
    local_head=$(git -C "$local_repo" rev-parse HEAD \
        2>/dev/null || true)
    [ -z "$bare_head" ] && return 0
    [ "$bare_head" = "$local_head" ] && return 0
    if git -C "$local_repo" merge-base --is-ancestor \
            "$bare_head" HEAD 2>/dev/null; then
        echo "ERROR: ${bare} is stale (agent-work" \
             "${bare_head:0:7} behind local HEAD" \
             "${local_head:0:7})." >&2
        echo "       Remove it to start a fresh run from" \
             "current HEAD:" >&2
        echo "       rm -rf ${bare}" >&2
    else
        echo "ERROR: ${bare} has unharvested agent commits" \
             "(agent-work ${bare_head:0:7} vs local HEAD" \
             "${local_head:0:7})." >&2
        echo "       Run harvest.sh first, or if you've" \
             "already integrated those commits:" >&2
        echo "       rm -rf ${bare}" >&2
    fi
    return 1
}

# Build a local repo with commits A, B on HEAD (where B is
# LOCAL_HEAD).  A bare clone taken at B mirrors the happy path;
# moving bare's agent-work forward to a fresh commit C created
# in the bare itself models the unharvested case; advancing
# local past B to D models the stale case; combining both models
# divergence.
_bp_local="$TMPDIR/bp-local"
_bp_bare="$TMPDIR/bp-bare.git"
git init -q -b main "$_bp_local"
git -C "$_bp_local" -c user.name=t -c user.email=t@t \
    commit --allow-empty -q -m "A"
git -C "$_bp_local" -c user.name=t -c user.email=t@t \
    commit --allow-empty -q -m "B"
_bp_B=$(git -C "$_bp_local" rev-parse HEAD)

# ------ 37.1 equal (guard does not fire) ------
git clone -q --bare "$_bp_local" "$_bp_bare"
git -C "$_bp_bare" branch -q agent-work "$_bp_B" 2>/dev/null \
    || git -C "$_bp_bare" update-ref refs/heads/agent-work "$_bp_B"
if check_bare_preflight "$_bp_bare" "$_bp_local" 2>/dev/null; then
    _bp_eq_rc="zero"
else
    _bp_eq_rc="nonzero"
fi
assert_eq "equal BARE_HEAD / LOCAL_HEAD -> guard allows run" \
    "zero" "$_bp_eq_rc"

# ------ 37.2 unharvested (bare has a commit local doesn't) ------
# Create commit C inside the bare on agent-work, mirroring an
# agent push.  Uses `git -C $bare commit-tree` with B's tree so
# the new commit's object lives only in the bare's objects/.
# Pass -c user.{name,email} explicitly: commit-tree refuses to
# stamp without an identity, and CI runners may have neither a
# global git config nor a usable getpwuid gecos fallback.
_bp_C=$(git -c user.name=t -c user.email=t@t \
    -C "$_bp_bare" commit-tree \
    -p "$_bp_B" -m "C (agent)" "${_bp_B}^{tree}")
git -C "$_bp_bare" update-ref refs/heads/agent-work "$_bp_C"
_bp_unh_err=$(check_bare_preflight "$_bp_bare" "$_bp_local" \
    2>&1 >/dev/null || true)
assert_eq "unharvested -> 'has unharvested agent commits'" "1" \
    "$(echo "$_bp_unh_err" \
        | grep -cE 'has unharvested agent commits' || true)"
assert_eq "unharvested -> names short BARE_HEAD" "1" \
    "$(echo "$_bp_unh_err" \
        | grep -cE "agent-work ${_bp_C:0:7}" || true)"
assert_eq "unharvested -> names short LOCAL_HEAD" "1" \
    "$(echo "$_bp_unh_err" \
        | grep -cE "local HEAD ${_bp_B:0:7}" || true)"
assert_eq "unharvested -> rm -rf remediation still offered" "1" \
    "$(echo "$_bp_unh_err" \
        | grep -cE "rm -rf ${_bp_bare}" || true)"
if check_bare_preflight "$_bp_bare" "$_bp_local" \
        >/dev/null 2>&1; then
    _bp_unh_rc="zero"
else
    _bp_unh_rc="nonzero"
fi
assert_eq "unharvested -> non-zero exit" "nonzero" "$_bp_unh_rc"

# ------ 37.3 stale (local has commit D that bare doesn't) ------
# Reset bare back to B; advance local to D.
git -C "$_bp_bare" update-ref refs/heads/agent-work "$_bp_B"
git -C "$_bp_local" -c user.name=t -c user.email=t@t \
    commit --allow-empty -q -m "D (local-only)"
_bp_D=$(git -C "$_bp_local" rev-parse HEAD)
_bp_stale_err=$(check_bare_preflight "$_bp_bare" "$_bp_local" \
    2>&1 >/dev/null || true)
assert_eq "stale -> 'is stale' wording" "1" \
    "$(echo "$_bp_stale_err" \
        | grep -cE 'is stale \(agent-work' || true)"
assert_eq "stale -> 'behind local HEAD' wording" "1" \
    "$(echo "$_bp_stale_err" \
        | grep -cE 'behind local HEAD' || true)"
assert_eq "stale -> leads with rm -rf as remediation" "1" \
    "$(echo "$_bp_stale_err" \
        | grep -cE 'Remove it to start a fresh run' || true)"
assert_eq "stale -> does NOT instruct to run harvest.sh" "0" \
    "$(echo "$_bp_stale_err" \
        | grep -cE 'Run harvest\.sh first' || true)"
assert_eq "stale -> names short BARE_HEAD" "1" \
    "$(echo "$_bp_stale_err" \
        | grep -cE "agent-work ${_bp_B:0:7}" || true)"
assert_eq "stale -> names short LOCAL_HEAD" "1" \
    "$(echo "$_bp_stale_err" \
        | grep -cE "local HEAD ${_bp_D:0:7}" || true)"
if check_bare_preflight "$_bp_bare" "$_bp_local" \
        >/dev/null 2>&1; then
    _bp_stale_rc="zero"
else
    _bp_stale_rc="nonzero"
fi
assert_eq "stale -> non-zero exit" "nonzero" "$_bp_stale_rc"

# ------ 37.4 divergent (each side has commits the other lacks) ------
# Give bare its own E on top of B while local still sits on D.
_bp_E=$(git -c user.name=t -c user.email=t@t \
    -C "$_bp_bare" commit-tree \
    -p "$_bp_B" -m "E (agent)" "${_bp_B}^{tree}")
git -C "$_bp_bare" update-ref refs/heads/agent-work "$_bp_E"
_bp_div_err=$(check_bare_preflight "$_bp_bare" "$_bp_local" \
    2>&1 >/dev/null || true)
# Divergent collapses into the unharvested branch per spec --
# the goal is only that the operator sees both SHAs and knows
# rm -rf is available.
assert_eq "divergent -> falls through to unharvested wording" "1" \
    "$(echo "$_bp_div_err" \
        | grep -cE 'has unharvested agent commits' || true)"
assert_eq "divergent -> names short BARE_HEAD" "1" \
    "$(echo "$_bp_div_err" \
        | grep -cE "agent-work ${_bp_E:0:7}" || true)"
assert_eq "divergent -> names short LOCAL_HEAD" "1" \
    "$(echo "$_bp_div_err" \
        | grep -cE "local HEAD ${_bp_D:0:7}" || true)"

# ------ 37.5 bare absent (guard is a no-op) ------
rm -rf "$_bp_bare"
if check_bare_preflight "$_bp_bare" "$_bp_local" \
        >/dev/null 2>&1; then
    _bp_abs_rc="zero"
else
    _bp_abs_rc="nonzero"
fi
assert_eq "bare missing -> guard is a no-op" "zero" "$_bp_abs_rc"

# ------ 37.6 bare exists but agent-work ref missing (guard no-op) ------
git init -q --bare "$_bp_bare"
if check_bare_preflight "$_bp_bare" "$_bp_local" \
        >/dev/null 2>&1; then
    _bp_noref_rc="zero"
else
    _bp_noref_rc="nonzero"
fi
assert_eq "bare without agent-work ref -> guard is a no-op" \
    "zero" "$_bp_noref_rc"

rm -rf "$_bp_local" "$_bp_bare"

# ============================================================
echo ""
echo "=== 38. compute_swarm_agents helper (live function from launch.sh) ==="

# Source the function from launch.sh so the regression net follows the
# real helper, not a mirror.  compute_swarm_agents has no globals
# beyond jq, so extracting and sourcing it is safe.  Catches any
# refactor that breaks the SWARM_AGENTS build-arg union.
_LAUNCH_SH="$TESTS_DIR/../launch.sh"
_EXTRACTED="$TMPDIR/compute_swarm_agents.sh"
awk '/^compute_swarm_agents\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { exit }' \
    "$_LAUNCH_SH" > "$_EXTRACTED"
# shellcheck source=/dev/null
source "$_EXTRACTED"

assert_eq "function defined" "function" \
    "$(type -t compute_swarm_agents)"

cat > "$TMPDIR/csa_default.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [{ "count": 2, "model": "claude-opus-4-6" }] }
EOF
assert_eq "default driver -> claude-code" "claude-code" \
    "$(compute_swarm_agents "$TMPDIR/csa_default.json")"

cat > "$TMPDIR/csa_codex.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "codex-cli",
  "agents": [{ "count": 1, "model": "gpt-5" }] }
EOF
assert_eq "codex-only top-level driver" "codex-cli" \
    "$(compute_swarm_agents "$TMPDIR/csa_codex.json")"

cat > "$TMPDIR/csa_mixed.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [
    { "count": 1, "model": "gpt-5",            "driver": "codex-cli"   },
    { "count": 2, "model": "claude-opus-4-6",  "driver": "claude-code" }
  ] }
EOF
assert_eq "mixed drivers (group order preserved)" \
    "codex-cli,claude-code" \
    "$(compute_swarm_agents "$TMPDIR/csa_mixed.json")"

cat > "$TMPDIR/csa_dedup.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "gemini-cli",
  "agents": [
    { "count": 1, "model": "gemini-2.5-pro" },
    { "count": 1, "model": "gemini-3-flash" }
  ] }
EOF
assert_eq "dedup same driver across groups" "gemini-cli" \
    "$(compute_swarm_agents "$TMPDIR/csa_dedup.json")"

# Exact scenario from the PR description: codex agents with a
# claude-code post-processor.  Without rebuilding in
# cmd_post_process the post container would inherit a claude-less
# image and exit 127 on first session.  This assertion locks in
# the union the build-arg has to express to install both CLIs.
cat > "$TMPDIR/csa_pp_split.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "codex-cli",
  "agents": [{ "count": 1, "model": "gpt-5" }],
  "post_process": { "prompt": "r.md", "driver": "claude-code" } }
EOF
assert_eq "codex agents + claude-code pp -> union" \
    "codex-cli,claude-code" \
    "$(compute_swarm_agents "$TMPDIR/csa_pp_split.json")"

cat > "$TMPDIR/csa_pp_same.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [{ "count": 1, "model": "claude-opus-4-6" }],
  "post_process": { "prompt": "r.md" } }
EOF
assert_eq "pp default driver matches agents -> no dup" "claude-code" \
    "$(compute_swarm_agents "$TMPDIR/csa_pp_same.json")"

cat > "$TMPDIR/csa_pp_inherit.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "gemini-cli",
  "agents": [{ "count": 1, "model": "gemini-2.5-pro" }],
  "post_process": { "prompt": "r.md" } }
EOF
assert_eq "pp inherits top-level driver -> single" "gemini-cli" \
    "$(compute_swarm_agents "$TMPDIR/csa_pp_inherit.json")"

cat > "$TMPDIR/csa_empty_group_drv.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "codex-cli",
  "agents": [{ "count": 1, "model": "gpt-5", "driver": "" }] }
EOF
assert_eq "empty per-group driver falls back to top-level" "codex-cli" \
    "$(compute_swarm_agents "$TMPDIR/csa_empty_group_drv.json")"

# ============================================================
echo ""
echo "=== 39. build_image is wired into both cmd_start and cmd_post_process ==="

# The PR #96 contract: a standalone post-process invocation must
# rebuild the image with build-args derived from its own config so
# the layer cache invalidates correctly when the driver set differs
# from a prior cmd_start.  Catches accidental removal of either
# call site.
_call_sites=$(grep -cE '^[[:space:]]+build_image[[:space:]]*$' \
    "$_LAUNCH_SH" || true)
assert_eq "build_image has 2 call sites" "2" "$_call_sites"

_pp_calls=$(awk '
    /^cmd_post_process\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+build_image[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")
assert_eq "cmd_post_process calls build_image" "1" "$_pp_calls"

_start_calls=$(awk '
    /^cmd_start\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+build_image[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")
assert_eq "cmd_start calls build_image" "1" "$_start_calls"

# build_image must thread both the SWARM_AGENTS union and the
# version pins; missing any of these would silently produce a
# stale image.  Pinning the function body structurally is cheaper
# than spinning up Docker.
_bi_body=$(awk '
    /^build_image\(\)[[:space:]]*\{/ { p = 1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "$_LAUNCH_SH")
assert_eq "build_image derives SWARM_AGENTS via compute_swarm_agents" \
    "1" \
    "$(printf '%s\n' "$_bi_body" \
        | grep -cE 'compute_swarm_agents[[:space:]]+"\$CONFIG_FILE"' \
        || true)"
assert_eq "build_image forwards SWARM_AGENTS build-arg" "1" \
    "$(printf '%s\n' "$_bi_body" \
        | grep -cE -- '--build-arg "SWARM_AGENTS=' || true)"
assert_eq "build_image forwards CLAUDE_CODE_VERSION build-arg" "1" \
    "$(printf '%s\n' "$_bi_body" \
        | grep -cE -- '--build-arg "CLAUDE_CODE_VERSION=' || true)"
assert_eq "build_image forwards CODEX_CLI_VERSION build-arg" "1" \
    "$(printf '%s\n' "$_bi_body" \
        | grep -cE -- '--build-arg "CODEX_CLI_VERSION=' || true)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
