#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# Unit tests for launch.sh parsing logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/project.sh
source "$TESTS_DIR/../lib/project.sh"

# The fake docker CLIs below hand "docker volume" to this script, which
# keeps each volume's labels in a file, so launch.sh can create and
# check workspace volumes.  FAKE_VOLUME_FAIL=create makes create fail;
# FAKE_VOLUME_FAIL=labels makes inspect show the labels with another
# nonce, as for a volume of that name another run made;
# FAKE_VOLUME_FAIL=exists makes every name taken; FAKE_VOLUME_FAIL=error
# makes inspect fail as when the daemon is gone.
FAKE_DOCKER_VOLUME="$TMPDIR/fake-docker-volume"
FAKE_DOCKER_VOLUME_DIR="$TMPDIR/fake-volumes"
export FAKE_DOCKER_VOLUME FAKE_DOCKER_VOLUME_DIR
mkdir -p "$FAKE_DOCKER_VOLUME_DIR"
cat > "$FAKE_DOCKER_VOLUME" <<'EOF'
#!/bin/bash
d="$FAKE_DOCKER_VOLUME_DIR"
shift
case "$1" in
    inspect)
        shift
        fmt=""
        if [ "$1" = -f ]; then fmt="$2"; shift 2; fi
        case "${FAKE_VOLUME_FAIL:-}" in
            error)
                echo "Cannot connect to the Docker daemon" >&2
                exit 1 ;;
            exists)
                [ -n "$fmt" ] || { echo "[]"; exit 0; } ;;
        esac
        if [ ! -f "$d/$1" ]; then
            echo "Error response from daemon: get $1: no such volume" >&2
            exit 1
        fi
        if [ "${FAKE_VOLUME_FAIL:-}" = labels ]; then
            jq -c '.["swarm-core.nonce"] = "other"' "$d/$1"
        elif [ -n "$fmt" ]; then
            cat "$d/$1"
        else
            echo "[]"
        fi ;;
    create)
        shift
        [ "${FAKE_VOLUME_FAIL:-}" = create ] && exit 1
        labels='{}'
        while [ $# -gt 1 ]; do
            if [ "$1" = --label ]; then
                labels=$(printf '%s' "$labels" | jq -c --arg k "${2%%=*}" \
                    --arg v "${2#*=}" '.[$k] = $v')
                shift 2
                continue
            fi
            shift
        done
        printf '%s\n' "$labels" > "$d/$1"
        echo "$1" ;;
esac
exit 0
EOF
chmod +x "$FAKE_DOCKER_VOLUME"

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
state_model_summary_for_test() {
    jq -r \
        '(.prompt // "") as $dp |
        ($dp | split("/") | .[-1] // "" | rtrimstr(".md")) as $dp_stem |
        [.agents[] | (.count // 0) as $count | select($count > 0) |
          "\($count)x \(.model | split("/") | .[-1])" +
          (if .context == "none" then " ctx:bare"
           elif .context == "slim" then " ctx:slim"
           else "" end) +
          (if .prompt and .prompt != $dp then
            ":" + (.prompt | split("/") | .[-1] | rtrimstr(".md") |
              if startswith($dp_stem + "-")
              then .[$dp_stem | length + 1:]
              else .
              end)
           else "" end)] | join(", ")' "$1"
}
parse_num_agents() {
    jq '[.agents[]? | (.count // 0)] | add // 0' "$1"
}

parse_agents_cfg() {
    jq -r '.tag as $dt | .driver as $dd |
        .agents[] | range(.count // 0) as $i |
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
echo "=== 0. Project ID sanitization ==="

assert_eq "swarm-core project unchanged" \
    "swarm-core" "$(swarm_project_id "swarm-core")"
assert_eq "legacy checkout project unchanged" \
    "claude-swarm" "$(swarm_project_id "claude-swarm")"
assert_eq "uppercase project lowercased" \
    "leanmultisig-swarm" "$(swarm_project_id "leanMultisig-swarm")"
assert_eq "spaces collapse to separator" \
    "my-repo" "$(swarm_project_id "My Repo!")"
assert_eq "leading/trailing separators trimmed" \
    "repo" "$(swarm_project_id "_Repo.")"
assert_eq "empty/all separators fallback" \
    "swarm" "$(swarm_project_id "---")"
# Docker names are ASCII; a UTF-8 locale must not let other letters in.
# "$BASH" runs the checks in the shell running this file: Bash 3.2
# ranges follow the locale, Bash 5 ranges are ASCII by default.
for _loc in en_US.UTF-8 C.UTF-8; do
    assert_eq "non-ASCII letters become separators under ${_loc}" \
        "caf-repo" \
        "$(LC_ALL="$_loc" "$BASH" -c 'source "$1"; swarm_project_id "$2"' \
            _ "$TESTS_DIR/../lib/project.sh" "Café Repo" 2>/dev/null)"
    assert_eq "an all non-ASCII name falls back under ${_loc}" "swarm" \
        "$(LC_ALL="$_loc" "$BASH" -c 'source "$1"; swarm_project_id "$2"' \
            _ "$TESTS_DIR/../lib/project.sh" "éàü" 2>/dev/null)"
    assert_eq "SWARM_PROJECT with a non-ASCII letter is refused (${_loc})" \
        "1" \
        "$(LC_ALL="$_loc" SWARM_PROJECT="café" "$BASH" -c \
            'source "$1"; swarm_project_resolve /src/x >/dev/null; echo $?' \
            _ "$TESTS_DIR/../lib/project.sh" 2>/dev/null)"
done

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

cat > "$TMPDIR/omitted_count.json" <<'EOF'
{
  "prompt": "p.md",
  "agents": [
    { "name": "headless", "count": 1, "model": "claude-opus-4-6" },
    { "name": "manual", "model": "gpt-5.4", "driver": "codex-cli" }
  ]
}
EOF
assert_eq "omitted count defaults to zero" "1" \
    "$(parse_num_agents "$TMPDIR/omitted_count.json")"
assert_eq "omitted count not expanded into agents cfg" "1" \
    "$(parse_agents_cfg "$TMPDIR/omitted_count.json" | wc -l | tr -d ' ')"

cat > "$TMPDIR/state_summary_interactive.json" <<'EOF'
{
  "prompt": "prompts/headless.md",
  "agents": [
    {
      "name": "headless",
      "count": 2,
      "model": "claude-opus-4-6",
      "context": "slim"
    },
    {
      "name": "manual-omitted",
      "model": "claude-opus-4-6",
      "context": "slim",
      "prompt": "prompts/headless-manual.md"
    },
    {
      "name": "manual-zero",
      "count": 0,
      "model": "gpt-5.4",
      "context": "slim",
      "prompt": "prompts/headless-manual.md"
    }
  ]
}
EOF
assert_eq "state summary skips interactive-only profiles" \
    "2x claude-opus-4-6 ctx:slim" \
    "$(state_model_summary_for_test "$TMPDIR/state_summary_interactive.json")"

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
echo "=== 18. Interactive profile selection ==="

_INTERACTIVE_FUNCS="$TMPDIR/interactive_funcs.sh"
awk '
    /^print_interactive_profiles\(\)[[:space:]]*\{/ { p = 1 }
    /^cmd_interactive\(\)[[:space:]]*\{/ { exit }
    p { print }
' "$_LAUNCH" > "$_INTERACTIVE_FUNCS"
# shellcheck source=/dev/null
source "$_INTERACTIVE_FUNCS"

cat > "$TMPDIR/interactive_named.json" <<'EOF'
{
  "driver": "codex-cli",
  "agents": [
    {
      "name": "hunter",
      "count": 0,
      "model": "gpt-5.4",
      "effort": "xhigh",
      "auth": "chatgpt"
    },
    {
      "name": "triage",
      "count": 1,
      "model": "claude-opus-4-6",
      "driver": "claude-code"
    }
  ]
}
EOF

CONFIG_FILE="$TMPDIR/interactive_named.json"
select_interactive_profile hunter "" "$TMPDIR/profile.json"
assert_eq "select named profile" "gpt-5.4" \
    "$(jq -r '.model' "$TMPDIR/profile.json")"
assert_eq "count zero profile selectable" "0" \
    "$(jq -r '.count' "$TMPDIR/profile.json")"

select_interactive_profile "" "2" "$TMPDIR/profile.json"
assert_eq "select by agent index" "triage" \
    "$(jq -r '.name' "$TMPDIR/profile.json")"

cat > "$TMPDIR/interactive_single.json" <<'EOF'
{
  "agents": [
    { "count": 0, "model": "fake-model", "driver": "fake" }
  ]
}
EOF
CONFIG_FILE="$TMPDIR/interactive_single.json"
select_interactive_profile "" "" "$TMPDIR/profile.json"
assert_eq "single unnamed profile selected by default" "fake" \
    "$(jq -r '.driver' "$TMPDIR/profile.json")"

CONFIG_FILE="$TMPDIR/interactive_named.json"
if (select_interactive_profile "" "" "$TMPDIR/profile.json" 2>/dev/null); then
    echo "  FAIL: ambiguous profile should error"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: ambiguous profile rejected"
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
assert_eq "launch help says wait does not start agents" "true" \
    "$([[ "$out" == *"Does not"* && "$out" == *"start agents"* ]] \
        && echo true || echo false)"
assert_eq "launch help says post-process harvests" "true" \
    "$([[ "$out" == *"Run only the post-processing agent"* \
        && "$out" == *"harvest"* ]] && echo true || echo false)"
assert_eq "launch help lists interactive command" "true" \
    "$([[ "$out" == *"interactive PROFILE"* \
        && "$out" == *"agent profile"* ]] && echo true || echo false)"

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
# Must run from a git repo (launch.sh needs git rev-parse).  The checks
# before it ask Docker for its context and containers: a fake docker
# answers, with none.
_no_cfg_dir=$(mktemp -d)
_no_cfg_bin=$(mktemp -d)
printf '#!/bin/bash\n[ "$1 $2" = "context show" ] && echo default\nexit 0\n' \
    > "$_no_cfg_bin/docker"
chmod +x "$_no_cfg_bin/docker"
git -C "$_no_cfg_dir" init -q
out=$(cd "$_no_cfg_dir" && PATH="$_no_cfg_bin:$PATH" SWARM_CONFIG="" \
    bash "$TESTS_DIR/../launch.sh" start 2>&1) && rc=0 || rc=$?
rm -rf "$_no_cfg_dir" "$_no_cfg_bin"
assert_eq "no config exits nonzero" "1" "$rc"
assert_eq "no config says swarmfile" "true" \
    "$([[ "$out" == *"swarmfile"* ]] && echo true || echo false)"

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

# The reader launch.sh uses (lib/docker-args.sh), its elements joined by
# "|" so that their boundaries show.
build_docker_extra_args() {
    (
        # shellcheck source=../lib/docker-args.sh
        source "$TESTS_DIR/../lib/docker-args.sh"
        swarm_docker_args_read "$1" || exit 1
        IFS='|'
        echo "${SWARM_DOCKER_ARGS[*]+"${SWARM_DOCKER_ARGS[*]}"}"
    )
}

cat > "$TMPDIR/da_full.json" <<'EOF'
{
  "prompt": "p.md",
  "docker_args": ["-v", "/var/run/docker.sock:/var/run/docker.sock", "--privileged"],
  "agents": [{ "count": 1, "model": "m" }]
}
EOF

assert_eq "docker_args full" \
    "-v|/var/run/docker.sock:/var/run/docker.sock|--privileged" \
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
_da_want="-v|/var/run/docker.sock:/var/run/docker.sock"
_da_want="${_da_want}|-v|/tmp:/host-tmp:ro|--cap-add|SYS_PTRACE"
assert_eq "docker_args complex" "$_da_want" \
    "$(build_docker_extra_args "$TMPDIR/da_complex.json")"
# An element with a space stays one element.
cat > "$TMPDIR/da_space.json" <<'EOF'
{ "prompt": "p.md", "docker_args": ["--label", "a b=c d"],
  "agents": [{ "count": 1, "model": "m" }] }
EOF
assert_eq "docker_args element with a space" "--label|a b=c d" \
    "$(build_docker_extra_args "$TMPDIR/da_space.json")"

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
echo "=== 35b. Bare repo and mirrors share no object files with the checkout ==="

# A local clone hardlinks object files unless told otherwise, and the
# chmod -R a+rwX in create_bare_repo and mirror_submodules would then
# make the checkout's own object files writable for every user.  Run
# the live functions from launch.sh on a checkout with packed and loose
# objects, a submodule, and objects borrowed through alternates, and
# check that nothing is shared, changed or still borrowed.
_hl_links() {
    stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}
_hl_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
_hl_launch="$TESTS_DIR/../launch.sh"
_hl_dir="$TMPDIR/hl"
_hl_git() {
    git -c user.name=test -c user.email=test@test \
        -c commit.gpgsign=false -c protocol.file.allow=always "$@"
}
mkdir -p "$_hl_dir"
_hl_git -C "$_hl_dir" init -q base
_hl_git -C "$_hl_dir/base" commit --allow-empty -m base -q
_hl_base_head=$(git -C "$_hl_dir/base" rev-parse HEAD)
_hl_git -C "$_hl_dir" init -q sub
_hl_git -C "$_hl_dir/sub" commit --allow-empty -m sub -q
# src borrows base's objects through alternates.
_hl_git -C "$_hl_dir" clone -q --shared base src
_hl_git -C "$_hl_dir/src" submodule add -q "$_hl_dir/sub" sub 2>/dev/null
_hl_git -C "$_hl_dir/src" commit -m src -q
git -C "$_hl_dir/src" gc -q
git -C "$_hl_dir/src/.git/modules/sub" gc -q
_hl_git -C "$_hl_dir/src" commit --allow-empty -m loose -q
_hl_loose=$(git -C "$_hl_dir/src" rev-parse HEAD)
_hl_loose="$_hl_dir/src/.git/objects/${_hl_loose:0:2}/${_hl_loose:2}"
_hl_loose_mode=$(_hl_mode "$_hl_loose")
_hl_packs=("$_hl_dir"/src/.git/objects/pack/*.pack)
_hl_src_pack=${_hl_packs[0]}
_hl_packs=("$_hl_dir"/src/.git/modules/sub/objects/pack/*.pack)
_hl_sub_pack=${_hl_packs[0]}
_hl_src_mode=$(_hl_mode "$_hl_src_pack")
_hl_sub_mode=$(_hl_mode "$_hl_sub_pack")

for _hl_fn in create_bare_repo prepare_bare_repo begin_engagement \
        engagement_base mirror_submodules; do
    awk -v fn="$_hl_fn" '$0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { p = 1 }
         p { print }
         p && /^\}[[:space:]]*$/ { exit }' "$_hl_launch"
done > "$TMPDIR/hl_funcs.sh"
_hl_runtime="$_hl_dir/runtime"
mkdir -m 700 "$_hl_runtime"
_hl_mirror="$_hl_runtime/mirrors/sub.git"
(
    # shellcheck source=/dev/null
    source "$TMPDIR/hl_funcs.sh"
    # No Docker here: the daemon id is made up.
    # shellcheck disable=SC2329
    swarm_docker_daemon_id() { printf 'TEST:DAEMON'; }
    REPO_ROOT="$_hl_dir/src"
    BARE_REPO="$_hl_dir/bare.git"
    MIRROR_DIR="$_hl_runtime/mirrors"
    STATE_FILE="$_hl_runtime/state.json"
    create_bare_repo
    mirror_submodules
) >/dev/null 2>&1 || true

assert_eq "bare repo has the checkout's HEAD on agent-work" \
    "$(git -C "$_hl_dir/src" rev-parse HEAD)" \
    "$(git -C "$_hl_dir/bare.git" rev-parse agent-work 2>/dev/null)"
assert_eq "mirror has the submodule's commit" \
    "$(git -C "$_hl_dir/sub" rev-parse HEAD)" \
    "$(git -C "$_hl_mirror" rev-parse HEAD 2>/dev/null)"
assert_eq "checkout pack is not shared with the bare repo" "1" \
    "$(_hl_links "$_hl_src_pack")"
assert_eq "checkout pack keeps its mode" "$_hl_src_mode" \
    "$(_hl_mode "$_hl_src_pack")"
assert_eq "submodule pack is not shared with its mirror" "1" \
    "$(_hl_links "$_hl_sub_pack")"
assert_eq "submodule pack keeps its mode" "$_hl_sub_mode" \
    "$(_hl_mode "$_hl_sub_pack")"
assert_eq "checkout loose object is not shared with the bare repo" "1" \
    "$(_hl_links "$_hl_loose")"
assert_eq "checkout loose object keeps its mode" "$_hl_loose_mode" \
    "$(_hl_mode "$_hl_loose")"
_hl_alt=no
[ -e "$_hl_dir/bare.git/objects/info/alternates" ] && _hl_alt=yes
assert_eq "bare repo does not borrow objects" "no" "$_hl_alt"
mv "$_hl_dir/base" "$_hl_dir/base.moved"
_hl_kept=no
git -C "$_hl_dir/bare.git" cat-file -e "${_hl_base_head}^{commit}" \
    2>/dev/null && _hl_kept=yes
assert_eq "bare repo keeps the borrowed objects" "yes" "$_hl_kept"
assert_eq "every bare clone in launch.sh goes through Git's transport" \
    "$(grep -c 'git clone --bare ' "$_hl_launch")" \
    "$(grep -c 'git clone --bare --no-local ' "$_hl_launch")"

rm -rf "$_hl_dir"

# ============================================================
echo ""
echo "=== 35c. Bare repo and mirrors hold what branches, tags and HEAD reach ==="

# Objects of the checkout that only other refs (remote-tracking, the
# recovery refs, the stash) or nothing reach stay out of the bare repo,
# so a cleanup does not keep them again.  A mirror holds what the
# submodule's branches, tags and HEAD reach, and the commit the
# engagement's base records for the submodule under refs/swarm/gitlink,
# fetched by id when the submodule's checkout moved on; a base that
# records a commit the submodule lacks gets a warning.  The live
# functions again (extracted in 35b).
_tr_has() {  # REPO OID: yes when REPO has the object
    if git -C "$1" cat-file -e "$2" 2>/dev/null; then echo yes
    else echo no; fi
}
_tr_unreachable() {  # REPO: how many objects no ref and no HEAD reach
    git -C "$1" cat-file --batch-all-objects \
        --batch-check='%(objectname)' | sort > "$TMPDIR/tr_all"
    git -C "$1" rev-list --objects --no-object-names --all HEAD \
        | sort -u > "$TMPDIR/tr_reach"
    comm -23 "$TMPDIR/tr_all" "$TMPDIR/tr_reach" | wc -l | tr -d ' '
}
# A user whose Git speaks protocol v0 by default.
printf '[protocol]\n\tversion = 0\n' > "$TMPDIR/tr_v0.gitconfig"
_tr_run() {  # FUNCTION ARGS...: one of the live functions, output kept
    (
        export GIT_CONFIG_GLOBAL="$TMPDIR/tr_v0.gitconfig"
        # shellcheck source=/dev/null
        source "$TMPDIR/hl_funcs.sh"
        # shellcheck disable=SC2329
        swarm_docker_daemon_id() { printf 'TEST:DAEMON'; }
        REPO_ROOT="$_tr_src"
        BARE_REPO="$_tr_dir/bare.git"
        MIRROR_DIR="$_tr_runtime/mirrors"
        STATE_FILE="$_tr_runtime/state.json"
        "$@"
    ) > "$TMPDIR/tr.out" 2>&1
}
_tr_dir="$TMPDIR/tr"
mkdir -p "$_tr_dir"
for _tr_s in sub sub2; do
    _hl_git -C "$_tr_dir" init -q "$_tr_s"
    _hl_git -C "$_tr_dir/$_tr_s" commit --allow-empty -m "$_tr_s one" -q
done
_tr_src="$_tr_dir/src"
_hl_git -C "$_tr_dir" init -q src
_hl_git -C "$_tr_src" commit --allow-empty -m one -q
_hl_git -C "$_tr_src" submodule add -q "$_tr_dir/sub" sub 2>/dev/null
_hl_git -C "$_tr_src" submodule add -q "$_tr_dir/sub2" sub2 2>/dev/null
_hl_git -C "$_tr_src" commit -m 'Add the submodules' -q
# Only a remote-tracking ref reaches this commit, only a recovery ref
# this blob, only the stash its commit, and nothing the last blob.
_tr_remote=$(_hl_git -C "$_tr_src" commit-tree -p HEAD -m remote \
    'HEAD^{tree}')
git -C "$_tr_src" update-ref refs/remotes/origin/side "$_tr_remote"
_tr_rec=$(printf 'kept by a recovery ref\n' \
    | git -C "$_tr_src" hash-object -w --stdin)
git -C "$_tr_src" update-ref refs/swarm-recovery/e00/s/s1/1/t/1 "$_tr_rec"
echo wip > "$_tr_src/wip.txt"
_hl_git -C "$_tr_src" add wip.txt
_hl_git -C "$_tr_src" stash -q
_tr_stash=$(git -C "$_tr_src" rev-parse refs/stash)
_tr_none=$(printf 'kept by nothing\n' \
    | git -C "$_tr_src" hash-object -w --stdin)
# The base records, for sub2, a commit sub2 never had.
_tr_fake=$(printf 'no such commit\n' | git -C "$_tr_src" hash-object --stdin)
git -C "$_tr_src" update-index --cacheinfo "160000,${_tr_fake},sub2"
_hl_git -C "$_tr_src" commit -m 'Point sub2 at a commit it lacks' -q
# sub's checkout moves on: HEAD to a commit of its own, and of its refs
# only a remote-tracking one stays, at a child of the commit the base
# records (so no ref has that commit as its tip, and protocol v0 would
# refuse to fetch it by id); the mirror must not get the child.
_tr_gitlink=$(git -C "$_tr_src" rev-parse HEAD:sub)
_tr_empty=$(git -C "$_tr_src/sub" mktree < /dev/null)
_tr_orphan=$(_hl_git -C "$_tr_src/sub" commit-tree -m orphan "$_tr_empty")
_tr_subside=$(_hl_git -C "$_tr_src/sub" commit-tree -p "$_tr_gitlink" \
    -m side "$_tr_empty")
git -C "$_tr_src/sub" update-ref refs/remotes/origin/side "$_tr_subside"
git -C "$_tr_src/sub" checkout -q --detach "$_tr_orphan"
for _tr_r in $(git -C "$_tr_src/sub" for-each-ref --format='%(refname)'); do
    [ "$_tr_r" = refs/remotes/origin/side ] \
        || git -C "$_tr_src/sub" update-ref --no-deref -d "$_tr_r"
done
assert_eq "sub's branches, tags and HEAD do not reach the base's commit" \
    0 "$(git -C "$_tr_src/sub" rev-list HEAD --branches --tags \
        | grep -cx "$_tr_gitlink")"
assert_eq "and no ref of sub has it as its tip" 0 \
    "$(git -C "$_tr_src/sub" for-each-ref --format='%(objectname)' \
        | grep -cx "$_tr_gitlink")"
_tr_runtime="$_tr_dir/runtime"
mkdir -m 700 "$_tr_runtime"
_tr_rc=0
_tr_run eval 'create_bare_repo && mirror_submodules' || _tr_rc=$?
assert_eq "start's bare repo and mirrors are made" 0 "$_tr_rc"
_tr_bare="$_tr_dir/bare.git"
_tr_mirror="$_tr_runtime/mirrors/sub.git"
_tr_mirror2="$_tr_runtime/mirrors/sub2.git"
assert_eq "bare repo: agent-work at the checkout's HEAD" \
    "$(git -C "$_tr_src" rev-parse HEAD)" \
    "$(git -C "$_tr_bare" rev-parse agent-work 2>/dev/null)"
assert_eq "bare repo: no commit only a remote-tracking ref reaches" \
    no "$(_tr_has "$_tr_bare" "$_tr_remote")"
assert_eq "bare repo: no object only a recovery ref reaches" \
    no "$(_tr_has "$_tr_bare" "$_tr_rec")"
assert_eq "bare repo: no commit only the stash reaches" \
    no "$(_tr_has "$_tr_bare" "$_tr_stash")"
assert_eq "bare repo: no object nothing reaches" \
    no "$(_tr_has "$_tr_bare" "$_tr_none")"
assert_eq "bare repo: every object is reachable" \
    0 "$(_tr_unreachable "$_tr_bare")"
assert_eq "mirror: the base's commit under refs/swarm/gitlink" \
    "$_tr_gitlink" \
    "$(git -C "$_tr_mirror" rev-parse -q --verify refs/swarm/gitlink)"
assert_eq "mirror: HEAD where the submodule's is" "$_tr_orphan" \
    "$(git -C "$_tr_mirror" rev-parse -q --verify HEAD)"
assert_eq "mirror: no commit only a remote-tracking ref reaches" \
    no "$(_tr_has "$_tr_mirror" "$_tr_subside")"
assert_eq "mirror: every object is reachable" \
    0 "$(_tr_unreachable "$_tr_mirror")"
# What a container does: a local clone of the mirror, then a checkout
# of the commit the base records.
_tr_ck=no
git clone -q "$_tr_mirror" "$_tr_dir/subclone" 2>/dev/null \
    && git -C "$_tr_dir/subclone" checkout -q "$_tr_gitlink" 2>/dev/null \
    && _tr_ck=yes
assert_eq "a clone of the mirror checks the base's commit out" yes "$_tr_ck"
assert_eq "sub2: mirrored all the same" yes \
    "$([ -d "$_tr_mirror2" ] && echo yes || echo no)"
assert_eq "sub2: no refs/swarm/gitlink" no \
    "$(git -C "$_tr_mirror2" rev-parse -q --verify refs/swarm/gitlink \
        >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "sub2: a warning names the commit it lacks" 1 \
    "$(grep -c "^WARNING: .* has no commit ${_tr_fake}, " "$TMPDIR/tr.out")"
# A session that joins adds a missing mirror for the engagement's base,
# not for the checkout's HEAD, which moved since.
_hl_git -C "$_tr_src/sub" checkout -q --detach "$_tr_subside"
_hl_git -C "$_tr_src" add sub
_hl_git -C "$_tr_src" commit -m 'Move sub' -q
mv "$_tr_mirror" "$_tr_dir/sub-first.git"
_tr_rc=0
_tr_run mirror_submodules missing || _tr_rc=$?
assert_eq "a joining session adds the missing mirror" 0 "$_tr_rc"
assert_eq "for the engagement's base" "$_tr_gitlink" \
    "$(git -C "$_tr_mirror" rev-parse -q --verify refs/swarm/gitlink)"
# A state file whose base is not a commit id: no mirror.
mv "$_tr_mirror" "$_tr_dir/sub-second.git"
jq -c '.base_commit = "HEAD"' "$_tr_runtime/state.json" \
    > "$_tr_runtime/state.json.tmp"
mv "$_tr_runtime/state.json.tmp" "$_tr_runtime/state.json"
_tr_rc=0
_tr_run mirror_submodules missing || _tr_rc=$?
assert_eq "a base that is no commit id refuses" 1 "$_tr_rc"
assert_eq "saying so" 1 "$(grep -c 'records no base commit' "$TMPDIR/tr.out")"
assert_eq "and mirrors nothing" no \
    "$([ -e "$_tr_mirror" ] && echo yes || echo no)"
# A commit id the checkout does not have: refused before anything is
# made.
jq -c --arg base "$_tr_fake" '.base_commit = $base' \
    "$_tr_runtime/state.json" > "$_tr_runtime/state.json.tmp"
mv "$_tr_runtime/state.json.tmp" "$_tr_runtime/state.json"
_tr_rc=0
_tr_run mirror_submodules missing || _tr_rc=$?
assert_eq "a base the checkout lacks refuses" 1 "$_tr_rc"
assert_eq "naming it" 1 \
    "$(grep -c "^ERROR: cannot read .* in the engagement's base ${_tr_fake}" \
        "$TMPDIR/tr.out")"
assert_eq "and makes no mirror, not even a .new" no \
    "$([ -e "$_tr_mirror" ] || [ -e "$_tr_mirror.new" ] && echo yes || echo no)"

rm -rf "$_tr_dir"

# ============================================================
echo ""
echo "=== 35d. Each mirror comes from its submodule's own Git directory ==="

# A submodule's Git directory is .git/modules/<name>, not <path>, and
# some keep theirs in their work tree: one moved with git mv, two whose
# names are each other's paths, and one added from a repository already
# there.  Each mirror, named after its submodule, holds that
# submodule's commits, and a clone of the bare repo whose submodules
# point at the mirrors, as a container's does, checks each of them out.
# The live functions again (extracted in 35b).
_gd_dir="$TMPDIR/gd"
mkdir -p "$_gd_dir"
for _gd_r in one rx ry; do
    _hl_git -C "$_gd_dir" init -q "$_gd_r"
    _hl_git -C "$_gd_dir/$_gd_r" commit --allow-empty -m "$_gd_r" -q
done
_gd_src="$_gd_dir/src"
_hl_git -C "$_gd_dir" init -q src
_hl_git -C "$_gd_src" commit --allow-empty -m one -q
_hl_git -C "$_gd_src" submodule add -q "$_gd_dir/one" first 2>/dev/null
_hl_git -C "$_gd_src" commit -m 'Add first' -q
mkdir -p "$_gd_src/lib"
_hl_git -C "$_gd_src" mv first lib/moved
_hl_git -C "$_gd_src" commit -m 'Move first' -q
_hl_git -C "$_gd_src" submodule add -q --name x "$_gd_dir/rx" y 2>/dev/null
_hl_git -C "$_gd_src" submodule add -q --name y "$_gd_dir/ry" x 2>/dev/null
_hl_git -C "$_gd_src" init -q inner
_hl_git -C "$_gd_src/inner" commit --allow-empty -m inner -q
_hl_git -C "$_gd_src" submodule add -q "$_gd_dir/one" inner >/dev/null 2>&1
_hl_git -C "$_gd_src" commit -m 'Add x, y and inner' -q
assert_eq "first's Git directory is under its name, not its path" \
    "yes no" \
    "$([ -d "$_gd_src/.git/modules/first" ] && echo yes || echo no) $(
        [ -e "$_gd_src/.git/modules/lib/moved" ] && echo yes || echo no)"
assert_eq "inner keeps its Git directory in its work tree" "yes no" \
    "$([ -d "$_gd_src/inner/.git" ] && echo yes || echo no) $(
        [ -e "$_gd_src/.git/modules/inner" ] && echo yes || echo no)"
_gd_runtime="$_gd_dir/runtime"
mkdir -m 700 "$_gd_runtime"
_gd_run() {  # 'FUNCTION [ARG]'...: each in turn, under set -e as in
    # launch.sh (a subshell after || would ignore it)
    set +e
    (
        set -e
        # shellcheck source=/dev/null
        source "$TMPDIR/hl_funcs.sh"
        # shellcheck disable=SC2329
        swarm_docker_daemon_id() { printf 'TEST:DAEMON'; }
        REPO_ROOT="$_gd_src"
        BARE_REPO="$_gd_dir/bare.git"
        MIRROR_DIR="$_gd_runtime/mirrors"
        STATE_FILE="$_gd_runtime/state.json"
        for _gd_cmd in "$@"; do
            $_gd_cmd
        done
    ) > "$TMPDIR/gd.out" 2>&1
    _gd_rc=$?
    set -e
}
_gd_run create_bare_repo mirror_submodules
assert_eq "start's bare repo and mirrors are made" 0 "$_gd_rc"
assert_eq "with no warning" 0 "$(grep -c '^WARNING' "$TMPDIR/gd.out" || true)"
for _gd_case in first:lib/moved:one x:y:rx y:x:ry inner:inner:src/inner; do
    IFS=: read -r _gd_name _gd_path _gd_repo <<< "$_gd_case"
    _gd_link=$(git -C "$_gd_src" rev-parse "HEAD:$_gd_path")
    assert_eq "${_gd_name} (at ${_gd_path}): the base's commit is ${_gd_repo}'s" \
        "$(git -C "$_gd_dir/$_gd_repo" rev-parse HEAD)" "$_gd_link"
    assert_eq "${_gd_name}: its mirror has it under refs/swarm/gitlink" \
        "$_gd_link" \
        "$(git -C "$_gd_runtime/mirrors/${_gd_name}.git" rev-parse -q \
            --verify refs/swarm/gitlink 2>/dev/null)"
done
# What a container does with the mounts: a clone of the bare repo whose
# submodules, by name, point at the mirrors.
_gd_ck="$_gd_dir/ck"
_hl_git clone -q "$_gd_dir/bare.git" "$_gd_ck" 2>/dev/null || true
git config --file "$_gd_ck/.gitmodules" --get-regexp 'submodule\..*\.path' \
    > "$TMPDIR/gd.paths" 2>/dev/null || true
while read -r _gd_key _gd_path; do
    _gd_name="${_gd_key#submodule.}"
    _gd_name="${_gd_name%.path}"
    git -C "$_gd_ck" config "submodule.${_gd_name}.url" \
        "$_gd_runtime/mirrors/${_gd_name}.git"
    _hl_git -C "$_gd_ck" submodule update --init -q -- "$_gd_path" \
        2>/dev/null || true
done < "$TMPDIR/gd.paths"
for _gd_path in lib/moved y x inner; do
    # " <commit>": checked out at the commit the base records.
    assert_eq "the clone checks ${_gd_path} out at the base's commit" \
        " $(git -C "$_gd_src" rev-parse "HEAD:$_gd_path")" \
        "$(git -C "$_gd_ck" submodule status -- "$_gd_path" 2>/dev/null \
            | cut -c1-41)"
done
# A submodule whose Git directory cannot be found or read stops start:
# a .git that names no repository (Git's foreach refuses it before the
# command runs), and a config Git cannot parse (git rev-parse fails in
# the command).  Each time on a new runtime directory and bare repo.
_gd_again() {  # N: put the last runtime directory and bare repo aside
    mv "$_gd_runtime" "$_gd_dir/runtime-$1"
    if [ -e "$_gd_dir/bare.git" ]; then
        mv "$_gd_dir/bare.git" "$_gd_dir/bare-$1.git"
    fi
    mkdir -m 700 "$_gd_runtime"
}
_gd_again 1
mv "$_gd_src/lib/moved/.git" "$_gd_dir/moved.gitfile"
printf 'gitdir: %s\n' "$_gd_dir/nowhere" > "$_gd_src/lib/moved/.git"
_gd_run create_bare_repo mirror_submodules
assert_eq "a submodule whose .git leads nowhere stops start" 1 \
    "$([ "$_gd_rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "and gets no mirror" no \
    "$([ -e "$_gd_runtime/mirrors/first.git" ] \
        || [ -e "$_gd_runtime/mirrors/first.git.new" ] && echo yes || echo no)"
mv "$_gd_dir/moved.gitfile" "$_gd_src/lib/moved/.git"
_gd_again 2
cp "$_gd_src/.git/modules/first/config" "$_gd_dir/first.config"
printf '[core\n' >> "$_gd_src/.git/modules/first/config"
_gd_run create_bare_repo mirror_submodules
assert_eq "a submodule whose config Git cannot read stops start" 1 \
    "$([ "$_gd_rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "naming the file" 1 \
    "$(grep -q "modules/first/config" "$TMPDIR/gd.out" && echo 1 || echo 0)"
assert_eq "and gets no mirror" no \
    "$([ -e "$_gd_runtime/mirrors/first.git" ] \
        || [ -e "$_gd_runtime/mirrors/first.git.new" ] && echo yes || echo no)"
# A session that joins the first engagement, whose mirrors are all
# there, stops too, and leaves them as they are.
_gd_again 3
rmdir "$_gd_runtime"
mv "$_gd_dir/runtime-1" "$_gd_runtime"
if [ -e "$_gd_dir/bare-1.git" ]; then
    mv "$_gd_dir/bare-1.git" "$_gd_dir/bare.git"
fi
# A file of the test's own in first's mirror, and its refs: both stay
# if the mirror does.
_gd_refs() {
    git -C "$_gd_runtime/mirrors/first.git" for-each-ref \
        --format='%(objectname) %(refname)' 2>/dev/null || true
}
touch "$_gd_runtime/mirrors/first.git/gd-sentinel" 2>/dev/null || true
_gd_before=$(_gd_refs)
_gd_run 'mirror_submodules missing'
assert_eq "a joining session stops on that config too" 1 \
    "$([ "$_gd_rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "naming the file" 1 \
    "$(grep -q "modules/first/config" "$TMPDIR/gd.out" && echo 1 || echo 0)"
assert_eq "and leaves first's mirror in place" yes \
    "$([ -e "$_gd_runtime/mirrors/first.git/gd-sentinel" ] && echo yes || echo no)"
assert_eq "with the same refs" "$_gd_before" "$(_gd_refs)"
assert_eq "among them the pin" 1 \
    "$(printf '%s\n' "$_gd_before" | grep -c ' refs/swarm/gitlink$' || true)"
cp "$_gd_dir/first.config" "$_gd_src/.git/modules/first/config"
_gd_run 'mirror_submodules missing'
assert_eq "with the config back, the session joins" 0 "$_gd_rc"

rm -rf "$_gd_dir"

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

cat > "$TMPDIR/csa_fake.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [{ "count": 1, "model": "fake", "driver": "fake" }] }
EOF
assert_eq "absent post-process adds no implicit driver" "fake" \
    "$(compute_swarm_agents "$TMPDIR/csa_fake.json")"

cat > "$TMPDIR/csa_pp_null.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [{ "count": 1, "model": "fake", "driver": "fake" }],
  "post_process": null }
EOF
assert_eq "null post-process adds no implicit driver" "fake" \
    "$(compute_swarm_agents "$TMPDIR/csa_pp_null.json")"

cat > "$TMPDIR/csa_unused_top.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "codex-cli",
  "agents": [{ "count": 1, "model": "fake", "driver": "fake" }] }
EOF
assert_eq "absent post-process skips unused top-level driver" "fake" \
    "$(compute_swarm_agents "$TMPDIR/csa_unused_top.json")"

cat > "$TMPDIR/csa_pp_default.json" <<'EOF'
{ "prompt": "p.md",
  "agents": [{ "count": 1, "model": "fake", "driver": "fake" }],
  "post_process": { "prompt": "r.md" } }
EOF
assert_eq "configured post-process keeps default driver" \
    "fake,claude-code" \
    "$(compute_swarm_agents "$TMPDIR/csa_pp_default.json")"

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

cat > "$TMPDIR/csa_interactive_zero.json" <<'EOF'
{ "prompt": "p.md",
  "driver": "claude-code",
  "agents": [
    { "name": "agent", "count": 1, "model": "claude-opus-4-6" },
    { "name": "operator", "count": 0, "model": "gpt-5", "driver": "codex-cli" }
  ] }
EOF
assert_eq "count zero interactive profile contributes driver" \
    "claude-code,codex-cli" \
    "$(compute_swarm_agents "$TMPDIR/csa_interactive_zero.json")"

# ============================================================
echo ""
echo "=== 39. build_image is wired into launch entrypoints ==="

# The PR #96 contract: a standalone post-process invocation must
# rebuild the image with build-args derived from its own config so
# the layer cache invalidates correctly when the driver set differs
# from a prior cmd_start.  Catches accidental removal of either
# call site.  post-process and interactive build in each of their two
# ways (creating the engagement, joining it), start in its one.
_call_sites=$(grep -cE '^[[:space:]]+build_image[[:space:]]*$' \
    "$_LAUNCH_SH" || true)
assert_eq "build_image has 5 call sites" "5" "$_call_sites"

_pp_calls=$(awk '
    /^cmd_post_process\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+build_image[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")
assert_eq "cmd_post_process calls build_image in both ways" "2" "$_pp_calls"

_start_calls=$(awk '
    /^cmd_start\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+build_image[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")
assert_eq "cmd_start calls build_image" "1" "$_start_calls"

_interactive_calls=$(awk '
    /^ensure_bare_repo_for_interactive\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+build_image[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")
assert_eq "interactive calls build_image in both ways" "2" \
    "$_interactive_calls"
assert_eq "cmd_interactive goes through that step" "1" "$(awk '
    /^cmd_interactive\(\)[[:space:]]*\{/ { p = 1; next }
    p && /^\}[[:space:]]*$/ { p = 0 }
    p && /^[[:space:]]+ensure_bare_repo_for_interactive[[:space:]]*$/ { c++ }
    END { print c + 0 }
' "$_LAUNCH_SH")"

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
echo "=== 40. cmd_stop gives the harness time to push ==="

# `docker stop` defaults to SIGTERM + 10s grace + SIGKILL.  The
# harness's SIGTERM trap pushes any in-flight local commits via
# `_session_end_push`, which on a contended bare repo (45+
# agents racing the same push lock) can easily take more than
# 10s to land.  Without `-t`, that emergency push gets cut
# mid-rebase and the commits die with the container.  Pin the
# flag's presence, the default, and the env-var override.
LAUNCH_FILE="$TESTS_DIR/../launch.sh"
CMD_STOP_BODY=$(awk '/^cmd_stop\(\) \{/,/^\}$/' "$LAUNCH_FILE")
# cmd_stop checks a copy of the state, which these make.
STOP_HELPERS=$(awk '/^(state_snapshot|swarm_tmp_file)\(\) \{/,/^\}$/' \
    "$LAUNCH_FILE")
assert_eq "cmd_stop passes the grace to docker stop" "1" \
    "$(printf '%s\n' "$CMD_STOP_BODY" \
        | grep -cF 'docker stop -t "$stop_timeout"')"
assert_eq "cmd_stop defaults grace to 60s" "1" \
    "$(printf '%s\n' "$CMD_STOP_BODY" \
        | grep -cF 'stop_timeout="${SWARM_STOP_TIMEOUT:-60}"')"

# A fake docker on PATH logs the calls that reach the CLI.
FAKE_DOCKER_DIR=$(mktemp -d)
trap_dir="$TMPDIR/cmd_stop_invocations"
mkdir -p "$trap_dir"
cat > "$FAKE_DOCKER_DIR/docker" <<FAKE
#!/bin/bash
echo "\$@" >> "$trap_dir/calls"
exit 0
FAKE
chmod +x "$FAKE_DOCKER_DIR/docker"

# Run cmd_stop ARGS on the engagement of $_sr/state.json (token tok1 on
# daemon d1 unless set otherwise), with a docker function in front of
# the fake CLI.  The running containers are the lines of $_sr/list,
# "<name> <project> <checkout> <token>", each with ID "id-<name>"; each
# run starts from them, and a container it stops no longer runs.
# STOP_DAEMON names the daemon Docker talks to (d1); with STOP_SWITCH
# set, the first docker stop makes a new engagement (token tok2, same
# names) take the place of this one.
_sr="$TMPDIR/stop-rt"
mkdir -m 700 "$_sr"
stop_state() {
    printf '%s\n' "$1" > "$_sr/state.json"
}
run_stop() {
    # The containers that run, from $_sr/list; stop takes them out.
    cp "$_sr/list" "$_sr/running"
    (
        eval "$CMD_STOP_BODY"
        eval "$STOP_HELPERS"
        SWARM_TMP_FILES=()
        CHECKOUT_PATH="/checkout"
        RUNTIME_DIR="$_sr"
        STATE_FILE="$_sr/state.json"
        # Called by cmd_stop and the lib/project.sh helpers.
        # shellcheck disable=SC2329
        docker() {
            local last a want_t="" want_p="" line n pr ck tk
            for last; do :; done
            case "${1:-} ${2:-}" in
                "info -f") echo "${STOP_DAEMON:-d1}"; return 0 ;;
                "context show") echo default; return 0 ;;
                "ps -q")
                    for a; do
                        case "$a" in
                            label=swarm-core.engagement-token=*)
                                want_t="${a#*=}"; want_t="${want_t#*=}" ;;
                            label=swarm-core.project=*)
                                want_p="${a#*=}"; want_p="${want_p#*=}" ;;
                        esac
                    done
                    while read -r n pr ck tk; do
                        [ -n "$n" ] || continue
                        [ "$tk" = "$want_t" ] && [ "$pr" = "$want_p" ] \
                            && echo "id-$n"
                    done < "$_sr/running"
                    return 0 ;;
                "container inspect")
                    while read -r n pr ck tk; do
                        if [ "id-$n" = "$last" ]; then
                            echo "/$n|$pr|$ck|$tk"
                            return 0
                        fi
                    done < "$_sr/running"
                    return 1 ;;
                "stop -t")
                    # Stopped, it no longer runs.
                    grep -v "^${last#id-} " "$_sr/running" \
                        > "$_sr/running.stopped" || true
                    mv "$_sr/running.stopped" "$_sr/running"
                    if [ -n "${STOP_SWITCH:-}" ] \
                            && [ ! -e "$_sr/switched" ]; then
                        : > "$_sr/switched"
                        sed 's/ tok1$/ tok2/' "$_sr/running" > "$_sr/running.new"
                        mv "$_sr/running.new" "$_sr/running"
                        jq -c '.engagement_token = "tok2"' \
                            "$_sr/state.json" > "$_sr/state.new"
                        mv "$_sr/state.new" "$_sr/state.json"
                    fi ;;
            esac
            command docker "$@"
        }
        # cmd_stop exits on a refusal: a subshell of its own keeps that
        # from ending this one before the status is noted.
        (PATH="$FAKE_DOCKER_DIR:$PATH" cmd_stop "$@") > "$TMPDIR/stop.out" \
            2>&1 || echo "rc=1" >> "$TMPDIR/stop.out"
    )
}
_stop_engaged='{"schema":"swarm-core.state/v1","engagement_id":"e1","engagement_token":"tok1","docker_daemon":"d1"}'
stopped() {
    grep -c "^stop -t ${1:-60} " "$trap_dir/calls" || true
}

# Default grace: 60 for every container of the engagement (numbered
# agents, post-process, interactive).
stop_state "$_stop_engaged"
printf '%s\n' "fake-agent-1 fake /checkout tok1" \
    "fake-agent-2 fake /checkout tok1" "fake-agent-post fake /checkout tok1" \
    "fake-agent-interactive-codex-1 fake /checkout tok1" > "$_sr/list"
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent run_stop
assert_eq "default grace: every container of the engagement" "4" \
    "$(stopped 60)"
assert_eq "default grace: by ID" "1" \
    "$(grep -cF 'stop -t 60 id-fake-agent-post' "$trap_dir/calls" || true)"
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent SWARM_STOP_TIMEOUT=120 run_stop
assert_eq "SWARM_STOP_TIMEOUT=120 propagates to docker stop -t 120" "4" \
    "$(stopped 120)"
# Whole seconds: 0 stops at once (and tries the lock once, which flock
# -w 0 would refuse on macOS), and leading zeros go.  Anything else
# stops nothing.
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent SWARM_STOP_TIMEOUT=0 run_stop
assert_eq "SWARM_STOP_TIMEOUT=0: docker stop -t 0" "4" "$(stopped 0)"
assert_eq "SWARM_STOP_TIMEOUT=0: a success" "0" \
    "$(grep -c '^rc=1$' "$TMPDIR/stop.out" || true)"
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent SWARM_STOP_TIMEOUT=007 run_stop
assert_eq "SWARM_STOP_TIMEOUT=007: docker stop -t 7" "4" "$(stopped 7)"
for _st_bad in 1.5 abc -1 1000000 " 5"; do
    : > "$trap_dir/calls"
    PROJECT=fake IMAGE_NAME=fake-agent SWARM_STOP_TIMEOUT="$_st_bad" run_stop
    assert_eq "SWARM_STOP_TIMEOUT='${_st_bad}': refused" "true" \
        "$(grep -q 'SWARM_STOP_TIMEOUT must be a whole number' \
                "$TMPDIR/stop.out" \
            && grep -qx 'rc=1' "$TMPDIR/stop.out" && echo true || echo false)"
    assert_eq "SWARM_STOP_TIMEOUT='${_st_bad}': stops nothing" "0" \
        "$(wc -l < "$trap_dir/calls" | tr -d ' ')"
done
# --numbered: only <image>-<digits>.
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent run_stop --numbered
assert_eq "--numbered stops the numbered agents only" "2" "$(stopped 60)"
assert_eq "--numbered leaves post-process running" "0" \
    "$(grep -cF 'id-fake-agent-post' "$trap_dir/calls" || true)"
# Only this checkout's and this engagement's.
printf '%s\n' "a.b-agent-1 a.b /checkout tok1" \
    "a.b-agent-2 a.b /elsewhere tok1" "a.b-agent-3 a.b /checkout tok9" \
    > "$_sr/list"
: > "$trap_dir/calls"
PROJECT=a.b IMAGE_NAME=a.b-agent run_stop
assert_eq "another checkout's container is not stopped" "0" \
    "$(grep -cF 'id-a.b-agent-2' "$trap_dir/calls" || true)"
assert_eq "another engagement's container is not stopped" "0" \
    "$(grep -cF 'id-a.b-agent-3' "$trap_dir/calls" || true)"
assert_eq "this engagement's container is" "1" "$(stopped 60)"
# A new engagement with the same names takes this one's place after the
# first docker stop: none of its containers is stopped.
printf '%s\n' "fake-agent-1 fake /checkout tok1" \
    "fake-agent-2 fake /checkout tok1" "fake-agent-3 fake /checkout tok1" \
    > "$_sr/list"
rm -f "$_sr/switched"
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent STOP_SWITCH=1 run_stop
assert_eq "an engagement that takes this one's place mid-stop: one stop" \
    "1" "$(stopped 60)"
rm -f "$_sr/switched"
# Refusals, with nothing stopped.
printf '%s\n' "fake-agent-1 fake /checkout tok1" > "$_sr/list"
stop_state "$_stop_engaged"
for _sv in daemon token legacy; do
    : > "$trap_dir/calls"
    case "$_sv" in
        daemon) PROJECT=fake IMAGE_NAME=fake-agent STOP_DAEMON=d2 run_stop ;;
        token) PROJECT=fake IMAGE_NAME=fake-agent \
                   SWARM_ENGAGEMENT_TOKEN=tok7 run_stop ;;
        legacy)
            stop_state '{"schema":"swarm-core.state/v1","engagement_id":"e1"}'
            PROJECT=fake IMAGE_NAME=fake-agent run_stop ;;
    esac
    assert_eq "stop refuses (${_sv})" "1" \
        "$(grep -c '^rc=1$' "$TMPDIR/stop.out" || true)"
    assert_eq "and stops nothing (${_sv})" "0" "$(stopped 60)"
done
assert_eq "an earlier release's engagement: says how to finish it" "1" \
    "$(grep -c 'release that made it' "$TMPDIR/stop.out" || true)"
stop_state '{"schema":"swarm-core.state/v1"}'
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent run_stop
assert_eq "no engagement: nothing to stop" "0" "$(stopped 60)"
assert_eq "no engagement: a success" "0" \
    "$(grep -c '^rc=1$' "$TMPDIR/stop.out" || true)"
# A start holds the lock while it builds the image, before it records
# its token: with none recorded, stop waits for the lock and fails when
# another operation keeps it.
exec 8>>"$_sr/engagement.lock"
flock -n 8
: > "$trap_dir/calls"
PROJECT=fake IMAGE_NAME=fake-agent SWARM_STOP_TIMEOUT=1 run_stop
exec 8>&-
assert_eq "no engagement, lock held: stop fails" "1" \
    "$(grep -c '^rc=1$' "$TMPDIR/stop.out" || true)"
assert_eq "no engagement, lock held: says to run stop again" "1" \
    "$(grep -c 'no engagement is about to start' "$TMPDIR/stop.out" \
        || true)"

# stop never creates the runtime directory and leaves the state file in
# place, since it names the owner.
run_stop_with_runtime() {
    (
        eval "$CMD_STOP_BODY"
        eval "$STOP_HELPERS"
        SWARM_TMP_FILES=()
        IMAGE_NAME="stop-fake"
        PROJECT="fake"
        RUNTIME_DIR="$1"
        STATE_FILE="$RUNTIME_DIR/state.json"
        CHECKOUT_PATH="/checkout"
        # Called by the evaluated cmd_stop.
        # shellcheck disable=SC2329
        docker() { return 0; }
        cmd_stop >/dev/null 2>&1 || true
    ) || true
}
_stop_target="$TMPDIR/stop-target"
_stop_rt="$TMPDIR/stop-runtime"
_stop_state='{"schema":"swarm-core.state/v1"}'
mkdir -m 700 "$_stop_target"
printf '%s\n' "$_stop_state" > "$_stop_target/state.json"
ln -s "$_stop_target" "$_stop_rt"
run_stop_with_runtime "$_stop_rt"
assert_eq "stop leaves state behind a symlinked runtime" "true" \
    "$([ -e "$_stop_target/state.json" ] && echo true || echo false)"
rm -f "$_stop_rt"

run_stop_with_runtime "$TMPDIR/stop-missing"
assert_eq "stop does not create a missing runtime" "false" \
    "$([ -e "$TMPDIR/stop-missing" ] && echo true || echo false)"
# With no runtime directory at all, no engagement was started there:
# nothing to stop, a success, and no lock to wait for.
_stop_none_rc=0
_stop_none_out=$(
    eval "$CMD_STOP_BODY"
    eval "$STOP_HELPERS"
    SWARM_TMP_FILES=()
    IMAGE_NAME="stop-fake"
    PROJECT="fake"
    RUNTIME_DIR="$TMPDIR/stop-missing"
    STATE_FILE="$RUNTIME_DIR/state.json"
    CHECKOUT_PATH="/checkout"
    # Called by the evaluated cmd_stop.
    # shellcheck disable=SC2329
    docker() { return 0; }
    cmd_stop 2>&1
) || _stop_none_rc=$?
assert_eq "no runtime directory: stop succeeds" "0" "$_stop_none_rc"
assert_eq "  saying there is nothing to stop" "1" \
    "$(grep -c '^No engagement recorded; nothing to stop.$' \
        <<< "$_stop_none_out" || true)"
assert_eq "  with nothing else to say" "1" \
    "$(grep -c . <<< "$_stop_none_out" || true)"
assert_eq "  and still no runtime directory" "false" \
    "$([ -e "$TMPDIR/stop-missing" ] && echo true || echo false)"
# A dangling link there is something: stop goes on to the lock, which
# cannot be taken through it, and fails.
ln -s "$TMPDIR/stop-nowhere" "$TMPDIR/stop-dangling"
_stop_none_rc=0
_stop_none_out=$(
    eval "$CMD_STOP_BODY"
    eval "$STOP_HELPERS"
    SWARM_TMP_FILES=()
    IMAGE_NAME="stop-fake"
    PROJECT="fake"
    RUNTIME_DIR="$TMPDIR/stop-dangling"
    STATE_FILE="$RUNTIME_DIR/state.json"
    CHECKOUT_PATH="/checkout"
    SWARM_STOP_TIMEOUT=1
    # Called by the evaluated cmd_stop.
    # shellcheck disable=SC2329
    docker() { return 0; }
    cmd_stop 2>&1
) || _stop_none_rc=$?
assert_eq "a dangling runtime link: stop does not succeed" "true" \
    "$([ "$_stop_none_rc" -ne 0 ] && echo true || echo false)"
rm -f "$TMPDIR/stop-dangling"
# swarm_path_absent tells a path that is not there from one stop cannot
# look into: test -e and -L fail in both cases.
_pa() { if swarm_path_absent "$1"; then echo yes; else echo no; fi; }
mkdir -p "$TMPDIR/pa/dir"
: > "$TMPDIR/pa/file"
ln -s "$TMPDIR/pa/nowhere" "$TMPDIR/pa/dangling"
_pa_all="$(_pa "$TMPDIR/pa/none") $(_pa "$TMPDIR/pa/no/such/dirs")"
_pa_all="$_pa_all $(_pa "$TMPDIR/pa/file") $(_pa "$TMPDIR/pa/dir")"
_pa_all="$_pa_all $(_pa "$TMPDIR/pa/dangling")"
assert_eq "path absent: a missing entry, missing parents, file, dir, link" \
    "yes yes no no no" "$_pa_all"
assert_eq "path absent: below a file is no absence" "no" \
    "$(_pa "$TMPDIR/pa/file/x")"
# Only a lookup that fails with "No such file or directory" counts: any
# other error, such as metadata the system will not show (an ls that
# says so, here), is no absence.
mkdir -p "$TMPDIR/pa/ls-bin"
cat > "$TMPDIR/pa/ls-bin/ls" <<'EOF'
#!/bin/bash
echo "ls: ${3}: Operation not permitted" >&2
exit 1
EOF
chmod +x "$TMPDIR/pa/ls-bin/ls"
assert_eq "path absent: a lookup that fails otherwise is no absence" "no" \
    "$(PATH="$TMPDIR/pa/ls-bin:$PATH" _pa "$TMPDIR/pa/none")"
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$TMPDIR/pa/shut/inside"
    chmod 600 "$TMPDIR/pa/shut"
    assert_eq "path absent: below a directory it cannot search is no" \
        "no" "$(_pa "$TMPDIR/pa/shut/inside/rt")"
    _stop_none_rc=0
    _stop_none_out=$(
        eval "$CMD_STOP_BODY"
        eval "$STOP_HELPERS"
        SWARM_TMP_FILES=()
        IMAGE_NAME="stop-fake"
        PROJECT="fake"
        RUNTIME_DIR="$TMPDIR/pa/shut/inside/rt"
        STATE_FILE="$RUNTIME_DIR/state.json"
        CHECKOUT_PATH="/checkout"
        SWARM_STOP_TIMEOUT=1
        # Called by the evaluated cmd_stop.
        # shellcheck disable=SC2329
        docker() { return 0; }
        cmd_stop 2>&1
    ) || _stop_none_rc=$?
    chmod 700 "$TMPDIR/pa/shut"
    assert_eq "a runtime stop cannot look into: stop does not succeed" \
        "true" "$([ "$_stop_none_rc" -ne 0 ] && echo true || echo false)"
    assert_eq "  nor says there is nothing to stop" "0" \
        "$(grep -c 'nothing to stop' <<< "$_stop_none_out" || true)"
else
    echo "  SKIP: root searches any directory, so no permission case"
fi

mkdir -m 700 "$_stop_rt"
printf '%s\n' "$_stop_state" > "$_stop_rt/state.json"
run_stop_with_runtime "$_stop_rt"
assert_eq "stop keeps the state file, which names the owner" "true" \
    "$([ -e "$_stop_rt/state.json" ] && echo true || echo false)"

# ============================================================
echo ""
echo "=== 41. interactive command wiring ==="

CMD_INTERACTIVE_BODY=$(awk '
    /^cmd_interactive\(\)[[:space:]]*\{/ { p = 1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "$LAUNCH_FILE")

assert_eq "interactive execs docker run, -it after docker_args" "1" \
    "$(printf '%s\n' "$CMD_INTERACTIVE_BODY" \
        | grep -A2 -F 'exec docker run' \
        | sed -n '2s/.*DOCKER_EXTRA_ARGS.*/da/p;3s/^ *-it \\$/it/p' \
        | tr -d '\n' | grep -c '^dait$')"
assert_eq "interactive uses dedicated entrypoint" "1" \
    "$(printf '%s\n' "$CMD_INTERACTIVE_BODY" \
        | grep -cF -- '--entrypoint /interactive.sh')"
assert_eq "interactive exports branch env" "1" \
    "$(printf '%s\n' "$CMD_INTERACTIVE_BODY" \
        | grep -cF 'SWARM_INTERACTIVE_BRANCH')"
assert_eq "interactive supports --agent-index" "true" \
    "$([ "$(printf '%s\n' "$CMD_INTERACTIVE_BODY" \
        | grep -cF -- '--agent-index' || true)" -gt 0 ] \
        && echo true || echo false)"
assert_eq "Dockerfile copies interactive entrypoint" "1" \
    "$(grep -cF 'COPY --chmod=755 lib/interactive.sh /interactive.sh' \
        "$TESTS_DIR/../Dockerfile")"

# ============================================================
echo ""
echo "=== 42. cmd_post_process propagates container exit code ==="

# Partial-output recovery contract: when the post-process container
# crashes after committing some findings into the bare repo, harvest
# still runs (so the work isn't lost on the local branch) but the
# function returns the container's exit code.  CI workflows / daemons
# gate publish on this signal so partial state doesn't ship.
_pp_body=$(awk '
    /^cmd_post_process\(\)[[:space:]]*\{/ { p = 1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "$_LAUNCH_SH")

assert_eq "cmd_post_process captures State.ExitCode" "1" \
    "$(printf '%s\n' "$_pp_body" \
        | grep -cE 'docker inspect[[:space:]]+-f[[:space:]]+.*State\.ExitCode' \
        || true)"

assert_eq "cmd_post_process returns container exit code on failure" "1" \
    "$(printf '%s\n' "$_pp_body" \
        | grep -cE 'return[[:space:]]+"\$exit_code"' \
        || true)"

# ============================================================
echo ""
echo "=== 43. post_process.setup override ==="

# A heavy top-level setup can be skipped or replaced for the
# post-process pass: post_process.setup as a path runs that script,
# false/empty skips setup, and omitting the key inherits the
# top-level setup.  Mirrors the resolution in cmd_post_process.
resolve_pp_setup() {
    local config_file="$1"
    local top_setup pp_setup
    top_setup=$(jq -r '.setup // empty' "$config_file")
    if jq -e '(.post_process // {}) | has("setup")' "$config_file" \
            >/dev/null 2>&1; then
        pp_setup=$(jq -r '.post_process.setup // ""' "$config_file")
        [ "$pp_setup" = "false" ] && pp_setup=""
    else
        pp_setup="$top_setup"
    fi
    echo "$pp_setup"
}

cat > "$TMPDIR/pp_setup_inherit.json" <<'EOF'
{ "prompt": "p.md", "setup": "scripts/setup.sh",
  "post_process": { "prompt": "review.md" } }
EOF
assert_eq "pp setup inherits top-level" "scripts/setup.sh" \
    "$(resolve_pp_setup "$TMPDIR/pp_setup_inherit.json")"

cat > "$TMPDIR/pp_setup_path.json" <<'EOF'
{ "prompt": "p.md", "setup": "scripts/setup.sh",
  "post_process": { "prompt": "review.md", "setup": "scripts/light.sh" } }
EOF
assert_eq "pp setup path overrides" "scripts/light.sh" \
    "$(resolve_pp_setup "$TMPDIR/pp_setup_path.json")"

cat > "$TMPDIR/pp_setup_false.json" <<'EOF'
{ "prompt": "p.md", "setup": "scripts/setup.sh",
  "post_process": { "prompt": "review.md", "setup": false } }
EOF
assert_eq "pp setup false skips" "" \
    "$(resolve_pp_setup "$TMPDIR/pp_setup_false.json")"

cat > "$TMPDIR/pp_setup_empty.json" <<'EOF'
{ "prompt": "p.md", "setup": "scripts/setup.sh",
  "post_process": { "prompt": "review.md", "setup": "" } }
EOF
assert_eq "pp setup empty skips" "" \
    "$(resolve_pp_setup "$TMPDIR/pp_setup_empty.json")"

# The live function must wire pp_setup into both setup env vars.
_pp_setup_body=$(awk '
    /^cmd_post_process\(\)[[:space:]]*\{/ { p = 1 }
    p { print }
    p && /^\}[[:space:]]*$/ { exit }
' "$_LAUNCH_SH")
assert_eq "cmd_post_process passes pp_setup to SWARM_SETUP" "1" \
    "$(printf '%s\n' "$_pp_setup_body" \
        | grep -cF 'SWARM_SETUP=${pp_setup}' || true)"
assert_eq "cmd_post_process passes pp_setup to SWARM_CFG_SETUP" "1" \
    "$(printf '%s\n' "$_pp_setup_body" \
        | grep -cF 'SWARM_CFG_SETUP=${pp_setup}' || true)"

# ============================================================
echo "=== 44. Pi timeout/retry overrides reach every container ==="
# Each docker-run path (start, interactive, post-process) must forward
# PI_HTTP_IDLE_TIMEOUT_MS and PI_MAX_RETRIES when set on the host.
for _fn in cmd_start cmd_interactive cmd_post_process; do
    _pi_fwd=$(awk -v fn="$_fn" '
        $0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { p = 1; next }
        p && /^\}[[:space:]]*$/ { p = 0 }
        p && /for _pv in PI_HTTP_IDLE_TIMEOUT_MS PI_MAX_RETRIES/ { c++ }
        END { print c + 0 }
    ' "$_LAUNCH_SH")
    assert_eq "${_fn} forwards Pi overrides" "1" "$_pi_fwd"
done

# Mirrors the EXTRA_ENV loop: unset variables add nothing, set ones
# become -e pairs.
_pi_env_mirror() {
    local -a EXTRA_ENV=() _pv
    for _pv in PI_HTTP_IDLE_TIMEOUT_MS PI_MAX_RETRIES \
            PI_COMPACTION_RESERVE_TOKENS; do
        [ -n "${!_pv:-}" ] && EXTRA_ENV+=(-e "${_pv}=${!_pv}")
    done
    echo "${EXTRA_ENV[*]+"${EXTRA_ENV[*]}"}"
}
assert_eq "no Pi overrides by default" "" \
    "$(PI_HTTP_IDLE_TIMEOUT_MS='' PI_MAX_RETRIES='' _pi_env_mirror)"
assert_eq "idle timeout forwarded" "-e PI_HTTP_IDLE_TIMEOUT_MS=1800000" \
    "$(PI_HTTP_IDLE_TIMEOUT_MS=1800000 PI_MAX_RETRIES='' _pi_env_mirror)"
assert_eq "both overrides forwarded" \
    "-e PI_HTTP_IDLE_TIMEOUT_MS=0 -e PI_MAX_RETRIES=2" \
    "$(PI_HTTP_IDLE_TIMEOUT_MS=0 PI_MAX_RETRIES=2 _pi_env_mirror)"
assert_eq "compaction reserve forwarded" \
    "-e PI_COMPACTION_RESERVE_TOKENS=65536" \
    "$(PI_HTTP_IDLE_TIMEOUT_MS='' PI_MAX_RETRIES='' \
        PI_COMPACTION_RESERVE_TOKENS=65536 _pi_env_mirror)"
for _fn in cmd_start cmd_interactive cmd_post_process; do
    assert_eq "${_fn} forwards the compaction reserve" "1" \
        "$(awk -v fn="$_fn" '
            $0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { p = 1; next }
            p && /^\}[[:space:]]*$/ { p = 0 }
            p && /^ *PI_COMPACTION_RESERVE_TOKENS; do$/ { c++ }
            END { print c + 0 }' "$_LAUNCH_SH")"
done

# ============================================================
echo ""
echo "=== 44. mirror_volume_args keeps each mount whole ==="

# Source the live helper.  Mounts used to go through a text file that
# was re-read with word splitting, so a space split one mount into
# several docker arguments.
_mva_fn="$TMPDIR/mirror_volume_args.sh"
awk '/^mirror_volume_args\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { exit }' \
    "$_LAUNCH_SH" > "$_mva_fn"
# shellcheck source=/dev/null
source "$_mva_fn"

_mva_sub="$TMPDIR/mva-sub"
_mva_top="$TMPDIR/mva-top"
git init -q "$_mva_sub"
git -C "$_mva_sub" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m init
git init -q "$_mva_top"
git -C "$_mva_top" -c protocol.file.allow=always \
    submodule add -q "$_mva_sub" "lib space" 2>/dev/null
git -C "$_mva_top" -c protocol.file.allow=always \
    submodule add -q "$_mva_sub" "no-mirror" 2>/dev/null

# The runtime directory lives under $HOME, which can contain a space.
_mva_mirrors="$TMPDIR/state dir/mirrors"
_mva_mirror="${_mva_mirrors}/lib space.git"
mkdir -p "$_mva_mirror"
_mva_out=$(
    MIRROR_DIR="$_mva_mirrors"
    REPO_ROOT="$_mva_top"
    mirror_volume_args
    printf '<%s>\n' "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}"
)

assert_eq "spaces in the path and the name stay in one mount" \
    "<-v>
<${_mva_mirror}:/mirrors/lib space:ro>" "$_mva_out"

_mva_plain="$TMPDIR/mva-plain"
git init -q "$_mva_plain"
_mva_rc=0
_mva_out=$(
    MIRROR_DIR="$_mva_mirrors"
    REPO_ROOT="$_mva_plain"
    mirror_volume_args
    printf '%s' "${#MIRROR_ARGS[@]}"
) || _mva_rc=$?
assert_eq "no submodules: success" "0" "$_mva_rc"
assert_eq "no submodules: no mounts" "0" "$_mva_out"

# A failed submodule listing must stop the launch instead of starting
# containers without their mirrors.
mkdir -p "$TMPDIR/mva-not-a-repo"
_mva_rc=0
(
    MIRROR_DIR="$_mva_mirrors"
    REPO_ROOT="$TMPDIR/mva-not-a-repo"
    mirror_volume_args
) >/dev/null 2>&1 || _mva_rc=$?
assert_eq "failed submodule listing returns an error" "1" "$_mva_rc"

# ============================================================
echo ""
echo "=== 45. No fixed /tmp paths in the engine scripts ==="

# Fixed names in /tmp can be created or read by another local user.
# Transient files come from mktemp and the rest lives in the runtime
# directory; only lib/project.sh names the legacy /tmp paths.
_root="$TESTS_DIR/.."
assert_eq "no fixed /tmp paths" "" \
    "$(grep -n '/tmp/' \
        "$_root/launch.sh" "$_root/harvest.sh" "$_root/dashboard.sh" \
        "$_root/costs.sh" "$_root/progress.sh" || true)"

# ============================================================
echo ""
echo "=== 46. Recovery hints quote the bare repo path ==="

# A bare repo whose agent-work is behind the checkout's HEAD (stale):
# interactive refuses and points to cleanup, with no removal command,
# even in a runtime directory with shell metacharacters in its path.
_hint_fn="$TMPDIR/ensure_bare_repo_for_interactive.sh"
awk '/^ensure_bare_repo_for_interactive\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { exit }' \
    "$_LAUNCH_SH" > "$_hint_fn"
# shellcheck source=/dev/null
source "$_hint_fn"

_hint_repo="$TMPDIR/hint-repo"
_hint_bare="$TMPDIR/"'run $HOME "q"/upstream.git'
git init -q "$_hint_repo"
git -C "$_hint_repo" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m one
git clone -q --bare "$_hint_repo" "$_hint_bare"
git -C "$_hint_bare" branch agent-work HEAD
git -C "$_hint_repo" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m two
_hint_out=$(
    cd "$_hint_repo"
    RUNTIME_DIR="$(dirname "$_hint_bare")"
    BARE_REPO="$_hint_bare"
    STATE_FILE="$TMPDIR/hint-state.json"
    printf '%s\n' '{"schema":"swarm-core.state/v1","engagement_id":"e1",
        "engagement_token":"t1","docker_daemon":"d1"}' > "$STATE_FILE"
    # Called by the engagement's daemon check.
    # shellcheck disable=SC2329
    docker() {
        # (Patterns with their opening parenthesis: Bash 3.2 cannot
        # parse a case inside $(...) otherwise.)
        case "$1 ${2:-}" in
            ("info -f") echo d1 ;;
            ("context show") echo default ;;
        esac
    }
    ensure_bare_repo_for_interactive 2>&1
) || true
assert_eq "a stale bare repo: refused as stale" "1" \
    "$(printf '%s\n' "$_hint_out" | grep -c 'is stale (agent-work' || true)"
assert_eq "a stale bare repo: the hint names cleanup" "1" \
    "$(printf '%s\n' "$_hint_out" | grep -c 'launch.sh cleanup' || true)"
assert_eq "and offers no removal command" "0" \
    "$(printf '%s\n' "$_hint_out" | grep -cE 'docker run|rm -rf' || true)"

# ============================================================
echo ""
echo "=== 47. write_state_file writes JSON state ==="

# The old env-format file broke on a quote in the title and ran any
# $(...) in it when the dashboard sourced it.
_wsf_fn="$TMPDIR/write_state_file.sh"
awk '/^write_state_file\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { exit }' \
    "$_LAUNCH_SH" > "$_wsf_fn"
# shellcheck source=/dev/null
source "$_wsf_fn"

_wsf_dir="$TMPDIR/wsf"
mkdir -m 700 "$_wsf_dir"
cat > "$_wsf_dir/swarm.json" <<'EOF'
{ "title": "say \"hi\" $(touch pwned)",
  "prompt": "prompts/task.md",
  "agents": [{ "count": 2, "model": "claude-opus-4-6" }] }
EOF
_wsf_out=$(
    CONFIG_FILE="$_wsf_dir/swarm.json"
    NUM_AGENTS=2
    PROJECT="proj"
    STATE_FILE="$_wsf_dir/state.json"
    SWARM_TITLE=""
    write_state_file && cat "$STATE_FILE"
)
assert_eq "state schema" "swarm-core.state/v1" \
    "$(jq -r .schema <<< "$_wsf_out")"
assert_eq "title is kept verbatim" 'say "hi" $(touch pwned)' \
    "$(jq -r .title <<< "$_wsf_out")"
assert_eq "swarmfile path" "$_wsf_dir/swarm.json" \
    "$(jq -r .config <<< "$_wsf_out")"
assert_eq "num_agents is a number" "number" \
    "$(jq -r '.num_agents | type' <<< "$_wsf_out")"
assert_eq "model summary" "2x claude-opus-4-6" \
    "$(jq -r .model_summary <<< "$_wsf_out")"
assert_eq "config label" "swarm.json" \
    "$(jq -r .config_label <<< "$_wsf_out")"
assert_eq "state file is mode 600" "600" \
    "$(swarm_file_mode "$_wsf_dir/state.json")"

# ============================================================
echo ""
echo "=== 48. start from a subdirectory with a relative SWARM_CONFIG ==="

# start changes into the repository root before it reads the swarmfile
# again, so a relative SWARM_CONFIG has to be resolved first.  A fake
# docker accepts every call; git, jq and the runtime directory are real.
_st_bin="$TMPDIR/start-bin"
_st_repo="$TMPDIR/start-repo"
_st_rt="$TMPDIR/start-runtime"
mkdir -p "$_st_bin" "$_st_repo/sub/configs"
# Like the real CLI, inspecting a missing container fails, and info and
# context show answer.
cat > "$_st_bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = volume ] && exec "$FAKE_DOCKER_VOLUME" "$@"
if [ "$1 $2" = "container inspect" ]; then
    echo "Error: No such container: ${*: -1}" >&2
    exit 1
fi
[ "$1" = info ] && echo d1
[ "$1 $2" = "context show" ] && echo default
exit 0
EOF
chmod +x "$_st_bin/docker"
git init -q "$_st_repo"
echo "Prompt." > "$_st_repo/prompt.md"
cat > "$_st_repo/sub/configs/swarm.json" <<'EOF'
{ "prompt": "prompt.md", "title": "start test", "driver": "fake",
  "agents": [{ "count": 1, "model": "fake" }] }
EOF
git -C "$_st_repo" add -A
git -C "$_st_repo" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q -m init
_st_rc=0
_st_out=$(cd "$_st_repo/sub" \
    && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_st_rt" \
        SWARM_CONFIG=configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" start 2>&1) || _st_rc=$?
assert_eq "start succeeds" "0" "$_st_rc"
assert_eq "runtime directory is private" "700" \
    "$(swarm_file_mode "$_st_rt" 2>/dev/null)"
assert_eq "bare repo is in the runtime directory" "true" \
    "$([ -d "$_st_rt/upstream.git" ] && echo true || echo false)"
assert_eq "state records the absolute swarmfile path" \
    "$(cd "$_st_repo/sub/configs" && pwd -P)/swarm.json" \
    "$(jq -r .config "$_st_rt/state.json" 2>/dev/null)"
assert_eq "state records the title" "start test" \
    "$(jq -r .title "$_st_rt/state.json" 2>/dev/null)"
assert_eq "start prints the runtime directory" "true" \
    "$(grep -qF "Runtime:   ${_st_rt}" <<< "$_st_out" \
        && echo true || echo false)"
# With CDPATH set, cd prints where it went, which must not end up in
# the resolved swarmfile path.
_st_rc=0
(cd "$_st_repo/sub" \
    && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_st_rt" CDPATH=. \
        SWARM_CONFIG=configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" status >/dev/null 2>&1) || _st_rc=$?
assert_eq "CDPATH does not change the swarmfile path" "0" "$_st_rc"

# A symlink followed by ".." resolves on the physical path, as the
# existence check does, not on the spelled one.
mkdir -p "$_st_repo/other/inner"
sed 's/start test/physical/' "$_st_repo/sub/configs/swarm.json" \
    > "$_st_repo/other/swarm.json"
sed 's/start test/logical/' "$_st_repo/sub/configs/swarm.json" \
    > "$_st_repo/sub/swarm.json"
ln -s "$_st_repo/other/inner" "$_st_repo/sub/link"
_st_rt2="$TMPDIR/start-runtime-2"
_st_rc=0
(cd "$_st_repo/sub" \
    && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_st_rt2" \
        SWARM_CONFIG=link/../swarm.json SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" start >/dev/null 2>&1) || _st_rc=$?
assert_eq "start through symlink/.. succeeds" "0" "$_st_rc"
assert_eq "symlink/.. picks the physical swarmfile" "physical" \
    "$(jq -r .title "$_st_rt2/state.json" 2>/dev/null)"

# A directory name may end in a newline; dirname and command
# substitution would drop it and pick configs/ instead.
_st_nl_dir="$_st_repo/sub/configs"$'\n'
mkdir -p "$_st_nl_dir"
sed 's/start test/newline dir/' "$_st_repo/sub/configs/swarm.json" \
    > "$_st_nl_dir/swarm.json"
_st_rt3="$TMPDIR/start-runtime-3"
_st_rc=0
(cd "$_st_repo/sub" \
    && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_st_rt3" \
        SWARM_CONFIG=$'configs\n/swarm.json' SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" start >/dev/null 2>&1) || _st_rc=$?
assert_eq "start with a newline in the directory name succeeds" "0" \
    "$_st_rc"
assert_eq "the swarmfile in 'configs<LF>' is used" "newline dir" \
    "$(jq -r .title "$_st_rt3/state.json" 2>/dev/null)"

# Every container start passes the owner label.
_lbl_bin="$TMPDIR/label-bin"
_lbl_log="$TMPDIR/label-docker.log"
mkdir -p "$_lbl_bin"
: > "$_lbl_log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"
[ "$1" = volume ] && exec "$FAKE_DOCKER_VOLUME" "$@"
[ "$1" = info ] && { echo d1; exit 0; }
[ "$1 $2" = "context show" ] && { echo default; exit 0; }
[ "$1 $2" = "container inspect" ] && exit 1\nexit 0\n' \
    "$_lbl_log" > "$_lbl_bin/docker"
chmod +x "$_lbl_bin/docker"
(cd "$_st_repo/sub" \
    && PATH="$_lbl_bin:$PATH" SWARM_RUNTIME_DIR="$TMPDIR/label-runtime" \
        SWARM_CONFIG=configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" start >/dev/null 2>&1) || true
_lbl_want="--label swarm-core.checkout=$(cd -P "$_st_repo" && pwd -P)"
assert_eq "docker run carries the checkout label" "1" \
    "$(grep '^run ' "$_lbl_log" | grep -cF -- "$_lbl_want" || true)"
assert_eq "docker run carries the project label" "1" \
    "$(grep '^run ' "$_lbl_log" \
        | grep -cF -- '--label swarm-core.project=start-repo' || true)"

# ============================================================
echo ""
echo "=== 49. A second checkout with the same name is refused ==="

# Two checkouts named start-repo resolve to the same project id, so the
# second may not touch the first one's runtime, image or containers.
_id_state="$TMPDIR/id-state"
_id_a="$TMPDIR/id-a/start-repo"
_id_b="$TMPDIR/id-b/start-repo"
mkdir -p "$TMPDIR/id-a" "$TMPDIR/id-b" "$_id_state"
for _id_repo in "$_id_a" "$_id_b"; do
    git clone -q "$_st_repo" "$_id_repo"
done
run_launch() {
    local repo="$1"
    shift
    (cd "$repo" && env -u SWARM_RUNTIME_DIR PATH="$_st_bin:$PATH" \
        XDG_STATE_HOME="$_id_state" SWARM_CONFIG=sub/configs/swarm.json \
        SWARM_SKIP_DEP_CHECK=1 "$@" bash "$_LAUNCH_SH" status 2>&1)
}
_id_rc=0
(cd "$_id_a" && env -u SWARM_RUNTIME_DIR PATH="$_st_bin:$PATH" \
    XDG_STATE_HOME="$_id_state" SWARM_CONFIG=sub/configs/swarm.json \
    SWARM_SKIP_DEP_CHECK=1 bash "$_LAUNCH_SH" start >/dev/null 2>&1) \
    || _id_rc=$?
assert_eq "first checkout starts" "0" "$_id_rc"
_id_rc=0
_id_out=$(run_launch "$_id_b") || _id_rc=$?
assert_eq "second checkout is refused" "1" "$_id_rc"
assert_eq "the refusal names SWARM_PROJECT" "true" \
    "$(grep -q SWARM_PROJECT <<< "$_id_out" \
        && echo true || echo false)"
_id_rc=0
run_launch "$_id_b" SWARM_PROJECT=start-repo-b >/dev/null || _id_rc=$?
assert_eq "SWARM_PROJECT gives it its own id" "0" "$_id_rc"
_id_rc=0
run_launch "$_id_a" >/dev/null || _id_rc=$?
assert_eq "the owner still works" "0" "$_id_rc"

# A separate runtime directory does not make container names separate:
# with A's agent container present, B (same id, its own runtime) must
# not start and must not remove the container.
_id_bin="$TMPDIR/id-bin"
_id_log="$TMPDIR/id-docker.log"
mkdir -p "$_id_bin"
: > "$_id_log"
cat > "$_id_bin/docker" <<EOF
#!/bin/bash
[ "\$1" = volume ] && exec "\$FAKE_DOCKER_VOLUME" "\$@"
[ "\$1" = info ] && { echo d1; exit 0; }
[ "\$1 \$2" = "context show" ] && { echo default; exit 0; }
echo "\$*" >> "$_id_log"
if [ "\$1" = ps ]; then
    jq -nc --arg o "$(cd -P "$_id_a" && pwd -P)" \
        '{name: "start-repo-agent-1", project: "start-repo", owner: \$o}'
fi
[ "\$1 \$2" = "container inspect" ] && exit 1
exit 0
EOF
chmod +x "$_id_bin/docker"
_id_rc=0
(cd "$_id_b" && PATH="$_id_bin:$PATH" \
    SWARM_RUNTIME_DIR="$TMPDIR/id-b-runtime" \
    SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
    bash "$_LAUNCH_SH" start >/dev/null 2>&1) || _id_rc=$?
assert_eq "B with its own runtime is refused by A's container" "1" \
    "$_id_rc"
assert_eq "B removes no container" "0" \
    "$(grep -c '^rm ' "$_id_log" || true)"
assert_eq "B creates no runtime directory" "false" \
    "$([ -e "$TMPDIR/id-b-runtime" ] && echo true || echo false)"

# The container can also appear after the check at the top (builds take
# minutes): the listing is empty, but by the time start reuses the name
# another checkout owns it.  start must not remove it.
cat > "$_id_bin/docker" <<EOF
#!/bin/bash
[ "\$1" = volume ] && exec "\$FAKE_DOCKER_VOLUME" "\$@"
[ "\$1" = info ] && { echo d1; exit 0; }
[ "\$1 \$2" = "context show" ] && { echo default; exit 0; }
# Docker refuses to make a container under a name another one holds.
if [ "\$1" = run ]; then
    echo "run refused: the name is in use" >> "$_id_log"
    echo "docker: Error response from daemon: Conflict." >&2
    exit 125
fi
echo "\$*" >> "$_id_log"
if [ "\$1 \$2" = "container inspect" ]; then
    jq -nc --arg o "/elsewhere/start-repo" \
        '{id: "late-id", labels: {"swarm-core.checkout": \$o,
                                  "swarm-core.project": "start-repo"}}'
fi
exit 0
EOF
: > "$_id_log"
_id_rc=0
(cd "$_id_b" && PATH="$_id_bin:$PATH" \
    SWARM_RUNTIME_DIR="$TMPDIR/id-b-runtime-2" \
    SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
    bash "$_LAUNCH_SH" start >/dev/null 2>&1) || _id_rc=$?
assert_eq "a container that appears later stops start" "1" \
    "$([ "$_id_rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "the late container is not removed" "0" \
    "$(grep -c '^rm ' "$_id_log" || true)"
assert_eq "no agent container is started" "0" \
    "$(grep -v '^run refused' "$_id_log" | grep -c '^run ' || true)"

# A container of another project can hold one of the names commands
# address (here start-repo-agent-1, labeled for project "other").
# logs, status and wait must not read it.
cat > "$_id_bin/docker" <<EOF
#!/bin/bash
[ "\$1" = volume ] && exec "\$FAKE_DOCKER_VOLUME" "\$@"
[ "\$1" = info ] && { echo d1; exit 0; }
[ "\$1 \$2" = "context show" ] && { echo default; exit 0; }
echo "\$*" >> "$_id_log"
if [ "\$1 \$2" = "container inspect" ]; then
    jq -nc '{id: "other-id", labels: {"swarm-core.project": "other",
                                      "swarm-core.checkout": "/x"}}'
fi
exit 0
EOF
run_named() {
    (cd "$_id_a" && PATH="$_id_bin:$PATH" XDG_STATE_HOME="$_id_state" \
        SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        bash "$_LAUNCH_SH" "$@" 2>&1)
}
: > "$_id_log"
_id_rc=0
run_named logs 1 >/dev/null || _id_rc=$?
assert_eq "logs refuses another project's container" "1" "$_id_rc"
assert_eq "logs reads nothing from it" "0" \
    "$(grep -c '^logs ' "$_id_log" || true)"
assert_eq "status marks it as not ours" "true" \
    "$(status_output=$(run_named status) &&
        grep -q 'start-repo-agent-1: *not ours' <<< "$status_output" \
        && echo true || echo false)"
assert_eq "status reads nothing from it" "0" \
    "$(grep -c '^inspect ' "$_id_log" || true)"

# ============================================================
echo ""
echo "=== 50. Engagement id ==="

# start records the engagement of the new bare repo; later phases
# refuse a different SWARM_ENGAGEMENT_ID.
assert_eq "start records a generated engagement id" "true" \
    "$(engagement_id=$(jq -r .engagement_id "$_st_rt/state.json" \
        2>/dev/null) &&
        grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' <<< "$engagement_id" \
        && echo true || echo false)"
_eng_rt="$TMPDIR/eng-runtime"
run_eng() {
    (cd "$_st_repo" && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_eng_rt" \
        SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        "$@" 2>&1)
}
_eng_rc=0
run_eng env SWARM_ENGAGEMENT_ID=eng-1 bash "$_LAUNCH_SH" start \
    >/dev/null || _eng_rc=$?
assert_eq "start with SWARM_ENGAGEMENT_ID succeeds" "0" "$_eng_rc"
assert_eq "start records SWARM_ENGAGEMENT_ID" "eng-1" \
    "$(jq -r .engagement_id "$_eng_rt/state.json" 2>/dev/null)"
_eng_rc=0
run_eng env SWARM_ENGAGEMENT_ID=eng-2 bash "$_LAUNCH_SH" interactive \
    --agent-index 1 >/dev/null || _eng_rc=$?
assert_eq "interactive refuses another engagement" "1" "$_eng_rc"
_eng_rc=0
run_eng env SWARM_ENGAGEMENT_ID=eng-1 bash "$_LAUNCH_SH" interactive \
    --agent-index 1 >/dev/null || _eng_rc=$?
assert_eq "interactive joins the recorded engagement" "0" "$_eng_rc"
_eng_rc=0
run_eng env SWARM_ENGAGEMENT_ID="bad id" bash "$_LAUNCH_SH" status \
    >/dev/null || _eng_rc=$?
assert_eq "a malformed SWARM_ENGAGEMENT_ID is refused" "1" "$_eng_rc"
_eng_rc=0
run_eng env SWARM_ENGAGEMENT_ID= bash "$_LAUNCH_SH" status \
    >/dev/null || _eng_rc=$?
assert_eq "an empty SWARM_ENGAGEMENT_ID is refused" "1" "$_eng_rc"
_eng_log="$TMPDIR/eng-docker.log"
_eng_bin="$TMPDIR/eng-bin"
mkdir -p "$_eng_bin"
printf '#!/bin/bash\necho "$*" >> "%s"
[ "$1" = volume ] && exec "$FAKE_DOCKER_VOLUME" "$@"
[ "$1" = info ] && { echo d1; exit 0; }
[ "$1 $2" = "context show" ] && { echo default; exit 0; }
[ "$1 $2" = "container inspect" ] && exit 1\nexit 0\n' \
    "$_eng_log" > "$_eng_bin/docker"
chmod +x "$_eng_bin/docker"
: > "$_eng_log"
_eng_rc=0
run_eng env PATH="$_eng_bin:$PATH" SWARM_ENGAGEMENT_ID=eng-2 \
    bash "$_LAUNCH_SH" stop >/dev/null || _eng_rc=$?
assert_eq "stop refuses another engagement" "1" "$_eng_rc"
assert_eq "stop stops nothing then" "0" \
    "$(grep -c '^stop ' "$_eng_log" || true)"
_eng_rc=0
run_eng env PATH="$_eng_bin:$PATH" SWARM_ENGAGEMENT_ID=eng-2 \
    bash "$_LAUNCH_SH" wait >/dev/null || _eng_rc=$?
assert_eq "wait refuses another engagement" "1" "$_eng_rc"

# ============================================================
echo ""
echo "=== 51. Engagement lock ==="

# start fails at once while another operation holds the lock, before
# it touches the bare repo or Docker.
_lk_rt="$TMPDIR/lock-runtime"
_lk_log="$TMPDIR/lock-docker.log"
_lk_bin="$TMPDIR/lock-bin"
mkdir -p "$_lk_bin"
mkdir -m 700 "$_lk_rt"
cat > "$_lk_bin/docker" <<EOF
#!/bin/bash
[ "\$1" = volume ] && exec "\$FAKE_DOCKER_VOLUME" "\$@"
[ "\$1" = info ] && { echo d1; exit 0; }
[ "\$1 \$2" = "context show" ] && { echo default; exit 0; }
echo "\$*" >> "$_lk_log"
[ "\$1 \$2" = "container inspect" ] && exit 1
# docker run -it checks that the session record for its --name names
# its own pid (exec keeps launch.sh's) and logs its arguments, checks
# the lock while the session runs, prints a line and exits with
# FAKE_EXIT.  With FAKE_NEVER_RUNS the container never starts.
[ "\$1" = info ] && { echo d1; exit 0; }
[ "\$1 \$2" = "context show" ] && { echo default; exit 0; }
_it=false
for _a in "\$@"; do
    [ "\$_a" != -it ] || _it=true
done
if [ "\$1" = run ] && \$_it; then
    _name=""
    _prev=""
    for _a in "\$@"; do
        [ "\$_prev" = --name ] && _name="\$_a"
        _prev="\$_a"
    done
    if grep -qx "pid=\$\$" "$_lk_rt/interactive-\$_name.pending" 2>/dev/null
    then
        echo "record names the session" >> "$_lk_log"
    fi
    [ -n "\${FAKE_NEVER_RUNS:-}" ] && exit 3
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if flock -n 6 6>>"$_lk_rt/engagement.lock"; then
            echo "lock free during session" >> "$_lk_log"
            break
        fi
        sleep 0.1
    done
    echo "SESSION OUTPUT"
    exit "\${FAKE_EXIT:-0}"
fi
exit 0
EOF
chmod +x "$_lk_bin/docker"
run_lock() {
    (cd "$_st_repo" && PATH="$_lk_bin:$PATH" SWARM_RUNTIME_DIR="$_lk_rt" \
        SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        "$BASH" "$_LAUNCH_SH" "$@" 2>&1)
}
exec 8>>"$_lk_rt/engagement.lock"
flock -n 8
: > "$_lk_log"
_lk_rc=0
run_lock start 8>&- >/dev/null || _lk_rc=$?
assert_eq "start fails while the lock is held" "1" "$_lk_rc"
assert_eq "start creates no bare repo then" "false" \
    "$([ -e "$_lk_rt/upstream.git" ] && echo true || echo false)"
assert_eq "start runs no container then" "0" \
    "$(grep -c '^run ' "$_lk_log" || true)"
_lk_rc=0
(cd "$_st_repo" && PATH="$_lk_bin:$PATH" SWARM_RUNTIME_DIR="$_lk_rt" \
    SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
    SWARM_LOCK_FD=8 "$BASH" "$_LAUNCH_SH" start >/dev/null 2>&1) \
    || _lk_rc=$?
assert_eq "start with the holder's SWARM_LOCK_FD runs" "0" "$_lk_rc"
exec 8>&-

# An interactive session records itself under the lock, gives the lock
# up and execs docker run, which keeps the terminal and the exit status.
: > "$_lk_log"
_lk_rc=0
_lk_out=$(FAKE_EXIT=4 run_lock interactive --agent-index 1) || _lk_rc=$?
assert_eq "the session is recorded before docker run" "1" \
    "$(grep -c 'record names the session' "$_lk_log" || true)"
assert_eq "the lock is free once the container runs" "1" \
    "$(grep -c 'lock free during session' "$_lk_log" || true)"
assert_eq "the session's output reaches the terminal" "true" \
    "$(grep -q 'SESSION OUTPUT' <<< "$_lk_out" \
        && echo true || echo false)"
assert_eq "interactive returns the container's exit status" "4" "$_lk_rc"
# docker_args reach docker run unchanged, run-only options included,
# and a --name among them does not replace the recorded name: the fake
# takes the last --name, as Docker does, and checks its record.
_lk_cfg="$_st_repo/sub/configs/docker-args.json"
jq '. + {docker_args: ["--detach-keys=ctrl-x", "--label", "-itd",
    "--name", "custom-session"]}' \
    "$_st_repo/sub/configs/swarm.json" > "$_lk_cfg"
: > "$_lk_log"
(cd "$_st_repo" && PATH="$_lk_bin:$PATH" SWARM_RUNTIME_DIR="$_lk_rt" \
    SWARM_CONFIG=sub/configs/docker-args.json SWARM_SKIP_DEP_CHECK=1 \
    "$BASH" "$_LAUNCH_SH" interactive --agent-index 1 >/dev/null 2>&1) \
    || true
assert_eq "docker_args reach docker run unchanged, right after run" "1" \
    "$(grep -c -- \
        '^run --detach-keys=ctrl-x --label -itd --name custom-session -it ' \
        "$_lk_log" || true)"
assert_eq "the container gets the recorded name" "1" \
    "$(grep -c 'record names the session' "$_lk_log" || true)"
assert_eq "the session label follows docker_args too" "1" \
    "$(grep '^run ' "$_lk_log" | grep -cE -- \
        ' --name custom-session -it .* --name [^ ]+ --label swarm-core\.session=' \
        || true)"
rm -f "$_lk_cfg"

# A container that never starts: docker run fails, and the lock is
# already free.
: > "$_lk_log"
_lk_rc=0
FAKE_NEVER_RUNS=1 run_lock interactive --agent-index 1 >/dev/null \
    || _lk_rc=$?
assert_eq "a container that never starts fails interactive" "3" "$_lk_rc"
_lk_free=1
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if flock -n 6 6>>"$_lk_rt/engagement.lock"; then
        _lk_free=0
        break
    fi
    sleep 0.1
done
assert_eq "the lock is free soon after that" "0" "$_lk_free"
# A caller that reads the output to EOF before it reaps launch.sh, as
# Python's communicate() does, must get EOF once launch.sh is done: the
# helper may not keep the output pipe open.  perl reads like that; the
# alarm ends a hang after 20 s.
_lk_rc=0
(cd "$_st_repo" && PATH="$_lk_bin:$PATH" SWARM_RUNTIME_DIR="$_lk_rt" \
    SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
    FAKE_NEVER_RUNS=1 perl -e '
        alarm 20;
        open(my $p, "-|", @ARGV) or exit 9;
        local $/;
        my $out = <$p>;
        close $p;
        exit($? >> 8);
    ' "$BASH" "$_LAUNCH_SH" interactive --agent-index 1 2>/dev/null) \
    || _lk_rc=$?
assert_eq "a reader that waits for EOF gets it and the exit status" "3" \
    "$_lk_rc"

# start --dashboard execs the dashboard, which runs until closed; the
# lock must be released first.
assert_eq "start --dashboard unlocks before exec" "1" \
    "$(awk '/^    start\)/,/;;/' "$_LAUNCH_SH" \
        | grep -A1 'swarm_unlock' | grep -c 'exec "$SWARM_DIR/dashboard.sh"' \
        || true)"

# ============================================================
echo ""
echo "=== 52. A new bare repo records its base and drops old agent refs ==="

# The checkout has a stale local agent-work and branches in the
# namespaces harvest and the preservation checks read.  None of them may
# reach the new bare repo; agent-work and refs/swarm/base start at HEAD,
# and the state file records HEAD as the base.
_br_dir="$TMPDIR/base-refs"
_br_src="$_br_dir/src"
mkdir -p "$_br_dir"
git init -q "$_br_src"
_br_git() {
    git -C "$_br_src" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false "$@"
}
_br_git commit -q --allow-empty -m one
_br_old=$(git -C "$_br_src" rev-parse HEAD)
_br_git commit -q --allow-empty -m two
_br_head=$(git -C "$_br_src" rev-parse HEAD)
for _br_ref in refs/heads/agent-work refs/heads/swarm/abc/interactive-x \
        refs/heads/agent-parked/1-20260101T000000Z refs/swarm-runs/r1 \
        refs/heads/feature; do
    git -C "$_br_src" update-ref "$_br_ref" "$_br_old"
done
awk '$0 ~ /^(create_bare_repo|prepare_bare_repo|begin_engagement)\(\)[[:space:]]*\{/ { p = 1 }
     p { print }
     p && /^\}[[:space:]]*$/ { p = 0 }' "$_LAUNCH_SH" > "$_br_dir/funcs.sh"
_br_run() {
    (
        # shellcheck source=/dev/null
        source "$_br_dir/funcs.sh"
        # No Docker here: the daemon id is made up.
        # shellcheck disable=SC2329
        swarm_docker_daemon_id() { printf 'TEST:DAEMON'; }
        REPO_ROOT="$1"
        BARE_REPO="$_br_dir/bare-$2.git"
        STATE_FILE="$_br_dir/state-$2.json"
        create_bare_repo
    ) >/dev/null 2>&1
}
_br_rc=0
_br_run "$_br_src" 1 || _br_rc=$?
_br_bare="$_br_dir/bare-1.git"
assert_eq "bare repo is created" "0" "$_br_rc"
assert_eq "agent-work starts at HEAD, not the old local branch" \
    "$_br_head" "$(git -C "$_br_bare" rev-parse agent-work 2>/dev/null)"
assert_eq "refs/swarm/base is HEAD" "$_br_head" \
    "$(git -C "$_br_bare" rev-parse refs/swarm/base 2>/dev/null)"
assert_eq "the state file records HEAD as the base" "$_br_head" \
    "$(jq -r .base_commit "$_br_dir/state-1.json" 2>/dev/null)"
assert_eq "old interactive, parked and run refs are not copied" "" \
    "$(git -C "$_br_bare" for-each-ref --format='%(refname)' \
        refs/heads/swarm/ refs/heads/agent-parked/ refs/swarm-runs/)"
assert_eq "other branches are copied as before" "$_br_old" \
    "$(git -C "$_br_bare" rev-parse feature 2>/dev/null)"
assert_eq "the bare repo's HEAD is agent-work" "refs/heads/agent-work" \
    "$(git -C "$_br_bare" symbolic-ref HEAD 2>/dev/null)"
assert_eq "the state file records the Docker daemon" "TEST:DAEMON" \
    "$(jq -r .docker_daemon "$_br_dir/state-1.json" 2>/dev/null)"
assert_eq "and a token of 16 hex digits" "true" \
    "$(jq -r .engagement_token "$_br_dir/state-1.json" 2>/dev/null \
        | grep -qE '^[0-9a-f]{16}$' && echo true || echo false)"
assert_eq "no upstream.git.new is left" "false" \
    "$([ -e "$_br_bare.new" ] && echo true || echo false)"

# The engagement is recorded before the clone starts.  A failure while
# the clone is prepared must not leave a bare repo that later commands
# would join with old agent branches in it, nor the half-made clone:
# cleanup is the next step.  FAIL names the step that fails.
_br_fail() {
    local n="$1" fail="$2"
    (
        # shellcheck source=/dev/null
        source "$_br_dir/funcs.sh"
        # No Docker here: the daemon id is made up.
        # shellcheck disable=SC2329
        swarm_docker_daemon_id() { printf 'TEST:DAEMON'; }
        # shellcheck disable=SC2329
        git() {
            case "$fail $*" in
                "list "*" for-each-ref "*) return 128 ;;
                "delete "*" update-ref -d "*) return 128 ;;
            esac
            command git "$@"
        }
        if [ "$fail" = state ]; then
            # shellcheck disable=SC2329
            swarm_state_update() { return 1; }
        fi
        REPO_ROOT="$_br_src"
        BARE_REPO="$_br_dir/bare-$n.git"
        STATE_FILE="$_br_dir/state-$n.json"
        create_bare_repo
    ) >/dev/null 2>&1
}
for _br_case in 3:list:true 4:delete:true 5:state:false; do
    _br_n="${_br_case%%:*}"
    _br_step="${_br_case#*:}"
    _br_recorded="${_br_step#*:}"
    _br_step="${_br_step%%:*}"
    _br_rc=0
    _br_fail "$_br_n" "$_br_step" || _br_rc=$?
    assert_eq "$_br_step failure stops bare creation" "1" "$_br_rc"
    assert_eq "$_br_step failure leaves no bare repo to join" "false" \
        "$([ -e "$_br_dir/bare-$_br_n.git" ] && echo true || echo false)"
    assert_eq "$_br_step failure leaves no upstream.git.new" "false" \
        "$([ -e "$_br_dir/bare-$_br_n.git.new" ] && echo true || echo false)"
    assert_eq "$_br_step failure: engagement recorded is $_br_recorded" \
        "$_br_recorded" \
        "$([ -n "$(jq -r '.engagement_id // empty' \
            "$_br_dir/state-$_br_n.json" 2>/dev/null)" ] \
            && echo true || echo false)"
done

# A bare repo that is there already is refused, never replaced; so is
# an upstream.git.new that a run stopped half way left.
mkdir -p "$_br_dir/bare-6.git" "$_br_dir/bare-7.git.new"
touch "$_br_dir/bare-6.git/marker" "$_br_dir/bare-7.git.new/marker"
for _br_n in 6 7; do
    _br_rc=0
    _br_fail "$_br_n" none || _br_rc=$?
    assert_eq "an existing bare repo or .new ($_br_n) is refused" "1" \
        "$_br_rc"
    assert_eq "and records no engagement ($_br_n)" "false" \
        "$([ -e "$_br_dir/state-$_br_n.json" ] && echo true || echo false)"
done
assert_eq "the bare repo is left as it was" "true" \
    "$([ -e "$_br_dir/bare-6.git/marker" ] && echo true || echo false)"
assert_eq "so is the .new" "true" \
    "$([ -e "$_br_dir/bare-7.git.new/marker" ] && echo true || echo false)"
assert_eq "and no bare repo is made next to the .new" "false" \
    "$([ -e "$_br_dir/bare-7.git" ] && echo true || echo false)"

# A new engagement drops what harvests of an earlier one merged.
printf '%s\n' '{"schema":"swarm-core.state/v1",
    "harvested":["0123456789abcdef0123456789abcdef01234567"],
    "harvest_pending":["0123456789abcdef0123456789abcdef01234567"]}' \
    > "$_br_dir/state-9.json"
_br_run "$_br_src" 9 || true
assert_eq "a new engagement drops the record of harvests" "null null" \
    "$(jq -r '"\(.harvested) \(.harvest_pending)"' \
        "$_br_dir/state-9.json" 2>/dev/null)"

# A checkout without a commit has nothing to start from.
git init -q "$_br_dir/empty"
_br_rc=0
_br_run "$_br_dir/empty" 2 || _br_rc=$?
assert_eq "a checkout without commits is refused" "1" "$_br_rc"
assert_eq "no state is written for it" "false" \
    "$([ -e "$_br_dir/state-2.json" ] && echo true || echo false)"


# ============================================================
echo ""
echo "=== 53. Open interactive sessions keep the bare repo and the mirrors ==="

# The session record names a process and its start time.  It is live
# while that process runs; a record whose process is gone, or whose
# pid now belongs to a newer process, is removed.
_pd_dir="$TMPDIR/pending"
mkdir -p "$_pd_dir"
# The caller's Docker selectors would steer the stub below; the cases
# that set them come last.
unset DOCKER_CONTEXT DOCKER_HOST
# Docker's answers once a session's process is gone.  Two contexts: A
# (daemon PD_DAEMON) and B (daemon d2, where no session container
# exists).  The current context is in a file, as docker context use
# keeps it; DOCKER_CONTEXT overrides it.  With PD_SWITCH set, docker
# info switches the current context to B, as another terminal could.
# PD_STATE is the state of the container with the session's label on
# A, "gone" for none, "error" for a failed listing, "failed" for a
# created one whose start failed.  A lookup by name finds nothing, as
# after a rename of the detached container.
PD_STATE=gone
PD_DAEMON=d1
PD_SWITCH=""
_pd_ctx="$TMPDIR/pending-context"
echo A > "$_pd_ctx"
# shellcheck disable=SC2329
docker() {
    local ctx
    ctx="${DOCKER_CONTEXT:-$(cat "$_pd_ctx")}"
    if [ "$1 $2" = "context show" ]; then
        cat "$_pd_ctx"
        return 0
    fi
    if [ "$1" = info ]; then
        [ -z "$PD_SWITCH" ] || echo B > "$_pd_ctx"
        if [ "$ctx" = A ]; then echo "$PD_DAEMON"; else echo d2; fi
        return 0
    fi
    if [ "$1 $2 ${*: -1}" = "container inspect pd-c1" ] \
            && [ "$ctx" = A ]; then
        case "$PD_STATE" in
            failed) echo "created|port is already allocated" ;;
            *) echo "${PD_STATE}|" ;;
        esac
        return 0
    fi
    if [ "$1" != ps ]; then
        echo "Error: No such container: ${*: -1}" >&2
        return 1
    fi
    [ "$ctx" = A ] || return 0
    case "$PD_STATE" in
        gone) ;;
        error) echo "Cannot connect to the Docker daemon" >&2; return 1 ;;
        failed)
            case "$*" in
                *" label=swarm-core.session="*) echo "pd-c1 created" ;;
            esac ;;
        *)
            case "$*" in
                *" label=swarm-core.session="*) echo "pd-c1 $PD_STATE" ;;
            esac ;;
    esac
}
_pd_id_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_pd_id_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sleep 60 &
_pd_live=$!
sh -c 'exit 0' &
_pd_dead=$!
wait "$_pd_dead" 2>/dev/null || true
swarm_pending_write "$_pd_dir" "$_pd_id_a" "$_pd_live" d1
swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_dead" d1
assert_eq "the record names the pid" "pid=$_pd_live" \
    "$(grep '^pid=' "$_pd_dir/interactive-$_pd_id_a.pending")"
assert_eq "only the running session is live" "$_pd_id_a" \
    "$(swarm_pending_live "$_pd_dir")"
assert_eq "the record of the ended session is removed" "false" \
    "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
        && echo true || echo false)"
printf 'pid=%s\nstarted=Thu Jan  1 00:00:00 1970\ndaemon=d1\n' \
    "$_pd_live" > "$_pd_dir/interactive-$_pd_id_b.pending"
assert_eq "a pid with another start time is not the session" \
    "$_pd_id_a" "$(swarm_pending_live "$_pd_dir")"
assert_eq "its record is removed" "false" \
    "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
        && echo true || echo false)"
printf 'pid=x\n' > "$_pd_dir/interactive-$_pd_id_b.pending"
_pd_rc=0
swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
assert_eq "a record without a pid fails the check" "1" "$_pd_rc"
rm -f "$_pd_dir/interactive-$_pd_id_b.pending"
ln -s "$_pd_dir/interactive-$_pd_id_a.pending" \
    "$_pd_dir/interactive-$_pd_id_b.pending"
_pd_rc=0
swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
assert_eq "a symlinked record fails the check" "1" "$_pd_rc"
rm -f "$_pd_dir/interactive-$_pd_id_b.pending"
_pd_rc=0
swarm_pending_write "$_pd_dir" "-bad name" "$_pd_live" d1 2>/dev/null \
    || _pd_rc=$?
assert_eq "a malformed container name is not recorded" "1" "$_pd_rc"
printf 'pid=%s\nstarted=\ndaemon=d1\n' "$_pd_live" \
    > "$_pd_dir/interactive--x.pending"
_pd_rc=0
swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
assert_eq "a record whose file name is no container name fails" "1" \
    "$_pd_rc"
rm -f "$_pd_dir/interactive--x.pending"
_pd_rc=0
swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_live" "" 2>/dev/null \
    || _pd_rc=$?
assert_eq "a record without a daemon id is not written" "1" "$_pd_rc"

# The start time is read the same way whatever the caller's time zone
# and locale, so a live session is not taken for a reused pid.
TZ=UTC LC_ALL=C swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_live" d1
assert_eq "a session recorded in UTC is live from another zone" \
    "$_pd_id_a $_pd_id_b" \
    "$(TZ=Pacific/Kiritimati LC_TIME=fr_FR.UTF-8 \
        swarm_pending_live "$_pd_dir" | sort | tr '\n' ' ' | sed 's/ $//')"
rm -f "$_pd_dir/interactive-$_pd_id_b.pending"

# A session can detach and leave the container running, and the
# container can be renamed: the session is still open after its
# process ended, found by its label.
swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_dead" d1
PD_STATE=running
assert_eq "a detached session whose container runs stays open" \
    "$_pd_id_a $_pd_id_b" \
    "$(swarm_pending_live "$_pd_dir" | sort | tr '\n' ' ' | sed 's/ $//')"
PD_STATE=error
_pd_rc=0
swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
assert_eq "a container state Docker cannot give fails the check" "1" \
    "$_pd_rc"
assert_eq "and keeps the record" "true" \
    "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
        && echo true || echo false)"
# Container ids mean something only on their daemon: after a switch to
# another daemon, "no such container" proves nothing.
PD_STATE=gone
echo B > "$_pd_ctx"
_pd_rc=0
swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
assert_eq "a record from another Docker daemon fails the check" "1" \
    "$_pd_rc"
assert_eq "and stays" "true" \
    "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
        && echo true || echo false)"
# A switch between reading the daemon id and inspecting the container
# must not send the inspect to the other daemon.
echo A > "$_pd_ctx"
PD_STATE=running
PD_SWITCH=1
assert_eq "a context switch during the check keeps the session open" \
    "$_pd_id_a $_pd_id_b" \
    "$(swarm_pending_live "$_pd_dir" 2>/dev/null | sort | tr '\n' ' ' \
        | sed 's/ $//')"
PD_SWITCH=""
echo A > "$_pd_ctx"
assert_eq "the pin does not outlive the check" "unset" \
    "${DOCKER_CONTEXT-unset}"
# A created container can still start after its client died.
PD_STATE=created
assert_eq "a session whose container is only created stays open" \
    "$_pd_id_a $_pd_id_b" \
    "$(swarm_pending_live "$_pd_dir" | sort | tr '\n' ' ' | sed 's/ $//')"
# One whose start failed never runs: retire can take it.
PD_STATE=failed
assert_eq "a session whose container failed to start is closed" \
    "$_pd_id_a" "$(swarm_pending_live "$_pd_dir")"
swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_dead" d1
PD_STATE=exited
assert_eq "an ended session whose container exited is closed" \
    "$_pd_id_a" "$(swarm_pending_live "$_pd_dir")"
assert_eq "its record is removed" "false" \
    "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
        && echo true || echo false)"
PD_STATE=gone

# Records that are not exactly "pid=N" and "started=T" fail the check
# and stay, even with a live pid.
_pd_bad() {
    local label="$1" content="$2" rc=0
    printf '%s' "$content" > "$_pd_dir/interactive-$_pd_id_b.pending"
    swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || rc=$?
    assert_eq "$label fails the check" "1" "$rc"
    assert_eq "$label is kept" "true" \
        "$([ -e "$_pd_dir/interactive-$_pd_id_b.pending" ] \
            && echo true || echo false)"
    rm -f "$_pd_dir/interactive-$_pd_id_b.pending"
}
_pd_nl=$'\n'
_pd_ok_tail="started=${_pd_nl}daemon=d1${_pd_nl}"
_pd_bad "a garbage start time" \
    "pid=$_pd_live${_pd_nl}started=garbage${_pd_nl}daemon=d1${_pd_nl}"
_pd_bad "a garbage day" "pid=$_pd_live${_pd_nl}started=Thu Jan garbage\
 00:00:00 1970${_pd_nl}daemon=d1${_pd_nl}"
_pd_bad "a second start time" "pid=$_pd_live${_pd_nl}started=${_pd_nl}\
started=Thu Jan  1 00:00:00 1970${_pd_nl}daemon=d1${_pd_nl}"
_pd_bad "an extra line" "pid=$_pd_live${_pd_nl}${_pd_ok_tail}other=1${_pd_nl}"
_pd_bad "a missing start line" "pid=$_pd_live${_pd_nl}daemon=d1${_pd_nl}"
_pd_bad "a missing daemon line" "pid=$_pd_live${_pd_nl}started=${_pd_nl}"
_pd_bad "a garbage daemon id" \
    "pid=$_pd_live${_pd_nl}started=${_pd_nl}daemon=a b${_pd_nl}"
_pd_bad "a second pid" "pid=$_pd_live${_pd_nl}pid=1${_pd_nl}${_pd_ok_tail}"
_pd_bad "trailing blank lines" \
    "pid=$_pd_live${_pd_nl}${_pd_ok_tail}${_pd_nl}${_pd_nl}"
_pd_bad "no final newline" "pid=$_pd_live${_pd_nl}started=${_pd_nl}daemon=d1"
# Root reads any file, so the unreadable case needs another user.
if [ "$(id -u)" != 0 ]; then
    printf 'pid=%s\n%s' "$_pd_live" "$_pd_ok_tail" \
        > "$_pd_dir/interactive-$_pd_id_b.pending"
    chmod 000 "$_pd_dir/interactive-$_pd_id_b.pending"
    _pd_rc=0
    swarm_pending_live "$_pd_dir" >/dev/null 2>&1 || _pd_rc=$?
    assert_eq "an unreadable record fails the check" "1" "$_pd_rc"
    chmod 600 "$_pd_dir/interactive-$_pd_id_b.pending"
    rm -f "$_pd_dir/interactive-$_pd_id_b.pending"
fi

# A selector the caller set already pins the daemon: DOCKER_CONTEXT is
# kept, DOCKER_HOST is left alone.  Docker allows "+" in context names.
# Print the context swarm_docker_pin leaves, or "unset".
_pd_pinned() {
    swarm_docker_pin && printf '%s' "${DOCKER_CONTEXT-unset}"
}
echo dev+local > "$_pd_ctx"
assert_eq "a context name with + is pinned" "dev+local" "$(_pd_pinned)"
echo B > "$_pd_ctx"
assert_eq "a caller's DOCKER_CONTEXT is kept" "A" \
    "$(DOCKER_CONTEXT=A _pd_pinned)"
assert_eq "with DOCKER_HOST no context is pinned" "unset" \
    "$(DOCKER_HOST=unix:///x _pd_pinned)"
# With the caller's DOCKER_CONTEXT=A, a context switch of the current
# context changes nothing either.
echo A > "$_pd_ctx"
swarm_pending_write "$_pd_dir" "$_pd_id_b" "$_pd_dead" d1
PD_STATE=running
PD_SWITCH=1
assert_eq "with the caller's DOCKER_CONTEXT a switch keeps it open" \
    "$_pd_id_a $_pd_id_b" \
    "$(DOCKER_CONTEXT=A swarm_pending_live "$_pd_dir" 2>/dev/null \
        | sort | tr '\n' ' ' | sed 's/ $//')"
PD_SWITCH=""
PD_STATE=gone
echo A > "$_pd_ctx"
rm -f "$_pd_dir/interactive-$_pd_id_b.pending"

unset -f docker

# Every place that creates a bare repo checks for a clean runtime
# (which counts open sessions) first, then builds the image, and
# interactive mirrors only when it creates the bare repo.
assert_eq "each bare repo creation checks for a clean runtime" "3" \
    "$(grep -B2 '^ *create_bare_repo "' "$_LAUNCH_SH" \
        | grep -c '^ *require_clean_runtime$')"
assert_eq "and builds the image between the two" "3" \
    "$(grep -B1 '^ *create_bare_repo "' "$_LAUNCH_SH" \
        | grep -c '^ *build_image$')"
assert_eq "cmd_interactive mirrors only through the bare repo step" "0" \
    "$(printf '%s\n' "$CMD_INTERACTIVE_BODY" \
        | grep -c 'mirror_submodules' || true)"

# Every bare repo creation mirrors the submodules.  A joining session
# adds missing mirrors and leaves existing ones alone.
assert_eq "each bare repo creation mirrors the submodules" "3" \
    "$(grep -A3 '^ *create_bare_repo "' "$_LAUNCH_SH" \
        | grep -c '^ *mirror_submodules$')"
_mm_dir="$TMPDIR/mirror-missing"
mkdir -p "$_mm_dir"
git init -q "$_mm_dir/sub"
git -C "$_mm_dir/sub" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m sub
git init -q "$_mm_dir/src"
git -C "$_mm_dir/src" -c protocol.file.allow=always submodule add -q \
    "$_mm_dir/sub" lib >/dev/null 2>&1
git -C "$_mm_dir/src" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q -m add-sub
for _mm_fn in engagement_base mirror_submodules; do
    awk -v fn="$_mm_fn" '$0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { p = 1 }
         p { print }
         p && /^\}[[:space:]]*$/ { exit }' "$_LAUNCH_SH"
done > "$_mm_dir/funcs.sh"
# The engagement's base, as begin_engagement records it.
jq -n --arg schema "$SWARM_STATE_SCHEMA" \
    --arg base "$(git -C "$_mm_dir/src" rev-parse HEAD)" \
    '{schema: $schema, base_commit: $base}' > "$_mm_dir/state.json"
_mm_run() {
    (
        # shellcheck source=/dev/null
        source "$_mm_dir/funcs.sh"
        REPO_ROOT="$_mm_dir/src"
        MIRROR_DIR="$_mm_dir/mirrors"
        STATE_FILE="$_mm_dir/state.json"
        mirror_submodules "$@"
    ) >/dev/null 2>&1
}
_mm_run
assert_eq "the submodule is mirrored" "true" \
    "$([ -d "$_mm_dir/mirrors/lib.git" ] && echo true || echo false)"
touch "$_mm_dir/mirrors/lib.git/keep"
_mm_run missing
assert_eq "a joining session leaves an existing mirror alone" "true" \
    "$([ -e "$_mm_dir/mirrors/lib.git/keep" ] && echo true || echo false)"
rm -rf "$_mm_dir/mirrors/lib.git"
_mm_run missing
assert_eq "a joining session adds a missing mirror" "true" \
    "$(git -C "$_mm_dir/mirrors/lib.git" rev-parse --is-bare-repository \
        2>/dev/null || echo false)"
assert_eq "a mirror is made under .new and then renamed" "false" \
    "$([ -e "$_mm_dir/mirrors/lib.git.new" ] && echo true || echo false)"
touch "$_mm_dir/mirrors/lib.git/keep"
_mm_rc=0
_mm_run || _mm_rc=$?
assert_eq "a new engagement never replaces a mirror: refused" "1" \
    "$([ "$_mm_rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "and the mirror stays" "true" \
    "$([ -e "$_mm_dir/mirrors/lib.git/keep" ] && echo true || echo false)"
rm -rf "$_mm_dir/mirrors/lib.git"
mkdir "$_mm_dir/mirrors/lib.git.new"
_mm_rc=0
_mm_run missing || _mm_rc=$?
assert_eq "a .new a stopped run left: refused" "1" \
    "$([ "$_mm_rc" -ne 0 ] && echo 1 || echo 0)"
rmdir "$_mm_dir/mirrors/lib.git.new"

# Through launch.sh: with a session open, start leaves the bare repo
# alone, and another interactive session still joins it.  Once the
# session ends, start still refuses: a new engagement waits for
# ./launch.sh cleanup.
_pd_rt="$TMPDIR/pending-runtime"
run_pd() {
    (cd "$_st_repo" && PATH="$_st_bin:$PATH" SWARM_RUNTIME_DIR="$_pd_rt" \
        SWARM_CONFIG=sub/configs/swarm.json SWARM_SKIP_DEP_CHECK=1 \
        "$BASH" "$_LAUNCH_SH" "$@" 2>&1)
}
run_pd start >/dev/null
touch "$_pd_rt/upstream.git/keep"
swarm_pending_write "$_pd_rt" "$_pd_id_a" "$_pd_live" d1
_pd_rc=0
_pd_out=$(run_pd start) || _pd_rc=$?
assert_eq "start refuses while a session is open" "1" "$_pd_rc"
assert_eq "start names the open session" "true" \
    "$(grep -q "$_pd_id_a" <<< "$_pd_out" \
        && echo true || echo false)"
assert_eq "the bare repo stays" "true" \
    "$([ -e "$_pd_rt/upstream.git/keep" ] && echo true || echo false)"
_pd_rc=0
run_pd interactive --agent-index 1 >/dev/null || _pd_rc=$?
assert_eq "another interactive session joins meanwhile" "0" "$_pd_rc"
kill "$_pd_live" 2>/dev/null || true
wait "$_pd_live" 2>/dev/null || true
_pd_rc=0
_pd_out=$(run_pd start) || _pd_rc=$?
assert_eq "after the session ends start still refuses" "1" "$_pd_rc"
assert_eq "and says cleanup comes first" "true" \
    "$(grep -q 'launch.sh cleanup' <<< "$_pd_out" \
        && echo true || echo false)"
assert_eq "and the bare repo stays" "true" \
    "$([ -e "$_pd_rt/upstream.git/keep" ] && echo true || echo false)"
assert_eq "the old record is gone" "false" \
    "$([ -e "$_pd_rt/interactive-$_pd_id_a.pending" ] \
        && echo true || echo false)"

# ============================================================
echo ""
echo "=== 54. No temporary file outlives launch.sh ==="

# interactive stopped by an agent index that does not exist, start
# stopped by a driver that does not exist once it wrote the agents'
# list, and interactive stopped by a Ctrl-C while the image builds:
# every file mktemp made for them is gone when they exit.  A mktemp
# first on PATH logs what the real one makes, NUL-terminated.
_tf_bin="$TMPDIR/tf-bin"
_tf_sig="$TMPDIR/tf-sig"
_tf_log="$TMPDIR/tf-mktemp.log"
_tf_rt="$TMPDIR/tf-runtime"
mkdir -p "$_tf_bin" "$_tf_sig"
cat > "$_tf_bin/mktemp" <<'EOF'
#!/bin/bash
out=$(PATH="$TF_PATH" mktemp "$@") || exit $?
printf '%s\0' "$out" >> "$TF_LOG"
printf '%s\n' "$out"
EOF
# docker build runs until a signal ends it, as a long build would;
# every other call goes to the start tests' docker.
cat > "$_tf_sig/docker" <<'EOF'
#!/bin/bash
[ "$1" != build ] || exec sleep 30
exec "$TF_DOCKER" "$@"
EOF
chmod +x "$_tf_bin/mktemp" "$_tf_sig/docker"
run_tf() {
    local orig="$PATH"
    : > "$_tf_log"
    (cd "$_st_repo" && TF_PATH="$orig" TF_LOG="$_tf_log" \
        PATH="$_tf_bin:$_st_bin:$orig" SWARM_RUNTIME_DIR="$_tf_rt" \
        SWARM_SKIP_DEP_CHECK=1 "$@" 2>&1)
}
# Print how many of the files mktemp made (the log) are still there.
tf_left() {
    local f n=0
    while IFS= read -r -d '' f; do
        [ ! -e "$f" ] || n=$((n + 1))
    done < "$_tf_log"
    printf '%s' "$n"
}
# Remove what is left of them.
tf_drop() {
    local f
    while IFS= read -r -d '' f; do
        rm -f -- "$f"
    done < "$_tf_log"
}
_tf_rc=0
run_tf env SWARM_CONFIG=sub/configs/swarm.json \
    bash "$_LAUNCH_SH" interactive --agent-index 9 >/dev/null || _tf_rc=$?
assert_eq "interactive with an unknown agent index fails" "1" "$_tf_rc"
assert_eq "it made a temporary file" "true" \
    "$([ -s "$_tf_log" ] && echo true || echo false)"
assert_eq "which is gone" "0" "$(tf_left)"
tf_drop
# A relative TMPDIR is made absolute first (a run may change directory
# before it exits), whatever CDPATH says.
mkdir -p "$_st_repo/sub/tf-rel"
_tf_rc=0
run_tf env SWARM_CONFIG=sub/configs/swarm.json TMPDIR=sub/tf-rel CDPATH=. \
    bash "$_LAUNCH_SH" interactive --agent-index 9 >/dev/null || _tf_rc=$?
assert_eq "so does a run with a relative TMPDIR" "1" "$_tf_rc"
_tf_first=""
IFS= read -r -d '' _tf_first < "$_tf_log" || true
assert_eq "whose file had an absolute path in it" \
    "$(cd -P "$_st_repo/sub/tf-rel" && pwd -P)" "${_tf_first%/swarm-profile.*}"
assert_eq "and is gone" "0" "$(tf_left)"
tf_drop
rmdir "$_st_repo/sub/tf-rel"
jq '.agents[0].driver = "no-such-driver"' \
    "$_st_repo/sub/configs/swarm.json" > "$_st_repo/sub/configs/tf.json"
_tf_rc=0
_tf_out=$(run_tf env SWARM_CONFIG=sub/configs/tf.json \
    bash "$_LAUNCH_SH" start) || _tf_rc=$?
assert_eq "start with an unknown driver fails" "1" "$_tf_rc"
assert_eq "once it wrote the agents' list" "true" \
    "$(grep -q 'unknown driver' <<< "$_tf_out" && echo true || echo false)"
assert_eq "every temporary file it made is gone" "0" "$(tf_left)"
tf_drop
rm -f "$_st_repo/sub/configs/tf.json"
# A Ctrl-C at the terminal while the image builds: SIGINT to the
# process group of launch.sh, run in one of its own with /bin/bash
# (Bash 3.2 on macOS), once docker build runs.
if ! (sigint_works); then
    echo "  SKIP: a Ctrl-C while the image builds (SIGINT is ignored here)"
else
    _tf_rc=0
    _tf_orig="$PATH"
    : > "$_tf_log"
    set -m
    (cd "$_st_repo" && TF_PATH="$_tf_orig" TF_LOG="$_tf_log" \
        TF_DOCKER="$_st_bin/docker" \
        PATH="$_tf_sig:$_tf_bin:$_st_bin:$_tf_orig" \
        SWARM_RUNTIME_DIR="$_tf_rt" SWARM_SKIP_DEP_CHECK=1 \
        SWARM_CONFIG=sub/configs/swarm.json \
        exec /bin/bash "$_LAUNCH_SH" interactive --agent-index 1 \
        > "$TMPDIR/tf-int.out" 2>&1) &
    _tf_pid=$!
    set +m
    _tf_tries=0
    while [ "$_tf_tries" -lt 200 ] \
            && ! pgrep -g "$_tf_pid" -x sleep >/dev/null 2>&1; do
        sleep 0.05
        _tf_tries=$((_tf_tries + 1))
    done
    kill -INT -- "-$_tf_pid" 2>/dev/null
    wait "$_tf_pid" || _tf_rc=$?
    assert_eq "a Ctrl-C while the image builds stops interactive" "130" \
        "$_tf_rc"
    assert_eq "after it made its temporary file" "true" \
        "$([ -s "$_tf_log" ] && echo true || echo false)"
    assert_eq "which is gone" "0" "$(tf_left)"
    tf_drop
fi

# ============================================================
echo ""
echo "=== 55. Workspace volumes, one daemon, clean runtimes ==="

# start, post-process, interactive, stop and wait against a fake docker
# that keeps its world in files under V_DIR, one directory per case:
#   context     the current context, a or b (DOCKER_CONTEXT overrides
#               it); the daemon behind context X has id daemon-X
#   switch      when there, the first "context show" switches the
#               current context to b right after it answers, as another
#               terminal could
#   containers  one JSON object per line: id, name, state, labels
#   volumes     the names "volume ls" prints
#   fail        calls that fail, one per line: ps (every listing), ps3
#               (from the third listing on), volume-ls, run, build,
#               stop (the container keeps running), stop-exits (it
#               stops anyway), stop-gone (it is removed meanwhile),
#               inspect
#   spawn       a count: while it is above 0, each container docker stop
#               stops makes a new running one of the same engagement
#               appear (as a start launching its agents would), and the
#               count goes down
#   newtoken    when there, wait's first listing gives the state file
#               (V_STATE) another engagement token, as a cleanup and a
#               new start in another terminal would
#   at.N        containers that replace containers right before wait's
#               Nth listing (the polls and the recount under the lock)
#   lock-probe  when there, each listing made once a flock call has
#               waited for the lock (a "-w" line in flock.log) tries the
#               engagement lock itself and logs to lock-probe.log whether
#               another process held it ("held") or not ("free")
#   hold-build  when there, docker build writes its pid to V_DIR/ready
#               and waits until a SIGTERM, then exits with 0 (after 30
#               seconds with none, it fails)
# Every call is logged to V_DIR/log as "<DOCKER_CONTEXT>|<arguments>".
# volume create and inspect go to the shared fake, which keeps this
# case's volumes in V_DIR/vols.
unset DOCKER_HOST DOCKER_CONTEXT SWARM_ENGAGEMENT_TOKEN
_v_bin="$TMPDIR/v55-bin"
_v_root="$TMPDIR/v55"
mkdir -p "$_v_bin" "$_v_root"
cat > "$_v_bin/docker" <<'EOF'
#!/bin/bash
d="$V_DIR"
ctx="${DOCKER_CONTEXT:-$(cat "$d/context")}"
printf '%s|%s\n' "${DOCKER_CONTEXT:-}" "$*" >> "$d/log"
fails() { grep -qx "$1" "$d/fail" 2>/dev/null; }
case "$1" in
    context)
        cat "$d/context"
        if [ -e "$d/switch" ]; then
            rm -f "$d/switch"
            echo b > "$d/context"
        fi ;;
    info) echo "daemon-$ctx" ;;
    volume)
        if [ "$2" = ls ]; then
            fails volume-ls && exit 1
            cat "$d/volumes" 2>/dev/null
            exit 0
        fi
        FAKE_DOCKER_VOLUME_DIR="$d/vols" exec "$FAKE_DOCKER_VOLUME" "$@" ;;
    ps)
        n=$(( $(cat "$d/ps-count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$d/ps-count"
        if [ -e "$d/lock-probe" ] \
                && grep -q '^-w ' "$d/flock.log" 2>/dev/null; then
            if (exec 7>>"$SWARM_RUNTIME_DIR/engagement.lock" \
                    && flock -n 7); then
                echo free >> "$d/lock-probe.log"
            else
                echo held >> "$d/lock-probe.log"
            fi
        fi
        fails ps && exit 1
        if fails ps3 && [ "$n" -ge 3 ]; then exit 1; fi
        shift
        all=false quiet=false fmt="" filters=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -a) all=true ;;
                -q) quiet=true ;;
                --filter) filters="${filters}$2"$'\n'; shift ;;
                --format) fmt="$2"; shift ;;
            esac
            shift
        done
        if [ "$fmt" = '{{.Names}} {{.State}}' ]; then
            w=$(( $(cat "$d/wait-listed" 2>/dev/null || echo 0) + 1 ))
            echo "$w" > "$d/wait-listed"
            if [ -f "$d/at.$w" ]; then
                mv "$d/at.$w" "$d/containers"
            fi
        fi
        if [ "$fmt" = '{{.Names}} {{.State}}' ] && [ -e "$d/newtoken" ]; then
            rm -f "$d/newtoken"
            jq -c '.engagement_token = "ffffffffffffffff"' "$V_STATE" \
                > "$V_STATE.x" && mv "$V_STATE.x" "$V_STATE"
        fi
        [ -s "$d/containers" ] || exit 0
        jq -r --argjson all "$all" --argjson quiet "$quiet" \
            --arg fmt "$fmt" --arg filters "$filters" '
            ($filters | split("\n") | map(select(length > 0))) as $f
            | select($all or .state == "running")
            | . as $c
            | select(all($f[]; . as $x
                | if startswith("label=") then
                      $x[6:] as $kv | ($kv | index("=")) as $i
                      | if $i == null then ($c.labels | has($kv))
                        else ($c.labels[$kv[:$i]] // null) == $kv[$i + 1:]
                        end
                  elif startswith("name=") then ($c.name | contains($x[5:]))
                  elif startswith("id=") then ($c.id | startswith($x[3:]))
                  else false end))
            | if $quiet then .id
              elif ($fmt | contains("\"owner\":")) then
                  {id, name,
                   project: (.labels["swarm-core.project"] // ""),
                   owner: (.labels["swarm-core.checkout"] // "")} | tojson
              elif $fmt == "{{.State}}" then .state
              elif $fmt == "{{.ID}} {{.State}}" then "\(.id) \(.state)"
              elif $fmt == "{{.Names}} {{.State}}" then "\(.name) \(.state)"
              else .name end' "$d/containers" ;;
    container|inspect)
        if fails inspect; then
            echo "Cannot connect to the Docker daemon" >&2
            exit 1
        fi
        [ "$1" = container ] && shift
        shift
        fmt=""
        if [ "$1" = -f ] || [ "$1" = --format ]; then
            fmt="$2"
            shift 2
        fi
        c=$(jq -c --arg t "$1" 'select(.name == $t or .id == $t)' \
            "$d/containers" 2>/dev/null | head -n 1)
        if [ -z "$c" ]; then
            echo "Error: No such container: $1" >&2
            exit 1
        fi
        case "$fmt" in
            *'"labels":'*) jq -c '{id, labels}' <<< "$c" ;;
            *.State.Error*) jq -r '"\(.state)|\(.error // "")"' <<< "$c" ;;
            *.State.Status*) jq -r .state <<< "$c" ;;
            *.State.Running*) jq -r '.state == "running"' <<< "$c" ;;
            *.State.ExitCode*) echo 0 ;;
            *'{{.Name}}|'*)
                jq -r '"/\(.name)|\(.labels["swarm-core.project"] // "")|\(.labels["swarm-core.checkout"] // "")|\(.labels["swarm-core.engagement-token"] // "")"' <<< "$c" ;;
            *) printf '%s\n' "$c" ;;
        esac ;;
    run)
        jq -nc '$ARGS.positional' --args -- "$@" >> "$d/argv.jsonl"
        fails run && exit 125
        case " $* " in
            *" -d "*) echo "cid-run" ;;
        esac ;;
    build)
        if [ -e "$d/hold-build" ]; then
            trap 'kill "$s" 2>/dev/null; exit 0' TERM
            sleep 30 &
            s=$!
            printf '%s\n' "$$" > "$d/ready.tmp"
            mv "$d/ready.tmp" "$d/ready"
            wait "$s"
            exit 1
        fi
        fails build && exit 1 ;;
    stop)
        id="${*: -1}"
        if fails stop-gone; then
            jq -c --arg i "$id" 'select(.id != $i)' "$d/containers" \
                > "$d/containers.x" && mv "$d/containers.x" "$d/containers"
            exit 42
        fi
        if fails stop-exits; then
            jq -c --arg i "$id" \
                'if .id == $i then .state = "exited" else . end' \
                "$d/containers" > "$d/containers.x" \
                && mv "$d/containers.x" "$d/containers"
            exit 42
        fi
        fails stop && exit 42
        jq -c --arg i "$id" \
            'if .id == $i then .state = "exited" else . end' \
            "$d/containers" > "$d/containers.x" \
            && mv "$d/containers.x" "$d/containers"
        left=$(cat "$d/spawn" 2>/dev/null || echo 0)
        if [ "$left" -gt 0 ]; then
            echo $((left - 1)) > "$d/spawn"
            n=$(( $(wc -l < "$d/containers") + 1 ))
            jq -c --arg i "$id" --arg n "$n" 'select(.id == $i)
                | .id = ("id-spawn-" + $n) | .state = "running"
                | .name = (.name | sub("-[0-9]+$"; "-" + $n))' \
                "$d/containers" > "$d/containers.x" \
                && cat "$d/containers.x" >> "$d/containers"
        fi ;;
esac
exit 0
EOF
chmod +x "$_v_bin/docker"

_v_checkout=$(swarm_checkout_path "$_st_repo")
_v_img="start-repo-agent"
# Two agents in slim context, a post-process, and docker_args that try
# to replace what the engine sets: auto-remove, a restart policy, a
# name.
V_CFG="$_v_root/swarm.json"
cat > "$V_CFG" <<'EOF'
{ "prompt": "prompt.md", "title": "v55", "driver": "fake",
  "docker_args": ["--rm", "--restart", "always", "--name", "other"],
  "agents": [{ "count": 2, "model": "fake", "context": "slim" }],
  "post_process": { "prompt": "prompt.md", "model": "fake" } }
EOF
_v_n=0
# A new case: a fresh fake Docker world on context a and a fresh
# runtime directory V_RT.
v_new() {
    _v_n=$((_v_n + 1))
    V_DIR="$_v_root/case-$_v_n"
    V_RT="$_v_root/rt-$_v_n"
    V_STATE="$V_RT/state.json"
    mkdir -p "$V_DIR/vols"
    echo a > "$V_DIR/context"
    : > "$V_DIR/log"
}
# Run launch.sh with ARGS in the start tests' checkout against this
# case's fake Docker; print its output.  Variables set on the call
# reach it; the lock descriptor of the test, 8, does not.
v_run() {
    (cd "$_st_repo" && PATH="$_v_bin:$PATH" V_DIR="$V_DIR" \
        V_STATE="$V_STATE" SWARM_RUNTIME_DIR="$V_RT" \
        SWARM_CONFIG="$V_CFG" SWARM_SKIP_DEP_CHECK=1 SWARM_WAIT_POLL=0 \
        "$BASH" "$_LAUNCH_SH" "$@" 8>&- 2>&1)
}
# What a refused command must leave as it was: the runtime directory's
# entries (the lock file aside, which taking the lock creates) and the
# state file.
v_snap() {
    (cd "$V_RT" 2>/dev/null && find . ! -name engagement.lock -print \
        | LC_ALL=C sort)
    cat "$V_STATE" 2>/dev/null || true
}
# Count the logged Docker calls that make, change or remove something.
v_writes() {
    grep -cE '^[^|]*[|](run|start|stop|kill|rm|commit|build|volume create|volume rm|container (start|stop|kill|rm)) ' \
        "$V_DIR/log" || true
}
v_has() {
    grep -qF -- "$1" <<< "$2" && echo true || echo false
}
# Print the names of this case's volumes that match extended regular
# expression RE.
v_volume() {
    local f
    for f in "$V_DIR/vols"/*; do
        [ -e "$f" ] || continue
        f="${f##*/}"
        if grep -qE -- "$1" <<< "$f"; then
            printf '%s\n' "$f"
        fi
    done
}
v_container() {
    # NAME STATE TOKEN: one container of this checkout.
    jq -cn --arg n "$1" --arg s "$2" --arg t "$3" --arg c "$_v_checkout" \
        '{id: ("id-" + $n), name: $n, state: $s,
          labels: ({"swarm-core.project": "start-repo",
                    "swarm-core.checkout": $c}
                   + (if $t == "" then {}
                      else {"swarm-core.engagement-token": $t} end))}' \
        >> "$V_DIR/containers"
}

# --- start: one volume per agent, the pin, the recorded daemon -------
v_new
touch "$V_DIR/switch"
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "start on a clean runtime succeeds" "0" "$_v_rc"
assert_eq "the first Docker call reads the context" "|context show" \
    "$(head -n 1 "$V_DIR/log")"
assert_eq "every later call goes to that context" "0" \
    "$(awk 'NR > 1 && !/^a[|]/ { n++ } END { print n + 0 }' "$V_DIR/log")"
assert_eq "even though the current context changed after that call" "b" \
    "$(cat "$V_DIR/context")"
assert_eq "the engagement records the daemon of the pinned context" \
    "daemon-a" "$(jq -r .docker_daemon "$V_STATE" 2>/dev/null)"
_v_eng=$(jq -r .engagement_id "$V_STATE" 2>/dev/null)
_v_tok=$(jq -r .engagement_token "$V_STATE" 2>/dev/null)
assert_eq "and a token of 16 hex digits" "true" \
    "$(grep -qE '^[0-9a-f]{16}$' <<< "$_v_tok" && echo true || echo false)"
assert_eq "one volume per agent" "2" \
    "$(find "$V_DIR/vols" -type f | wc -l | tr -d ' ')"
for _v_i in 1 2; do
    _v_vol=$(v_volume "^${_v_img}-${_v_i}-ws-[0-9a-f]{8}$")
    assert_eq "agent $_v_i: its volume is named after it" "true" \
        "$([ -n "$_v_vol" ] && echo true || echo false)"
    assert_eq "agent $_v_i: the volume carries every label" "true" \
        "$(jq -e --arg c "$_v_checkout" --arg e "$_v_eng" \
            --arg t "$_v_tok" --arg n "${_v_img}-${_v_i}" '
            .["swarm-core.project"] == "start-repo"
            and .["swarm-core.checkout"] == $c
            and .["swarm-core.engagement"] == $e
            and .["swarm-core.engagement-token"] == $t
            and .["swarm-core.container"] == $n
            and .["swarm-core.kind"] == "agent"
            and .["swarm-core.context"] == "slim"
            and (.["swarm-core.nonce"] | test("^[0-9a-f]{16}$"))' \
            "$V_DIR/vols/${_v_vol:-none}" >/dev/null 2>&1 \
            && echo true || echo false)"
    assert_eq "agent $_v_i: mount, labels, policies and name follow docker_args" \
        "1" "$(grep -F -- "|run --rm --restart always --name other -d --mount type=bind,src=$V_RT/upstream.git,dst=/upstream " "$V_DIR/log" | grep -cF -- " --mount type=volume,src=${_v_vol:-none},dst=/workspace --label swarm-core.engagement=${_v_eng} --label swarm-core.engagement-token=${_v_tok} --restart no --rm=false --name ${_v_img}-${_v_i} " || true)"
done
assert_eq "start builds the image once" "1" \
    "$(grep -c '|build ' "$V_DIR/log" || true)"
_v_start_dir="$V_DIR"
_v_start_rt="$V_RT"

# --- interactive and post-process join it, each with its volume ------
# The current context is b now: switch back first.
echo a > "$V_DIR/context"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run interactive --agent-index 1) || _v_rc=$?
assert_eq "interactive joins the engagement" "0" "$_v_rc"
_v_sess=$(grep -F -- '|run --rm --restart always --name other -it ' \
    "$V_DIR/log" \
    | sed -n 's/.* --rm=false --name \([^ ]*\) .*/\1/p')
assert_eq "the session's name ends in UTC time and 8 hex digits" "true" \
    "$(grep -qE "^${_v_img}-interactive-[a-z0-9._-]+-[0-9]{14}-[0-9a-f]{8}$" \
        <<< "$_v_sess" && echo true || echo false)"
_v_vol=$(v_volume "^${_v_sess:-none}-ws-[0-9a-f]{8}$")
assert_eq "the session gets a volume of its own" "true" \
    "$(jq -e --arg n "$_v_sess" --arg t "$_v_tok" '
        .["swarm-core.container"] == $n
        and .["swarm-core.kind"] == "interactive"
        and .["swarm-core.context"] == "slim"
        and .["swarm-core.engagement-token"] == $t' \
        "$V_DIR/vols/${_v_vol:-none}" >/dev/null 2>&1 \
        && echo true || echo false)"
assert_eq "mounted after docker_args, with the policies and its name" "1" \
    "$(grep -F -- "|run --rm --restart always --name other -it --mount type=bind,src=$V_RT/upstream.git,dst=/upstream " "$V_DIR/log" | grep -cF -- " --mount type=volume,src=${_v_vol:-none},dst=/workspace --label swarm-core.engagement=${_v_eng} --label swarm-core.engagement-token=${_v_tok} --restart no --rm=false --name ${_v_sess} " || true)"
assert_eq "its session record names the daemon" "daemon=daemon-a" \
    "$(grep '^daemon=' "$V_RT/interactive-${_v_sess}.pending" 2>/dev/null)"
assert_eq "joining builds the image too" "1" \
    "$(grep -c '|build ' "$V_DIR/log" || true)"

# post-process: docker run fails here, which ends it before it waits.
: > "$V_DIR/log"
echo run > "$V_DIR/fail"
_v_rc=0
_v_out=$(v_run post-process) || _v_rc=$?
rm -f "$V_DIR/fail"
assert_eq "post-process reached docker run" "125" "$_v_rc"
_v_vol=$(v_volume "^${_v_img}-post-ws-[0-9a-f]{8}$")
assert_eq "post-process gets a volume of its own" "true" \
    "$(jq -e --arg t "$_v_tok" '
        .["swarm-core.container"] == "start-repo-agent-post"
        and .["swarm-core.kind"] == "agent"
        and .["swarm-core.context"] == "full"
        and .["swarm-core.engagement-token"] == $t' \
        "$V_DIR/vols/${_v_vol:-none}" >/dev/null 2>&1 \
        && echo true || echo false)"
assert_eq "mounted after docker_args, with the policies and its name" "1" \
    "$(grep -F -- "|run --rm --restart always --name other -d --mount type=bind,src=$V_RT/upstream.git,dst=/upstream " "$V_DIR/log" | grep -cF -- " --mount type=volume,src=${_v_vol:-none},dst=/workspace --label swarm-core.engagement=${_v_eng} --label swarm-core.engagement-token=${_v_tok} --restart no --rm=false --name ${_v_img}-post " || true)"

# --- volume failures stop before any docker run ----------------------
# Creation fails; the labels read back are not the ones set (another
# volume of that name); the name is taken; Docker cannot say.
for _v_case in "create:cannot create Docker volume" \
        "labels:is not the one just created" \
        "exists:already exists" "error:cannot check Docker volume"; do
    v_new
    _v_rc=0
    _v_out=$(FAKE_VOLUME_FAIL="${_v_case%%:*}" v_run start) || _v_rc=$?
    assert_eq "volume ${_v_case%%:*}: start fails" "1" "$_v_rc"
    assert_eq "volume ${_v_case%%:*}: saying why" "true" \
        "$(v_has "${_v_case#*:}" "$_v_out")"
    assert_eq "volume ${_v_case%%:*}: before any docker run" "0" \
        "$(grep -c '|run ' "$V_DIR/log" || true)"
done

# An unknown context mode stops start before anything is made.
_v_cfg_ok="$V_CFG"
V_CFG="$_v_root/bad-context.json"
jq '.agents[0].context = "weird"' "$_v_cfg_ok" > "$V_CFG"
v_new
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "an unknown context mode stops start" "1" "$_v_rc"
assert_eq "saying so" "true" "$(v_has "unknown context mode" "$_v_out")"
assert_eq "before the runtime directory is made" "false" \
    "$([ -e "$V_RT" ] && echo true || echo false)"
assert_eq "and before any Docker write" "0" "$(v_writes)"
v_new
_v_rc=0
_v_out=$(v_run interactive --agent-index 1) || _v_rc=$?
assert_eq "an unknown context mode stops interactive" "1" "$_v_rc"
assert_eq "saying so" "true" "$(v_has "unknown context mode" "$_v_out")"
assert_eq "before the runtime directory is made" "false" \
    "$([ -e "$V_RT" ] && echo true || echo false)"
V_CFG="$_v_cfg_ok"

# The volume helper itself refuses an unknown kind or context before it
# asks Docker anything.
_v_vlog="$_v_root/helper.log"
: > "$_v_vlog"
_v_rc=0
(docker() { echo "$*" >> "$_v_vlog"; }
 swarm_workspace_volume_create n p /c e t other full) >/dev/null 2>&1 \
    || _v_rc=$?
assert_eq "an unknown volume kind is refused" "1" "$_v_rc"
_v_rc=0
(docker() { echo "$*" >> "$_v_vlog"; }
 swarm_workspace_volume_create n p /c e t agent weird) >/dev/null 2>&1 \
    || _v_rc=$?
assert_eq "an unknown context is refused" "1" "$_v_rc"
assert_eq "both before any Docker call" "0" \
    "$(wc -l < "$_v_vlog" | tr -d ' ')"

# --- another daemon: nothing joins, nothing is stopped ---------------
V_DIR="$_v_start_dir"
V_RT="$_v_start_rt"
V_STATE="$V_RT/state.json"
# The ended session's record would be pruned by a later check.
rm -f "$V_RT"/interactive-*.pending
# The agents as stop and wait would see them: stop has one to stop; wait
# would go on at once to post-process (it would poll a running one
# forever).
v_agents() {
    : > "$V_DIR/containers"
    v_container "${_v_img}-1" "$1" "$_v_tok"
    v_container "${_v_img}-2" exited "$_v_tok"
}
echo b > "$V_DIR/context"
_v_before=$(v_snap)
for _v_cmd in stop wait post-process "interactive --agent-index 1"; do
    if [ "$_v_cmd" = stop ]; then v_agents running; else v_agents exited; fi
    : > "$V_DIR/log"
    _v_rc=0
    # shellcheck disable=SC2086
    _v_out=$(v_run $_v_cmd) || _v_rc=$?
    assert_eq "another daemon: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "another daemon: $_v_cmd says which" "true" \
        "$(v_has "runs on Docker daemon daemon-a, but Docker now talks to daemon-b" "$_v_out")"
    assert_eq "another daemon: $_v_cmd changes nothing" "0" "$(v_writes)"
done
assert_eq "another daemon: runtime and state as they were" "$_v_before" \
    "$(v_snap)"
echo a > "$V_DIR/context"

# The daemon check refuses a state file it cannot read, and one with no
# daemon, without asking Docker.
printf '{' > "$_v_root/bad-state.json"
_v_rc=0
(docker() { echo "$*" >> "$_v_vlog"; }
 swarm_engagement_daemon_check "$_v_root/bad-state.json") >/dev/null 2>&1 \
    || _v_rc=$?
assert_eq "an unreadable state file fails the daemon check" "1" "$_v_rc"
jq -n '{schema: "swarm-core.state/v1", engagement_id: "e"}' \
    > "$_v_root/no-daemon.json"
_v_rc=0
(docker() { echo "$*" >> "$_v_vlog"; }
 swarm_engagement_daemon_check "$_v_root/no-daemon.json") >/dev/null 2>&1 \
    || _v_rc=$?
assert_eq "so does a state file with no daemon" "1" "$_v_rc"
assert_eq "neither asks Docker" "0" "$(wc -l < "$_v_vlog" | tr -d ' ')"

# --- stop and the lock; wait follows one engagement -------------------
# A post-process holds the lock for its whole run: stop still stops
# what runs, then waits for the lock, up to the grace, before it can
# say that nothing more is starting.  Past the grace, it fails.
v_agents running
: > "$V_DIR/log"
exec 8>>"$V_RT/engagement.lock"
flock -n 8
_v_rc=0
_v_out=$(SWARM_STOP_TIMEOUT=1 v_run stop) || _v_rc=$?
exec 8>&-
assert_eq "stop while another command holds the lock: fails" "1" "$_v_rc"
assert_eq "once it stopped the running agent by its id" "1" \
    "$(grep -c "^a|stop -t 1 id-${_v_img}-1$" "$V_DIR/log" || true)"
assert_eq "saying why" "true" \
    "$(v_has "without the engagement lock, stop cannot tell" "$_v_out")"
# A flock first on PATH logs each call to V_DIR/flock.log.
_v_flk="$TMPDIR/v55-flock"
mkdir -p "$_v_flk"
_v_real_flock=$(command -v flock)
cat > "$_v_flk/flock" <<EOF
#!/bin/bash
echo "\$*" >> "\$V_DIR/flock.log"
exec "$_v_real_flock" "\$@"
EOF
chmod +x "$_v_flk/flock"
# Hold the lock in the background, as another command would, until a
# flock call waits for it, then run FUNCTION and let the lock go.  When
# no call waits for it within ten seconds, the holder leaves
# V_DIR/holder-timeout and goes on all the same.
v_hold() {
    rm -f "$V_DIR/flock.log" "$V_DIR/holder-timeout"
    exec 8>>"$V_RT/engagement.lock"
    flock -n 8
    (
        _v_seen=false
        for _ in $(seq 100); do
            if grep -q '^-w ' "$V_DIR/flock.log" 2>/dev/null; then
                _v_seen=true
                break
            fi
            sleep 0.1
        done
        $_v_seen || : > "$V_DIR/holder-timeout"
        "$1"
    ) &
    _v_holder=$!
    exec 8>&-
}
v_holder_waited() {
    [ -e "$V_DIR/holder-timeout" ] && echo false || echo true
}
# A start that recorded the engagement holds the lock while it launches
# its agents: one it launches once stop waits for the lock is stopped
# too, before stop succeeds.
v_late() { v_container "${_v_img}-3" running "$_v_tok"; }
v_agents running
: > "$V_DIR/log"
touch "$V_DIR/lock-probe"
rm -f "$V_DIR/lock-probe.log"
v_hold v_late
_v_rc=0
_v_out=$(PATH="$_v_flk:$PATH" v_run stop) || _v_rc=$?
wait "$_v_holder"
rm -f "$V_DIR/lock-probe"
assert_eq "stop while a start launches one more agent: a success" "0" \
    "$_v_rc"
assert_eq "the start went on once stop waited for the lock" "true" \
    "$(v_holder_waited)"
assert_eq "once it had the lock" "1" \
    "$(grep -c '^-w 60 ' "$V_DIR/flock.log" || true)"
# Its two listings under the lock (one that stops the late agent, one
# that finds nothing): the lock was held, by stop, for both.
_v_probe="$(grep -c '^held$' "$V_DIR/lock-probe.log" || true)"
_v_probe+=" $(grep -c '^free$' "$V_DIR/lock-probe.log" || true)"
assert_eq "stop holds the lock for its listings under it" "2 0" "$_v_probe"
assert_eq "that agent stopped too" "1" \
    "$(grep -c "^a|stop -t 60 id-${_v_img}-3$" "$V_DIR/log" || true)"
assert_eq "none of the engagement's agents runs then" "0" \
    "$(jq -r 'select(.state == "running") | .id' "$V_DIR/containers" \
        | grep -c . || true)"
# wait takes the lock once the agents are done, which a stop holds for
# a moment then: wait waits for it rather than give up.
v_agents exited
echo run > "$V_DIR/fail"
: > "$V_DIR/log"
v_hold :
_v_rc=0
_v_out=$(PATH="$_v_flk:$PATH" v_run wait) || _v_rc=$?
wait "$_v_holder"
rm -f "$V_DIR/fail"
assert_eq "wait: the lock held a moment, it waits for it" "1" \
    "$(grep -c '^-w 60 ' "$V_DIR/flock.log" || true)"
assert_eq "the holder let it go once wait waited" "true" \
    "$(v_holder_waited)"
assert_eq "then post-process starts" "1" \
    "$(grep -c "|run .* -d .* --name ${_v_img}-post " "$V_DIR/log" || true)"
assert_eq "and ends at the failed docker run" "125" "$_v_rc"
# A stop that fails without the lock fails at once, without waiting for
# the lock first.
v_agents running
echo stop > "$V_DIR/fail"
rm -f "$V_DIR/flock.log"
exec 8>>"$V_RT/engagement.lock"
flock -n 8
_v_rc=0
_v_out=$(PATH="$_v_flk:$PATH" SWARM_STOP_TIMEOUT=2 v_run stop) || _v_rc=$?
exec 8>&-
rm -f "$V_DIR/fail"
assert_eq "stop that cannot stop an agent: fails" "1" "$_v_rc"
assert_eq "without waiting for the lock" "0" \
    "$(cat "$V_DIR/flock.log" 2>/dev/null | grep -c '^-w ' || true)"

# stop and wait take every check from one copy of the state: the state
# file replaced right after that copy (a cleanup and a new start with
# the same engagement id elsewhere) changes neither the engagement they
# check nor the token they act on.  A cp first on PATH replaces it.
_v_cp="$TMPDIR/v55-cp"
mkdir -p "$_v_cp"
cat > "$_v_cp/cp" <<'EOF'
#!/bin/bash
/bin/cp "$@" || exit $?
if [ "${*: -2:1}" = "$V_STATE" ] && [ -e "$V_DIR/replace-state" ]; then
    rm -f "$V_DIR/replace-state"
    jq -c '.engagement_token = "ffffffffffffffff"' "$V_STATE" \
        > "$V_STATE.x" && mv "$V_STATE.x" "$V_STATE"
fi
EOF
chmod +x "$_v_cp/cp"
cp "$V_STATE" "$_v_root/state.saved"
v_agents running
jq -c --arg c "$_v_checkout" '{id: "id-new-1", name: "start-repo-agent-1",
    state: "running", labels: {"swarm-core.project": "start-repo",
    "swarm-core.checkout": $c,
    "swarm-core.engagement-token": "ffffffffffffffff"}}' \
    -n >> "$V_DIR/containers"
: > "$V_DIR/replace-state"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(PATH="$_v_cp:$PATH" SWARM_ENGAGEMENT_ID="$_v_eng" v_run stop) \
    || _v_rc=$?
assert_eq "stop: the state replaced after its copy: still stops" "0" \
    "$_v_rc"
assert_eq "the engagement it checked" "1" \
    "$(grep -c "|stop -t 60 id-${_v_img}-1$" "$V_DIR/log" || true)"
assert_eq "and not the new one's container" "0" \
    "$(grep -c '|stop -t 60 id-new-1$' "$V_DIR/log" || true)"
cp "$_v_root/state.saved" "$V_STATE"
v_agents exited
: > "$V_DIR/replace-state"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(PATH="$_v_cp:$PATH" SWARM_ENGAGEMENT_ID="$_v_eng" v_run wait) \
    || _v_rc=$?
assert_eq "wait: the state replaced after its copy: refused under the lock" \
    "1" "$_v_rc"
assert_eq "for that reason" "true" \
    "$(v_has "the engagement changed while waiting" "$_v_out")"
assert_eq "with no post-process" "0" "$(grep -c '|run ' "$V_DIR/log" || true)"
cp "$_v_root/state.saved" "$V_STATE"
# Neither command reads the state file itself before its checks.
for _v_fn in cmd_stop cmd_wait; do
    assert_eq "$_v_fn checks a copy of the state" "true" \
        "$(awk -v fn="$_v_fn" '$0 ~ "^" fn "\\(\\)" { p = 1 } p { print }
               p && /^}/ { exit }' "$_LAUNCH_SH" \
            | awk '/state_snapshot snap/ { s = 1 }
                   /swarm_engagement_daemon_check/ { exit }
                   s && /"\$STATE_FILE"/ { bad = 1 }
                   END { print (s && !bad) ? "true" : "false" }')"
done

# A start can still be launching agents of the engagement while stop
# runs (it holds the lock; stop's first phase does not take it): stop
# lists them again after each pass and stops those too; when they keep
# appearing even under the lock, it fails rather than leave one running
# behind a success.
v_agents running
echo 1 > "$V_DIR/spawn"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run stop) || _v_rc=$?
assert_eq "stop: an agent launched while it stops is stopped too" "0" \
    "$_v_rc"
assert_eq "in a second pass" "2" "$(grep -c '|stop -t 60 ' "$V_DIR/log" || true)"
assert_eq "none of the engagement's agents runs then" "0" \
    "$(jq -r 'select(.state == "running") | .id' "$V_DIR/containers" \
        | grep -c . || true)"
# Three passes that stop, then one that only checks: two more batches
# that appear are stopped too.
v_agents running
echo 2 > "$V_DIR/spawn"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run stop) || _v_rc=$?
assert_eq "stop: two more batches during stop are stopped too" "0" "$_v_rc"
assert_eq "in three passes" "3" "$(grep -c '|stop -t 60 ' "$V_DIR/log" || true)"
# More than three passes' worth without the lock is no failure yet:
# under the lock, stop stops the rest.
v_agents running
echo 4 > "$V_DIR/spawn"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run stop) || _v_rc=$?
assert_eq "stop: agents that appear for four passes: a success" "0" \
    "$_v_rc"
assert_eq "three stops without the lock, two under it" "5" \
    "$(grep -c '|stop -t 60 ' "$V_DIR/log" || true)"
v_agents running
echo 99 > "$V_DIR/spawn"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run stop) || _v_rc=$?
rm -f "$V_DIR/spawn"
assert_eq "stop: agents that keep appearing fail it" "1" "$_v_rc"
assert_eq "after three passes without the lock and three under it" "6" \
    "$(grep -c '|stop -t 60 ' "$V_DIR/log" || true)"
assert_eq "saying so" "true" \
    "$(v_has "keep starting, even under the engagement lock" "$_v_out")"
# post-process, under the lock, finds every numbered agent done (no
# start can be launching more then) or refuses: the dashboard's p
# stops them first without the lock.
v_agents running
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run post-process) || _v_rc=$?
assert_eq "post-process while a numbered agent runs: refused" "1" "$_v_rc"
assert_eq "with the next step" "true" \
    "$(v_has "stop them (./launch.sh stop --numbered) or wait for them" \
        "$_v_out")"
assert_eq "and nothing made" "0" "$(v_writes)"
: > "$V_DIR/containers"

# A stop Docker cannot do fails the command, so that the dashboard's p
# does not go on to post-process while an agent may still run; one that
# stopped or went meanwhile is fine.  So is the label check: a container
# Docker cannot describe, though it is there, fails the stop.
for _v_case in stop:1:"cannot stop ${_v_img}-1" \
        stop-exits:0:"${_v_img}-1 not running" \
        stop-gone:0:"${_v_img}-1 not running" \
        inspect:1:"cannot inspect container id-${_v_img}-1"; do
    _v_mode="${_v_case%%:*}"
    _v_want="${_v_case#*:}"
    _v_msg="${_v_want#*:}"
    _v_want="${_v_want%%:*}"
    v_agents running
    echo "$_v_mode" > "$V_DIR/fail"
    _v_rc=0
    _v_out=$(v_run stop) || _v_rc=$?
    rm -f "$V_DIR/fail"
    assert_eq "stop, $_v_mode: status" "$_v_want" "$_v_rc"
    assert_eq "stop, $_v_mode: says what happened" "true" \
        "$(v_has "$_v_msg" "$_v_out")"
done

# A token that is not the engagement's refuses.
for _v_cmd in stop wait post-process; do
    if [ "$_v_cmd" = stop ]; then v_agents running; else v_agents exited; fi
    : > "$V_DIR/log"
    _v_rc=0
    _v_out=$(SWARM_ENGAGEMENT_TOKEN=0123456789abcdef v_run "$_v_cmd") \
        || _v_rc=$?
    assert_eq "another token: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "another token: $_v_cmd says the engagement is gone" "true" \
        "$(v_has "the engagement this command was started for is gone" \
            "$_v_out")"
    assert_eq "another token: $_v_cmd changes nothing" "0" "$(v_writes)"
done

# A token set but empty names no engagement: refused, nothing changed.
for _v_cmd in stop wait post-process; do
    if [ "$_v_cmd" = stop ]; then v_agents running; else v_agents exited; fi
    : > "$V_DIR/log"
    _v_rc=0
    _v_out=$(SWARM_ENGAGEMENT_TOKEN='' v_run "$_v_cmd") || _v_rc=$?
    assert_eq "an empty token: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "an empty token: $_v_cmd says so" "true" \
        "$(v_has "SWARM_ENGAGEMENT_TOKEN is set but empty" "$_v_out")"
    assert_eq "an empty token: $_v_cmd changes nothing" "0" "$(v_writes)"
done

# A token names an engagement: once it is gone (cleaned up, or no state
# file at all), a stop bound to it refuses instead of finding nothing
# to stop.
cp "$V_STATE" "$_v_root/state.saved"
for _v_st in cleaned missing; do
    case "$_v_st" in
        cleaned)
            jq -c 'del(.engagement_id, .engagement_started_at,
                .base_commit, .docker_daemon, .engagement_token)' \
                "$_v_root/state.saved" > "$V_STATE" ;;
        missing) rm -f "$V_STATE" ;;
    esac
    : > "$V_DIR/log"
    _v_rc=0
    _v_out=$(SWARM_ENGAGEMENT_TOKEN="$_v_tok" v_run stop) || _v_rc=$?
    assert_eq "a token-bound stop, engagement $_v_st: refused" "1" "$_v_rc"
    assert_eq "a token-bound stop, engagement $_v_st: says it is gone" \
        "true" "$(v_has "the engagement this command was started for is gone" "$_v_out")"
    assert_eq "a token-bound stop, engagement $_v_st: stops nothing" "0" \
        "$(v_writes)"
done
cp "$_v_root/state.saved" "$V_STATE"
chmod 600 "$V_STATE"

# start makes a new engagement, and a token names one to join: refused
# before anything is prepared, here with the token of an engagement a
# failed clone recorded and left nothing of, which start would replace.
_v_keep="$V_DIR|$V_RT|$V_STATE"
v_new
mkdir -m 700 "$V_RT"
jq -cn --arg r "$_v_checkout" '{schema: "swarm-core.state/v1",
    project: "start-repo", repo_root: $r, engagement_id: "e-failed",
    engagement_started_at: "2026-01-01T00:00:00Z",
    base_commit: "0000000000000000000000000000000000000001",
    docker_daemon: "daemon-a", engagement_token: "aaaaaaaaaaaaaaaa"}' \
    > "$V_STATE"
chmod 600 "$V_STATE"
_v_before=$(v_snap)
_v_rc=0
_v_out=$(SWARM_ENGAGEMENT_TOKEN=aaaaaaaaaaaaaaaa v_run start) || _v_rc=$?
assert_eq "a token-bound start: refused" "1" "$_v_rc"
assert_eq "a token-bound start: says why" "true" \
    "$(v_has "SWARM_ENGAGEMENT_TOKEN names an engagement to join" "$_v_out")"
assert_eq "a token-bound start: the engagement stays recorded" \
    "$_v_before" "$(v_snap)"
assert_eq "a token-bound start: builds and runs nothing" "0" \
    "$(v_writes)"
IFS='|' read -r V_DIR V_RT V_STATE <<< "$_v_keep"

# wait reads the token once; an engagement started again while it polls
# makes it stop before post-process and harvest.
v_agents exited
cp "$V_STATE" "$_v_root/state.saved"
touch "$V_DIR/newtoken"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
assert_eq "wait: an engagement replaced while it polls stops it" "1" \
    "$_v_rc"
assert_eq "saying so" "true" \
    "$(v_has "the engagement changed while waiting" "$_v_out")"
assert_eq "no post-process starts" "0" \
    "$(grep -c '|run ' "$V_DIR/log" || true)"
assert_eq "and no harvest" "false" "$(v_has "Harvesting results" "$_v_out")"
cp "$_v_root/state.saved" "$V_STATE"
# Without the switch, wait goes on to post-process with the token.
echo run > "$V_DIR/fail"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
rm -f "$V_DIR/fail"
assert_eq "wait: all agents done, post-process starts" "1" \
    "$(grep -c "|run .* -d .* --name ${_v_img}-post " "$V_DIR/log" || true)"
assert_eq "wait: post-process ended at the failed docker run" "125" \
    "$_v_rc"

# wait goes on only once no numbered agent runs: one that runs for two
# more listings keeps it waiting for them (then one more listing, under
# the lock).
v_agents exited
mv "$V_DIR/containers" "$V_DIR/at.3"
v_agents running
rm -f "$V_DIR/wait-listed"
echo run > "$V_DIR/fail"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
rm -f "$V_DIR/fail"
# Four listings by wait, one by post-process under its lock.
assert_eq "wait: a running agent keeps it waiting" "5" \
    "$(cat "$V_DIR/wait-listed" 2>/dev/null)"
assert_eq "wait: then post-process starts" "1" \
    "$(grep -c "|run .* -d .* --name ${_v_img}-post " "$V_DIR/log" || true)"
# A start records the engagement before it launches the agents, and
# holds the lock until they run: agents that run by the time wait has
# the lock are waited for too.
: > "$V_DIR/containers"
v_agents running
mv "$V_DIR/containers" "$V_DIR/at.2"
v_agents exited
cp "$V_DIR/containers" "$V_DIR/at.4"
: > "$V_DIR/containers"
rm -f "$V_DIR/wait-listed"
echo run > "$V_DIR/fail"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
rm -f "$V_DIR/fail"
assert_eq "wait: agents launched while it took the lock are waited for" \
    "6" "$(cat "$V_DIR/wait-listed" 2>/dev/null)"
assert_eq "wait: post-process only after them" "1" \
    "$(grep -c "|run .* -d .* --name ${_v_img}-post " "$V_DIR/log" || true)"
# The count itself: numbered agents only, any state that may still run.
awk '/^wait_count\(\)[[:space:]]*\{/ { p = 1 } p { print }
     p && /^\}[[:space:]]*$/ { exit }' "$_LAUNCH_SH" > "$_v_root/wait_count.sh"
assert_eq "wait counts the numbered agents that run or may" "3 3" \
    "$(IMAGE_NAME="$_v_img"
       # shellcheck source=/dev/null
       source "$_v_root/wait_count.sh"
       wait_count "${_v_img}-1 running
${_v_img}-2 exited
${_v_img}-3 created
${_v_img}-4 paused
${_v_img}-10 dead
${_v_img}-5 failed
${_v_img}-post running
${_v_img}-interactive-x-1 running
other-agent-1 running")"
# No read loop over a here-string (Bash 3.2 makes a temporary file for
# it that can fail to be made, and a failed read ends the loop early).
assert_eq "wait reads no listing through a here-string" "0" \
    "$(awk '/^cmd_wait\(\)[[:space:]]*\{/ { p = 1 } p { print }
            p && /^\}[[:space:]]*$/ { exit }' "$_LAUNCH_SH" \
        | grep -c '<<<' || true)"

# --- post-process with this checkout's -post container ---------------
for _v_state in running exited; do
    : > "$V_DIR/containers"
    v_container "${_v_img}-post" "$_v_state" "$_v_tok"
    : > "$V_DIR/log"
    _v_before=$(v_snap)
    _v_rc=0
    _v_out=$(v_run post-process) || _v_rc=$?
    assert_eq "a $_v_state -post container: post-process refused" "1" \
        "$_v_rc"
    case "$_v_state" in
        running) _v_next="stop it first (./launch.sh stop)" ;;
        *) _v_next="retire it first: ./launch.sh retire --post-process" ;;
    esac
    assert_eq "a $_v_state -post container: the next step" "true" \
        "$(v_has "$_v_next" "$_v_out")"
    assert_eq "a $_v_state -post container: nothing removed or made" "0" \
        "$(v_writes)"
    assert_eq "a $_v_state -post container: runtime as it was" \
        "$_v_before" "$(v_snap)"
done
: > "$V_DIR/containers"
# A container whose start failed (a port in use) stays created, with
# the error, and never runs: post-process says to retire it, and wait
# does not wait for such an agent.
v_container "${_v_img}-post" created "$_v_tok"
jq -c '.error = "port is already allocated"' "$V_DIR/containers" \
    > "$V_DIR/containers.x" && mv "$V_DIR/containers.x" "$V_DIR/containers"
_v_rc=0
_v_out=$(v_run post-process) || _v_rc=$?
assert_eq "a -post container that failed to start: retire it first" \
    "1 true" "$_v_rc $(v_has "retire it first" "$_v_out")"
: > "$V_DIR/containers"
v_container "${_v_img}-1" exited "$_v_tok"
v_container "${_v_img}-2" created "$_v_tok"
jq -c 'if .name | endswith("-2")
       then .error = "port is already allocated" else . end' \
    "$V_DIR/containers" > "$V_DIR/containers.x" \
    && mv "$V_DIR/containers.x" "$V_DIR/containers"
rm -f "$V_DIR/wait-listed"
echo run > "$V_DIR/fail"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
rm -f "$V_DIR/fail"
assert_eq "wait: an agent that failed to start is not waited for" "1" \
    "$(grep -c "|run .* -d .* --name ${_v_img}-post " "$V_DIR/log" || true)"
: > "$V_DIR/containers"

# A token names an engagement to join: with the bare repo gone, the
# engagement recorded is incomplete; post-process and interactive do not
# make a new one or its parts.
mv "$V_RT/upstream.git" "$_v_root/upstream.saved"
for _v_cmd in post-process "interactive --agent-index 1"; do
    : > "$V_DIR/log"
    _v_rc=0
    # shellcheck disable=SC2086
    _v_out=$(SWARM_ENGAGEMENT_TOKEN="$_v_tok" v_run $_v_cmd) || _v_rc=$?
    assert_eq "token, no bare repo: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "token, no bare repo: $_v_cmd says why" "true" \
        "$(v_has "is incomplete: $V_RT/upstream.git is missing" "$_v_out")"
    assert_eq "token, no bare repo: $_v_cmd gives the way out" "true" \
        "$(v_has "Run ./launch.sh cleanup" "$_v_out")"
    assert_eq "token, no bare repo: $_v_cmd makes nothing" "0" \
        "$(v_writes)"
done
mv "$_v_root/upstream.saved" "$V_RT/upstream.git"

# --- a new engagement only on a clean runtime -------------------------
# The leftovers: the bare repo (with and without agent work the checkout
# lacks), upstream.git.new, mirrors/, a remnant in the runtime
# directory, a hidden one, a container of this checkout in any state, a
# volume, an open interactive session.  Each makes start refuse and
# change nothing; post-process and interactive join the engagement the
# state records, which is incomplete without its bare repo, and refuse
# too.
sleep 60 &
_v_live=$!
# A runtime with a recorded engagement and, of what start made, only
# leftover KIND; "work" keeps the bare repo, with a commit on agent-work
# that the checkout lacks.
v_leftover() {
    v_new
    v_run start >/dev/null || true
    if [ "$1" = work ]; then
        git -C "$V_RT/upstream.git" -c user.name=t -c user.email=t@t \
            -c commit.gpgsign=false commit-tree -m work -p agent-work \
            "$(git -C "$V_RT/upstream.git" rev-parse 'agent-work^{tree}')" \
            > "$_v_root/work-commit"
        git -C "$V_RT/upstream.git" update-ref refs/heads/agent-work \
            "$(cat "$_v_root/work-commit")"
    else
        rm -rf "$V_RT/upstream.git" "$V_RT/mirrors"
        rm -f "$V_RT"/interactive-*.pending
    fi
    case "$1" in
        new) mkdir "$V_RT/upstream.git.new" ;;
        mirrors) mkdir "$V_RT/mirrors" ;;
        remnant) mkdir "$V_RT/x.removing" ;;
        hidden) mkdir "$V_RT/.x.removing" ;;
        container) v_container "${_v_img}-1" exited "" ;;
        volume) echo "${_v_img}-1-ws-0123abcd" > "$V_DIR/volumes" ;;
        session)
            swarm_pending_write "$V_RT" "${_v_img}-interactive-x-1" \
                "$_v_live" daemon-a ;;
    esac
    : > "$V_DIR/log"
}
for _v_kind in work new mirrors remnant hidden container volume session; do
    v_leftover "$_v_kind"
    _v_before=$(v_snap)
    _v_cmds="start post-process interactive"
    [ "$_v_kind" = work ] && _v_cmds="start"
    for _v_cmd in $_v_cmds; do
        _v_rc=0
        if [ "$_v_cmd" = interactive ]; then
            _v_out=$(v_run interactive --agent-index 1) || _v_rc=$?
        else
            _v_out=$(v_run "$_v_cmd") || _v_rc=$?
        fi
        assert_eq "$_v_kind left: $_v_cmd refused" "1" "$_v_rc"
        if [ "$_v_cmd" = start ]; then
            assert_eq "$_v_kind left: $_v_cmd names the clean runtime rule" \
                "true" "$(v_has \
                    "a new engagement starts only on a clean runtime" \
                    "$_v_out")"
            assert_eq "$_v_kind left: $_v_cmd gives the way out" "true" \
                "$(v_has "then ./launch.sh cleanup" "$_v_out")"
        else
            assert_eq "$_v_kind left: $_v_cmd finds it incomplete" "true" \
                "$(v_has "is incomplete: $V_RT/upstream.git" "$_v_out")"
            assert_eq "$_v_kind left: $_v_cmd gives the way out" "true" \
                "$(v_has "Run ./launch.sh cleanup" "$_v_out")"
        fi
        assert_eq "$_v_kind left: $_v_cmd changes nothing" "$_v_before" \
            "$(v_snap)"
        assert_eq "$_v_kind left: $_v_cmd makes nothing in Docker" "0" \
            "$(v_writes)"
        if [ "$_v_kind" = work ]; then
            assert_eq "agent work the checkout lacks is named" "true" \
                "$(v_has "agent-work $(cut -c1-12 "$_v_root/work-commit"): run ./harvest.sh" "$_v_out")"
        fi
    done
done
kill "$_v_live" 2>/dev/null || true
wait "$_v_live" 2>/dev/null || true
# A bare repo whose work the checkout has: refused, without that list.
v_new
v_run start >/dev/null || true
: > "$V_DIR/log"
_v_before=$(v_snap)
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "a second start on the same runtime is refused" "1" "$_v_rc"
assert_eq "naming the bare repo" "true" \
    "$(v_has "  $V_RT/upstream.git" "$_v_out")"
assert_eq "with nothing to harvest listed" "false" \
    "$(v_has "does not contain this agent work" "$_v_out")"
assert_eq "and changes nothing" "$_v_before" "$(v_snap)"
assert_eq "nor makes anything in Docker" "0" "$(v_writes)"

# Listings that fail refuse, after the lock and before anything is
# made.
for _v_case in ps3:"cannot list Docker containers" \
        volume-ls:"cannot list Docker volumes"; do
    v_new
    echo "${_v_case%%:*}" > "$V_DIR/fail"
    _v_rc=0
    _v_out=$(v_run start) || _v_rc=$?
    assert_eq "${_v_case%%:*} fails: start refused" "1" "$_v_rc"
    assert_eq "${_v_case%%:*} fails: saying so" "true" \
        "$(v_has "${_v_case#*:}" "$_v_out")"
    assert_eq "${_v_case%%:*} fails: in the gate (the runtime is claimed)" \
        "true" "$(jq -e '.repo_root != null' "$V_STATE" >/dev/null 2>&1 \
            && echo true || echo false)"
    assert_eq "${_v_case%%:*} fails: no engagement made" "" \
        "$(jq -r '.engagement_id // empty' "$V_STATE" 2>/dev/null)"
    assert_eq "${_v_case%%:*} fails: nothing made in Docker" "0" \
        "$(v_writes)"
done

# --- creation stopped half way ------------------------------------------
# The clone fails: only the .new it made goes; the engagement stays
# recorded, so the next start refuses until cleanup finishes it.
_v_git="$TMPDIR/v55-git"
mkdir -p "$_v_git"
cat > "$_v_git/git" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        *upstream.git.new)
            if [ "\$1" = clone ]; then
                mkdir -p "\$a/objects" && echo partial > "\$a/objects/x"
                exit 128
            fi ;;
    esac
done
exec "$(command -v git)" "\$@"
EOF
chmod +x "$_v_git/git"
v_new
_v_rc=0
_v_out=$(PATH="$_v_git:$PATH" v_run start) || _v_rc=$?
assert_eq "a clone that fails stops start" "1" "$_v_rc"
assert_eq "its upstream.git.new is removed" "false" \
    "$([ -e "$V_RT/upstream.git.new" ] && echo true || echo false)"
assert_eq "no bare repo is left" "false" \
    "$([ -e "$V_RT/upstream.git" ] && echo true || echo false)"
assert_eq "the engagement was recorded first" "true" \
    "$([ -n "$(jq -r '.engagement_id // empty' "$V_STATE" 2>/dev/null)" ] \
        && echo true || echo false)"
assert_eq "no container was started" "0" \
    "$(grep -c '|run ' "$V_DIR/log" || true)"
_v_before=$(v_snap)
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "the next start refuses" "1" "$_v_rc"
assert_eq "naming the engagement still recorded" "true" \
    "$(v_has "still records engagement" "$_v_out")"
assert_eq "and the way out" "true" \
    "$(v_has "Run ./launch.sh cleanup" "$_v_out")"
assert_eq "and changes nothing" "$_v_before" "$(v_snap)"
assert_eq "nor makes anything in Docker" "0" "$(v_writes)"
_v_rc=0
v_run cleanup > "$_v_root/cleanup.out" || _v_rc=$?
assert_eq "cleanup finishes that engagement" "0" "$_v_rc"
assert_eq "its record goes" "" \
    "$(jq -r '.engagement_id // empty' "$V_STATE" 2>/dev/null)"
_v_rc=0
v_run start >/dev/null || _v_rc=$?
assert_eq "then a start works" "0" "$_v_rc"

# --- only a complete engagement is joined -------------------------------
# swarm_bare_repo_ready: a bare repository at that very path, given to
# Git explicitly, whose HEAD names a commit.
_rb="$_v_root/ready"
mkdir -p "$_rb"
git clone -q --bare "$_st_repo" "$_rb/bare.git"
ln -s "$_rb/bare.git" "$_rb/link.git"
mkdir "$_rb/empty.git" "$_st_repo/inside.git"
git clone -q "$_st_repo" "$_rb/work.git"
git init -q --bare "$_rb/unborn.git"
rb() {
    swarm_bare_repo_ready "$1" && echo ready || echo no
}
assert_eq "a bare repo is ready" ready "$(rb "$_rb/bare.git")"
assert_eq "a missing path is not" no "$(rb "$_rb/missing.git")"
assert_eq "a link to a bare repo is not" no "$(rb "$_rb/link.git")"
assert_eq "an empty directory is not" no "$(rb "$_rb/empty.git")"
assert_eq "nor one inside another repository (no discovery)" no \
    "$(rb "$_st_repo/inside.git")"
assert_eq "a repository with a work tree is not" no "$(rb "$_rb/work.git")"
assert_eq "its git dir is not bare either" no "$(rb "$_rb/work.git/.git")"
assert_eq "a bare repo whose HEAD names no commit is not" no \
    "$(rb "$_rb/unborn.git")"
assert_eq "the caller's GIT_DIR does not stand in" no \
    "$(GIT_DIR="$_rb/bare.git" rb "$_rb/empty.git")"
assert_eq "nor its GIT_OBJECT_DIRECTORY get in the way" ready \
    "$(GIT_OBJECT_DIRECTORY="$_rb/empty.git" rb "$_rb/bare.git")"
rmdir "$_st_repo/inside.git"
# Agents can write the bare repo.  A config that includes another file
# is refused before Git reads it (an include of a FIFO would block the
# read; a regular file here, so that following it fails the test rather
# than hanging it), and a FIFO where Git reads makes the read end once
# its time is up.
git clone -q --bare "$_st_repo" "$_rb/include.git"
printf '[core]\n\tbare = true\n' > "$_rb/include.git/extra"
git config -f "$_rb/include.git/config" include.path extra
assert_eq "a bare repo whose config includes another file is not" no \
    "$(rb "$_rb/include.git" 2>/dev/null)"
assert_eq "saying so" 1 \
    "$(rb "$_rb/include.git" 2>&1 >/dev/null \
        | grep -c 'config includes other files' || true)"
git clone -q --bare "$_st_repo" "$_rb/fifo.git"
rm "$_rb/fifo.git/HEAD"
mkfifo "$_rb/fifo.git/HEAD"
# In the background, watched: a read that never ends would hang the
# tests.
(
    _SWARM_GIT_READ_SECS=1
    rb "$_rb/fifo.git" > "$TMPDIR/rb-fifo.out" 2>/dev/null
) &
_rb_pid=$!
_rb_i=0
while kill -0 "$_rb_pid" 2>/dev/null && [ "$_rb_i" -lt 150 ]; do
    sleep 0.1
    _rb_i=$((_rb_i + 1))
done
if kill -0 "$_rb_pid" 2>/dev/null; then
    # Still reading: a writer opening the FIFO lets the read end.
    perl -e 'alarm 5; open(my $f, ">", $ARGV[0])' "$_rb/fifo.git/HEAD" \
        || true
    _rb_fifo=hung
else
    _rb_fifo=$(cat "$TMPDIR/rb-fifo.out")
fi
wait "$_rb_pid" 2>/dev/null || true
assert_eq "a bare repo whose HEAD is a FIFO is not, once the read times out" \
    no "$_rb_fifo"
# Each of these reads is bounded: a git that does not return (here a
# stand-in that sleeps on the call named, and runs Git otherwise) ends
# within a second or two (under 15 s allows for a slow host; without
# the bound it takes 30).
_rb_slow="$TMPDIR/rb-slow"
mkdir -p "$_rb_slow"
cat > "$_rb_slow/git" <<'EOF'
#!/bin/sh
for a in "$@"; do
    [ "$a" = "$RB_SLOW_ON" ] && exec sleep 30
done
exec "$RB_REAL_GIT" "$@"
EOF
chmod +x "$_rb_slow/git"
_rb_git=$(command -v git)
rb_slow() {  # ARGUMENT REPO: the result, then 1 when it took under 15 s
    local t0=$SECONDS out
    out=$(PATH="$_rb_slow:$PATH" RB_SLOW_ON="$1" RB_REAL_GIT="$_rb_git" \
        _SWARM_GIT_READ_SECS=1 rb "$2" 2>"$TMPDIR/rb-slow.err")
    echo "$out $((SECONDS - t0 < 15))"
}
assert_eq "a config check that does not return ends" "no 1" \
    "$(rb_slow --get-regexp "$_rb/bare.git")"
assert_eq "saying it took too long" 1 \
    "$(grep -c 'took over 1 seconds' "$TMPDIR/rb-slow.err" || true)"
assert_eq "a bare repository check that does not return ends" "no 1" \
    "$(rb_slow --is-bare-repository "$_rb/bare.git")"
assert_eq "a HEAD commit check that does not return ends" "no 1" \
    "$(rb_slow --verify "$_rb/bare.git")"
assert_eq "with the stand-in sleeping on nothing, it is ready" "ready 1" \
    "$(rb_slow --no-such-argument "$_rb/bare.git")"
assert_eq "each read gets 60 seconds (as CHANGELOG.md says)" 60 \
    "$_SWARM_GIT_READ_SECS"
# The bound holds where the caller ignores SIGALRM.
assert_eq "swarm_bounded ends a command whose SIGALRM was ignored" "142 1" \
    "$(trap '' ALRM
        _t0=$SECONDS _rc=0
        swarm_bounded 1 sleep 30 || _rc=$?
        echo "$_rc $((SECONDS - _t0 < 15))")"
# And where it comes blocked (a signal mask exec passes on).
assert_eq "swarm_bounded ends a command whose SIGALRM was blocked" "142 1" \
    "$(perl -MPOSIX -e 'sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGALRM))
            or exit 126; exec @ARGV' \
        "$BASH" -c 'source "$1"; t0=$SECONDS rc=0
            swarm_bounded 1 sleep 30 2>/dev/null || rc=$?
            echo "$rc $((SECONDS - t0 < 15))"' _ "$TESTS_DIR/../lib/project.sh")"
# Git reads no stdin here, even with its global config there (a pipe
# that never ends would hold the read until the bound).
assert_eq "Git's reads get no stdin" "ready" \
    "$(yes '' | GIT_CONFIG_GLOBAL=/dev/stdin _SWARM_GIT_READ_SECS=2 \
        rb "$_rb/bare.git" 2>/dev/null)"

# A recorded engagement whose bare repo is KIND: missing (state, with
# nothing else left either), a link, an empty directory, a repository
# with a work tree, a bare repo with no commit, one whose config
# includes another file.
v_incomplete() {
    v_new
    v_run start >/dev/null || true
    rm -rf "$V_RT/upstream.git" "$V_RT/mirrors"
    rm -f "$V_RT"/interactive-*.pending
    case "$1" in
        link)
            git clone -q --bare "$_st_repo" "$_v_root/elsewhere-$_v_n.git"
            ln -s "$_v_root/elsewhere-$_v_n.git" "$V_RT/upstream.git" ;;
        empty) mkdir "$V_RT/upstream.git" ;;
        worktree) git clone -q "$_st_repo" "$V_RT/upstream.git" ;;
        unborn) git init -q --bare "$V_RT/upstream.git" ;;
        include)
            git clone -q --bare "$_st_repo" "$V_RT/upstream.git"
            printf '[core]\n\tbare = true\n' > "$V_RT/upstream.git/extra"
            git config -f "$V_RT/upstream.git/config" include.path extra ;;
    esac
    : > "$V_DIR/log"
}
for _v_kind in state link empty worktree unborn include; do
    v_incomplete "$_v_kind"
    _v_before=$(v_snap)
    for _v_cmd in post-process "interactive --agent-index 1"; do
        _v_rc=0
        # shellcheck disable=SC2086
        _v_out=$(v_run $_v_cmd) || _v_rc=$?
        assert_eq "bare repo $_v_kind: $_v_cmd refused" "1" "$_v_rc"
        assert_eq "bare repo $_v_kind: $_v_cmd finds it incomplete" "true" \
            "$(v_has "is incomplete: $V_RT/upstream.git" "$_v_out")"
        assert_eq "bare repo $_v_kind: $_v_cmd changes nothing" \
            "$_v_before" "$(v_snap)"
        assert_eq "bare repo $_v_kind: $_v_cmd makes nothing in Docker" "0" \
            "$(v_writes)"
    done
done
# A record with nothing left: start refuses it too.
v_incomplete state
_v_before=$(v_snap)
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "a record alone: start refused" "1" "$_v_rc"
assert_eq "a record alone: start names it" "true" \
    "$(v_has "still records engagement" "$_v_out")"
assert_eq "a record alone: start changes nothing" "$_v_before" "$(v_snap)"
assert_eq "a record alone: start makes nothing in Docker" "0" "$(v_writes)"

# wait: once the agents are done, an incomplete engagement stops it
# before post-process, and before harvest without one.
_v_tok_saved="$_v_tok"
for _v_cfg in post harvest; do
    v_incomplete state
    # Agents of this engagement, done.
    _v_tok=$(jq -r .engagement_token "$V_STATE" 2>/dev/null)
    v_agents exited
    _v_cfg_saved="$V_CFG"
    if [ "$_v_cfg" = harvest ]; then
        V_CFG="$_v_root/no-post.json"
        jq 'del(.post_process)' "$_v_cfg_saved" > "$V_CFG"
    fi
    _v_rc=0
    _v_out=$(v_run wait) || _v_rc=$?
    V_CFG="$_v_cfg_saved"
    assert_eq "wait ($_v_cfg next), incomplete engagement: refused" "1" \
        "$_v_rc"
    assert_eq "wait ($_v_cfg next): finds it incomplete" "true" \
        "$(v_has "is incomplete: $V_RT/upstream.git" "$_v_out")"
    assert_eq "wait ($_v_cfg next): no post-process starts" "0" \
        "$(grep -c '|run ' "$V_DIR/log" || true)"
    assert_eq "wait ($_v_cfg next): no harvest" "false" \
        "$(v_has "Harvesting results" "$_v_out")"
    assert_eq "wait ($_v_cfg next): it listed this engagement's agents" \
        "true" "$(v_has "0 running, 2 exited" "$_v_out")"
done
_v_tok="$_v_tok_saved"

# The bare repo is mounted with --mount, which fails on a missing source
# rather than making one, at each docker run that mounts it.
v_new
v_run start >/dev/null || true
assert_eq "start mounts the bare repo with --mount" "2" \
    "$(grep -cF -- "--mount type=bind,src=$V_RT/upstream.git,dst=/upstream" \
        "$V_DIR/log" || true)"
v_agents exited
: > "$V_DIR/log"
v_run post-process >/dev/null || true
assert_eq "post-process mounts it with --mount" "1" \
    "$(grep -cF -- "--mount type=bind,src=$V_RT/upstream.git,dst=/upstream" \
        "$V_DIR/log" || true)"
: > "$V_DIR/log"
v_run interactive --agent-index 1 >/dev/null || true
assert_eq "interactive mounts it with --mount" "1" \
    "$(grep -cF -- "--mount type=bind,src=$V_RT/upstream.git,dst=/upstream" \
        "$V_DIR/log" || true)"
assert_eq "and no -v names /upstream any more" "0" \
    "$(grep -c ':/upstream' "$_LAUNCH_SH" || true)"
_v_cfg_saved="$V_CFG"

# --- docker_args: the exact vector, first, checked before anything -----
# Each docker run gets docker_args exactly (argument boundaries kept, as
# the fake's JSON log of each run shows) right after "run", before every
# argument the engine sets.
_v_cfg_da="$_v_root/da-exact.json"
jq '.docker_args = ["--label", "a b=c d", "--env", "X= y", "-e", "Z",
    "--network=host"]' "$_v_cfg_saved" > "$_v_cfg_da"
_v_cfg_saved="$V_CFG"
V_CFG="$_v_cfg_da"
v_new
v_run start >/dev/null || true
_v_da_want='["--label","a b=c d","--env","X= y","-e","Z","--network=host"]'
assert_eq "each agent's run gets docker_args exactly, right after run" "2" \
    "$(jq -c --argjson w "$_v_da_want" \
        'select(.[0] == "run" and .[1:8] == $w and .[8] == "-d")' \
        "$V_DIR/argv.jsonl" | grep -c . || true)"
v_agents exited
: > "$V_DIR/argv.jsonl"
# (The fake's docker run fails here, after logging: post-process ends at
# once instead of waiting for a container the fake never makes.)
echo run > "$V_DIR/fail"
v_run post-process >/dev/null || true
rm -f "$V_DIR/fail"
assert_eq "post-process's too" "1" \
    "$(jq -c --argjson w "$_v_da_want" \
        'select(.[0] == "run" and .[1:8] == $w and .[8] == "-d")' \
        "$V_DIR/argv.jsonl" | grep -c . || true)"
: > "$V_DIR/argv.jsonl"
v_run interactive --agent-index 1 >/dev/null || true
assert_eq "and interactive's, -it after them" "1" \
    "$(jq -c --argjson w "$_v_da_want" \
        'select(.[0] == "run" and .[1:8] == $w and .[8] == "-it")' \
        "$V_DIR/argv.jsonl" | grep -c . || true)"
V_CFG="$_v_cfg_saved"

# Absent, null and empty docker_args: the engine's arguments right after
# run, at each launch.
for _v_da in absent null empty; do
    _v_cfg_da="$_v_root/da-$_v_da.json"
    case "$_v_da" in
        absent) jq 'del(.docker_args)' "$_v_cfg_saved" > "$_v_cfg_da" ;;
        null) jq '.docker_args = null' "$_v_cfg_saved" > "$_v_cfg_da" ;;
        empty) jq '.docker_args = []' "$_v_cfg_saved" > "$_v_cfg_da" ;;
    esac
    V_CFG="$_v_cfg_da"
    v_new
    _v_rc=0
    v_run start >/dev/null || _v_rc=$?
    assert_eq "docker_args $_v_da: start works" "0" "$_v_rc"
    v_agents exited
    echo run > "$V_DIR/fail"
    _v_rc=0
    v_run post-process >/dev/null || _v_rc=$?
    rm -f "$V_DIR/fail"
    assert_eq "docker_args $_v_da: post-process gets to docker run" "125" \
        "$_v_rc"
    v_run interactive --agent-index 1 >/dev/null || true
    assert_eq "docker_args $_v_da: -d or -it right after run, each time" \
        "-d -d -d -it" \
        "$(jq -r '.[1]' "$V_DIR/argv.jsonl" | tr '\n' ' ' | sed 's/ $//')"
    V_CFG="$_v_cfg_saved"
done

# A bad docker_args stops start, post-process, interactive, chat and
# shell before they prepare anything: no runtime directory, nothing in
# Docker.
_v_cfg_bad="$_v_root/da-bad.json"
jq '.docker_args = ["--rm", "-it"]' "$_v_cfg_saved" > "$_v_cfg_bad"
V_CFG="$_v_cfg_bad"
for _v_cmd in start post-process "interactive --agent-index 1" \
        "chat --agent-index 1" "shell --agent-index 1"; do
    v_new
    _v_rc=0
    # shellcheck disable=SC2086
    _v_out=$(v_run $_v_cmd) || _v_rc=$?
    assert_eq "bad docker_args: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "bad docker_args: $_v_cmd says why" "true" \
        "$(v_has "docker_args element 2 (-it) groups short options" \
            "$_v_out")"
    assert_eq "bad docker_args: $_v_cmd prepares nothing" "no" \
        "$([ -e "$V_RT" ] && echo yes || echo no)"
    assert_eq "bad docker_args: $_v_cmd makes nothing in Docker" "0" \
        "$(v_writes)"
done
V_CFG="$_v_cfg_saved"

# wait reads docker_args only when it goes on to post-process; stop,
# status and logs never do.
v_new
v_run start >/dev/null || true
v_agents exited
_v_tok_saved="$_v_tok"
_v_tok=$(jq -r .engagement_token "$V_STATE" 2>/dev/null)
v_agents exited
V_CFG="$_v_cfg_bad"
: > "$V_DIR/log"
_v_rc=0
_v_out=$(v_run wait) || _v_rc=$?
assert_eq "wait on to post-process: a bad docker_args stops it" "1" "$_v_rc"
assert_eq "  saying why" "true" \
    "$(v_has "docker_args element 2 (-it) groups short options" "$_v_out")"
assert_eq "  before any run" "0" "$(grep -c '|run ' "$V_DIR/log" || true)"
V_CFG="$_v_root/da-bad-harvest.json"
jq 'del(.post_process)' "$_v_cfg_bad" > "$V_CFG"
_v_out=$(v_run wait) || true
assert_eq "wait on to harvest: docker_args not read" "false" \
    "$(v_has "docker_args" "$_v_out")"
assert_eq "  it goes on to harvest" "true" \
    "$(v_has "Harvesting results" "$_v_out")"
V_CFG="$_v_root/da-not-array.json"
jq '.docker_args = "-it"' "$_v_cfg_saved" > "$V_CFG"
for _v_cmd in stop status "logs 1"; do
    # shellcheck disable=SC2086
    _v_out=$(v_run $_v_cmd) || true
    assert_eq "$_v_cmd ignores docker_args" "false" \
        "$(v_has "docker_args" "$_v_out")"
done
V_CFG="$_v_cfg_saved"
_v_tok="$_v_tok_saved"

# What C5 will restrict passes for now: TARGET_* in -e, --env-file,
# --volumes-from.
V_CFG="$_v_root/da-later.json"
jq '.docker_args = ["-e", "TARGET_REPO", "-e", "TARGET_REV=main",
    "--env-file", "/dev/null", "--volumes-from", "other"]' \
    "$_v_cfg_saved" > "$V_CFG"
v_new
_v_rc=0
v_run start >/dev/null || _v_rc=$?
assert_eq "TARGET_* in -e, --env-file, --volumes-from: start works" "0" \
    "$_v_rc"
assert_eq "  and they reach docker run" "2" \
    "$(jq -c 'select(.[0] == "run" and .[1:9] == ["-e", "TARGET_REPO",
        "-e", "TARGET_REV=main", "--env-file", "/dev/null",
        "--volumes-from", "other"])' "$V_DIR/argv.jsonl" \
        | grep -c . || true)"
V_CFG="$_v_cfg_saved"

# A run killed during the clone leaves upstream.git.new: the gate
# refuses it (cleanup preserves and removes it, see test_cleanup.sh).
v_leftover new
_v_out=$(v_run start || true)
assert_eq "a .new left by a killed run is named" "true" \
    "$(v_has "  $V_RT/upstream.git.new" "$_v_out")"

# A failed image build leaves the runtime clean too.
v_new
echo build > "$V_DIR/fail"
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
rm -f "$V_DIR/fail"
assert_eq "a failed image build stops start" "1" "$_v_rc"
assert_eq "before an engagement is recorded" "" \
    "$(jq -r '.engagement_id // empty' "$V_STATE" 2>/dev/null)"
assert_eq "and before a bare repo is made" "false" \
    "$([ -e "$V_RT/upstream.git" ] && echo true || echo false)"
_v_rc=0
v_run start >/dev/null || _v_rc=$?
assert_eq "the next start works" "0" "$_v_rc"

# --- a runtime inside the checkout ----------------------------------
v_new
V_RT="$_st_repo/.swarm-v55"
V_STATE="$V_RT/state.json"
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "a runtime inside the checkout: start refused" "1" "$_v_rc"
assert_eq "saying so" "true" \
    "$(v_has "is inside the checkout or its git dir" "$_v_out")"
assert_eq "and nothing is made there" "false" \
    "$([ -e "$V_RT" ] && echo true || echo false)"
assert_eq "nor in Docker" "0" "$(v_writes)"

# --- an engagement of an earlier release ------------------------------
# Its state file records no daemon and no token, and its containers
# (one started with --rm, one with an anonymous /workspace volume) keep
# their files themselves.  Every command but status and logs refuses
# it, says how to finish it, and changes nothing.
v_new
v_run start >/dev/null || true
jq -c 'del(.docker_daemon, .engagement_token)' "$V_STATE" \
    > "$V_STATE.x" && mv "$V_STATE.x" "$V_STATE"
find "$V_DIR/vols" -type f -exec rm -f {} +
v_container "${_v_img}-1" running ""
v_container "${_v_img}-2" running ""
v_container "${_v_img}-post" exited ""
v_container "${_v_img}-interactive-x-20260101000000-0" running ""
: > "$V_DIR/log"
_v_before=$(v_snap)
for _v_cmd in start post-process "interactive --agent-index 1" stop wait \
        retire cleanup; do
    _v_rc=0
    # shellcheck disable=SC2086
    _v_out=$(v_run $_v_cmd) || _v_rc=$?
    assert_eq "earlier release: $_v_cmd refused" "1" "$_v_rc"
    assert_eq "earlier release: $_v_cmd says how to finish it" "true" \
        "$(v_has "Finish it with the release that made it" "$_v_out")"
    assert_eq "earlier release: $_v_cmd changes nothing" "$_v_before" \
        "$(v_snap)"
    assert_eq "earlier release: $_v_cmd stops, removes or makes nothing" \
        "0" "$(v_writes)"
done
_v_rc=0
_v_out=$(v_run status) || _v_rc=$?
assert_eq "earlier release: status still answers" "0" "$_v_rc"
assert_eq "with the agents' states" "true" \
    "$(v_has "running" "$_v_out")"
_v_rc=0
v_run logs 1 >/dev/null || _v_rc=$?
assert_eq "earlier release: logs still answer" "0" "$_v_rc"
assert_eq "earlier release: the runtime is as it was" "$_v_before" \
    "$(v_snap)"

# Leftovers with no engagement recorded come from an earlier release.
v_new
v_run start >/dev/null || true
jq -c 'del(.engagement_id, .engagement_started_at, .base_commit,
    .docker_daemon, .engagement_token)' "$V_STATE" \
    > "$V_STATE.x" && mv "$V_STATE.x" "$V_STATE"
: > "$V_DIR/log"
_v_before=$(v_snap)
_v_rc=0
_v_out=$(v_run start) || _v_rc=$?
assert_eq "leftovers without an engagement: start refused" "1" "$_v_rc"
assert_eq "as an earlier release's" "true" \
    "$(v_has "Finish it with the release that made it" "$_v_out")"
assert_eq "naming what is left" "true" \
    "$(v_has "  $V_RT/upstream.git" "$_v_out")"
assert_eq "and changes nothing" "$_v_before" "$(v_snap)"

# --- launch.sh removes nothing by force ---------------------------------
assert_eq "launch.sh has no docker rm -f" "0" \
    "$(grep -c 'docker rm -f' "$_LAUNCH_SH" || true)"
assert_eq "no alpine helper" "0" "$(grep -c 'alpine' "$_LAUNCH_SH" || true)"
assert_eq "no rm_docker_dir" "0" \
    "$(grep -c 'rm_docker_dir' "$_LAUNCH_SH" || true)"

# A session record is never written over another.
_v_pd="$_v_root/pending"
mkdir -p "$_v_pd"
swarm_pending_write "$_v_pd" "${_v_img}-interactive-y-1" "$$" daemon-a
_v_rec=$(cat "$_v_pd/interactive-${_v_img}-interactive-y-1.pending")
_v_rc=0
swarm_pending_write "$_v_pd" "${_v_img}-interactive-y-1" 1 daemon-b \
    2>/dev/null || _v_rc=$?
assert_eq "a second record of the same name is refused" "1" "$_v_rc"
assert_eq "and the first stays as it was" "$_v_rec" \
    "$(cat "$_v_pd/interactive-${_v_img}-interactive-y-1.pending")"

# ============================================================
echo ""
echo "=== 56. A run stopped on an unset variable does not end with 0 ==="

# Bash 3.2 (macOS's /bin/bash, which runs these tests there) runs an
# EXIT trap with $? at 0 when set -u stops the script on an unset
# variable.  A flock that names one, through BASH_ENV, stops launch.sh in
# swarm_lock, in the main shell and after its EXIT trap is set.
_u_hook="$TMPDIR/unset-hook.sh"
cat > "$_u_hook" <<'EOF'
flock() { : "$swarm_test_unset_variable"; }
EOF
v_new
_v_rc=0
_v_out=$(BASH_ENV="$_u_hook" v_run start) || _v_rc=$?
assert_eq "start stopped on an unset variable: not status 0" "true" \
    "$([ "$_v_rc" -ne 0 ] && echo true || echo false)"
assert_eq "having made no engagement" "" \
    "$(jq -r '.engagement_id // empty' "$V_STATE" 2>/dev/null)"
# The ends a run means keep status 0: help, and a run's last line.
_v_rc=0
v_run interactive --help >/dev/null || _v_rc=$?
assert_eq "interactive --help ends with 0" "0" "$_v_rc"
_v_rc=0
v_run status >/dev/null || _v_rc=$?
assert_eq "status ends with 0" "0" "$_v_rc"

# The check is made only on Bash before 4.1 (swarm_stop_guard_needed):
# later versions end a run that set -u stops with a nonzero status
# themselves, and every version can run the EXIT trap with $? at 0 when
# a signal ends the script.
_sg_guard() {
    if swarm_stop_guard_needed "$1" "$2"; then echo yes; else echo no; fi
}
_sg_all="$(_sg_guard 3 2) $(_sg_guard 4 0) $(_sg_guard 4 1)"
_sg_all="$_sg_all $(_sg_guard 4 4) $(_sg_guard 5 2) $(_sg_guard 10 0)"
assert_eq "the check is made on Bash 3.2 and 4.0, not from 4.1 on" \
    "yes yes no no no no" "$_sg_all"
# Every Bash the runner has: /bin/bash, and on macOS the Homebrew bash
# (required on CI).
_sg_bashes="/bin/bash"
_sg_brew=""
if command -v brew >/dev/null 2>&1; then
    _sg_brew="$(brew --prefix)/bin/bash"
fi
if [ -n "$_sg_brew" ] && [ -x "$_sg_brew" ]; then
    _sg_bashes="$_sg_bashes $_sg_brew"
elif [ "$(uname)" = Darwin ]; then
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has the Homebrew bash" "yes" "no"
    else
        echo "  SKIP: no Homebrew bash, so only /bin/bash is checked"
    fi
fi
# launch.sh's EXIT trap and its temp-file cleanup, extracted, in a child
# Bash with the version test stubbed both ways: a run that ends without
# the flag prints the line and ends with 1 only where the check is made;
# the flag, or another status, is kept; the temp files go every time.
_sg_extract() {  # FUNCTION FILE
    awk -v f="$1" '$0 ~ "^" f "\\(\\)[[:space:]]*\\{" { p = 1 }
         p { print }
         p && /^\}[[:space:]]*$/ { exit }' "$2"
}
{
    _sg_extract swarm_tmp_cleanup "$_LAUNCH_SH"
    _sg_extract swarm_exit_trap "$_LAUNCH_SH"
} > "$TMPDIR/sg-trap.sh"
assert_eq "launch.sh's trap and its cleanup are extracted" "2" \
    "$(grep -cE '^(swarm_tmp_cleanup|swarm_exit_trap)\(\)' \
        "$TMPDIR/sg-trap.sh")"
_sg_run() {  # BASH NEEDED(0 yes, 1 no) END
    mkdir -p "$TMPDIR/sg-files"
    : > "$TMPDIR/sg-files/a"
    : > "$TMPDIR/sg-files/b"
    cat > "$TMPDIR/sg-run.sh" <<EOF
set -euo pipefail
SWARM_TMP_FILES=("$TMPDIR/sg-files/a" "$TMPDIR/sg-files/b")
SWARM_EXIT_OK=false
# shellcheck source=/dev/null
source "$TMPDIR/sg-trap.sh"
swarm_stop_guard_needed() { return $2; }
trap swarm_exit_trap EXIT
$3
EOF
    "$1" "$TMPDIR/sg-run.sh" 2>&1
}
_sg_gone() {
    if [ -e "$TMPDIR/sg-files/a" ] || [ -e "$TMPDIR/sg-files/b" ]; then
        echo no
    else
        echo yes
    fi
}
_sg_line='launch.sh stopped before the end of its run'
for _sg_b in $_sg_bashes; do
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 0 ':') || _sg_rc=$?
    assert_eq "$_sg_b: no flag where the check is made: status 1" "1" \
        "$_sg_rc"
    assert_eq "$_sg_b:   saying so once" "1" \
        "$(grep -c "$_sg_line" <<< "$_sg_out")"
    assert_eq "$_sg_b:   the temp files go" "yes" "$(_sg_gone)"
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 1 ':') || _sg_rc=$?
    assert_eq "$_sg_b: no flag where it is not: status 0" "0" "$_sg_rc"
    assert_eq "$_sg_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_sg_out")"
    assert_eq "$_sg_b:   the temp files go" "yes" "$(_sg_gone)"
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 0 'SWARM_EXIT_OK=true') || _sg_rc=$?
    assert_eq "$_sg_b: the flag: status 0" "0" "$_sg_rc"
    assert_eq "$_sg_b:   no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_sg_out")"
    assert_eq "$_sg_b:   the temp files go" "yes" "$(_sg_gone)"
    _sg_rc=0
    _sg_out=$(_sg_run "$_sg_b" 0 'exit 3') || _sg_rc=$?
    assert_eq "$_sg_b: another status stays" "3" "$_sg_rc"
    assert_eq "$_sg_b:   with no line" "0" \
        "$(grep -c 'stopped before the end' <<< "$_sg_out")"
    assert_eq "$_sg_b:   the temp files go" "yes" "$(_sg_gone)"
done
# End to end: SIGTERM and SIGHUP to launch.sh start while it waits in
# docker build (the hold-build knob), which comes after its EXIT trap is
# set and after it made its agents file, a temp file in TMPDIR.  python3
# starts the run in a session of its own, signals launch.sh only, then
# lets the held fake go (Bash may hold the signal until it returns), and
# kills the whole session at the end.  On Bash 4.1 and later no line, on
# earlier versions the line; death by the signal and the temp file gone
# on every version.
_sg_py=yes
if ! command -v python3 >/dev/null 2>&1; then
    _sg_py=no
    if [ -n "${CI:-}" ]; then
        assert_eq "CI has python3" "yes" "no"
    else
        echo "  SKIP: no python3, so no signal is sent"
    fi
fi
cat > "$TMPDIR/sg-sigrun.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
bash, script, cwd, ready, errfile, signame, watch = sys.argv[1:8]
args = sys.argv[8:]
def made():
    return "yes" if glob.glob(watch) else "no"
p = None
held = None
def release(sig=signal.SIGTERM):
    # The held command traps SIGTERM and exits with 0.
    if held is not None:
        try:
            os.kill(held, sig)
        except ProcessLookupError:
            pass
def killgroup():
    release(signal.SIGKILL)
    if p is None:
        return
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
# A TERM, HUP or INT to this supervisor (a test run cancelled) ends it
# through the finally block, which kills the run's session.  They are
# blocked while the run is made, and unblocked in the run before exec.
def stop(signum, frame):
    raise SystemExit(128 + signum)
caught = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
for s in caught:
    signal.signal(s, stop)
try:
    signal.pthread_sigmask(signal.SIG_BLOCK, caught)
    try:
        with open(errfile, "w") as err:
            p = subprocess.Popen(
                [bash, script] + args, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=err,
                start_new_session=True,
                preexec_fn=lambda: signal.pthread_sigmask(
                    signal.SIG_UNBLOCK, caught))
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, caught)
    deadline = time.time() + 20
    while time.time() < deadline and not os.path.exists(ready):
        if p.poll() is not None:
            break
        time.sleep(0.1)
    if not os.path.exists(ready):
        print("ready no")
        sys.exit(0)
    with open(ready) as f:
        held = int(f.read().strip())
    print("ready yes")
    print("before", made())
    # Then let the held command end with 0 at once: whether Bash acts
    # on its signal before or after it sees that end, the status it
    # has is 0, as it would be in a run the signal stops there.
    os.kill(p.pid, getattr(signal, signame))
    release()
    try:
        rc = p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        print("rc timeout")
        sys.exit(0)
    print("rc", rc)
    print("after", made())
finally:
    killgroup()
EOF
if [ "$_sg_py" = yes ]; then
    for _sg_b in $_sg_bashes; do
        _sg_v=$("$_sg_b" -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"')
        # shellcheck disable=SC2086  # major and minor as two words
        if [ "$(_sg_guard $_sg_v)" = yes ]; then _sg_n=1; else _sg_n=0; fi
        for _sg_sig in TERM:-15 HUP:-1; do
            _sg_name="$_sg_b, SIG${_sg_sig%%:*}"
            v_new
            touch "$V_DIR/hold-build"
            mkdir "$V_DIR/tmp"
            _sg_out=$(cd "$_st_repo" && env PATH="$_v_bin:$PATH" \
                V_DIR="$V_DIR" V_STATE="$V_STATE" SWARM_RUNTIME_DIR="$V_RT" \
                SWARM_CONFIG="$V_CFG" SWARM_SKIP_DEP_CHECK=1 \
                SWARM_WAIT_POLL=0 TMPDIR="$V_DIR/tmp" \
                python3 "$TMPDIR/sg-sigrun.py" "$_sg_b" "$_LAUNCH_SH" \
                    "$_st_repo" "$V_DIR/ready" "$V_DIR/err" \
                    "SIG${_sg_sig%%:*}" "$V_DIR/tmp/swarm-agents.*" \
                    start 8>&- 2>&1)
            assert_eq "$_sg_name: start waits in docker build" "yes" \
                "$(sed -n 's/^ready //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   its agents file there" "yes" \
                "$(sed -n 's/^before //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   it dies of the signal" \
                "${_sg_sig#*:}" "$(sed -n 's/^rc //p' <<< "$_sg_out")"
            assert_eq "$_sg_name:   the line only before Bash 4.1" \
                "$_sg_n" "$(grep -c "$_sg_line" "$V_DIR/err" || true)"
            assert_eq "$_sg_name:   the agents file goes" "no" \
                "$(sed -n 's/^after //p' <<< "$_sg_out")"
        done
    done
fi

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
