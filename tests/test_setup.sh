#!/bin/bash
set -euo pipefail

# Unit tests for setup.sh JSON construction logic.
# No Docker, API key, or interactive input required.

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

# --- Helpers: same jq pipeline and auth logic used in setup.sh ---

build_config() {
    local prompt="$1" setup="$2" max_idle="$3"
    local git_name="$4" git_email="$5" agents_json="$6"
    jq -n \
        --arg prompt "$prompt" \
        --arg setup "$setup" \
        --argjson max_idle "$max_idle" \
        --arg git_name "$git_name" \
        --arg git_email "$git_email" \
        --argjson agents "$agents_json" \
        '{
            prompt: $prompt,
            max_idle: $max_idle,
            git_user: { name: $git_name, email: $git_email },
            agents: $agents
        }
        | if $setup != "" then .setup = $setup else . end'
}

add_post_process() {
    local config="$1" pp_prompt="$2" pp_model="$3"
    echo "$config" | jq \
        --arg pp_prompt "$pp_prompt" \
        --arg pp_model "$pp_model" \
        '. + { post_process: { prompt: $pp_prompt, model: $pp_model } }'
}

build_agents_json() {
    local result="[]"
    while [ $# -ge 2 ]; do
        local obj="{\"count\": $1, \"model\": \"$2\"}"
        result=$(echo "$result" | jq --argjson obj "$obj" '. + [$obj]')
        shift 2
    done
    echo "$result"
}

# Mirrors setup.sh credential detection logic.
detect_auth_mode() {
    local api_key="$1" oauth_token="$2"
    if [ -n "$api_key" ] && [ -n "$oauth_token" ]; then
        echo "both"
    elif [ -n "$oauth_token" ]; then
        echo "oauth"
    elif [ -n "$api_key" ]; then
        echo "apikey"
    else
        echo "prompt"
    fi
}

# ============================================================
echo "=== 1. Basic config construction ==="

AGENTS=$(build_agents_json 2 "claude-opus-4-6")
CONFIG=$(build_config "task.md" "" 3 "swarm-agent" "agent@claude-swarm.local" "$AGENTS")

assert_eq "prompt"  "task.md" "$(echo "$CONFIG" | jq -r '.prompt')"
assert_eq "max_idle" "3"      "$(echo "$CONFIG" | jq -r '.max_idle')"
assert_eq "git name" "swarm-agent" "$(echo "$CONFIG" | jq -r '.git_user.name')"
assert_eq "git email" "agent@claude-swarm.local" "$(echo "$CONFIG" | jq -r '.git_user.email')"
assert_eq "agent count" "2"   "$(echo "$CONFIG" | jq '[.agents[].count] | add')"
assert_eq "no setup"   "null" "$(echo "$CONFIG" | jq -r '.setup // "null"')"

# ============================================================
echo ""
echo "=== 2. Config with setup script ==="

AGENTS=$(build_agents_json 1 "claude-sonnet-4-5")
CONFIG=$(build_config "p.md" "setup.sh" 5 "test" "t@t" "$AGENTS")

assert_eq "setup present" "setup.sh" "$(echo "$CONFIG" | jq -r '.setup')"
assert_eq "max_idle"      "5"        "$(echo "$CONFIG" | jq -r '.max_idle')"

# ============================================================
echo ""
echo "=== 3. Multi-group agents ==="

AGENTS=$(build_agents_json 2 "claude-opus-4-6" 3 "claude-sonnet-4-5" 1 "custom-model")
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")

assert_eq "total agents"  "6"  "$(echo "$CONFIG" | jq '[.agents[].count] | add')"
assert_eq "group count"   "3"  "$(echo "$CONFIG" | jq '.agents | length')"
assert_eq "first model"   "claude-opus-4-6"   "$(echo "$CONFIG" | jq -r '.agents[0].model')"
assert_eq "second model"  "claude-sonnet-4-5"  "$(echo "$CONFIG" | jq -r '.agents[1].model')"
assert_eq "third model"   "custom-model"       "$(echo "$CONFIG" | jq -r '.agents[2].model')"

# ============================================================
echo ""
echo "=== 4. Post-processing addition ==="

AGENTS=$(build_agents_json 1 "m")
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")
CONFIG=$(add_post_process "$CONFIG" "review.md" "claude-opus-4-6")

assert_eq "pp prompt" "review.md"      "$(echo "$CONFIG" | jq -r '.post_process.prompt')"
assert_eq "pp model"  "claude-opus-4-6" "$(echo "$CONFIG" | jq -r '.post_process.model')"
assert_eq "prompt preserved" "p.md"    "$(echo "$CONFIG" | jq -r '.prompt')"

# ============================================================
echo ""
echo "=== 5. Valid JSON output ==="

AGENTS=$(build_agents_json 2 "m1" 3 "m2")
CONFIG=$(build_config "p.md" "s.sh" 5 "name" "e@e" "$AGENTS")
CONFIG=$(add_post_process "$CONFIG" "pp.md" "m3")

echo "$CONFIG" > "$TMPDIR/output.json"
assert_eq "valid JSON" "true" "$(jq empty "$TMPDIR/output.json" 2>/dev/null && echo true || echo false)"

KEY_COUNT=$(echo "$CONFIG" | jq 'keys | length')
assert_eq "top-level keys" "6" "$KEY_COUNT"

# ============================================================
echo ""
echo "=== 6. Custom endpoint agent ==="

AGENT_OBJ='{"count": 2, "model": "custom", "base_url": "https://example.com", "api_key": "sk-test"}'
AGENTS=$(echo "[]" | jq --argjson obj "$AGENT_OBJ" '. + [$obj]')
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")

assert_eq "base_url" "https://example.com" "$(echo "$CONFIG" | jq -r '.agents[0].base_url')"
assert_eq "api_key"  "sk-test"             "$(echo "$CONFIG" | jq -r '.agents[0].api_key')"

# ============================================================
echo ""
echo "=== 7. OAuth auth mode detection ==="

assert_eq "oauth token present"   "oauth"   "$(detect_auth_mode "" "sk-ant-oat01-tok")"
assert_eq "api key present"       "apikey"  "$(detect_auth_mode "sk-key" "")"
assert_eq "both set"              "both"    "$(detect_auth_mode "sk-key" "sk-ant-oat01-tok")"
assert_eq "neither set"           "prompt"  "$(detect_auth_mode "" "")"

# ============================================================
echo ""
echo "=== 8. Config valid without API key (OAuth-only) ==="

AGENTS=$(build_agents_json 3 "claude-opus-4-6")
CONFIG=$(build_config "task.md" "" 3 "swarm-agent" "agent@claude-swarm.local" "$AGENTS")

echo "$CONFIG" > "$TMPDIR/oauth-config.json"
assert_eq "valid JSON (oauth)" "true" \
    "$(jq empty "$TMPDIR/oauth-config.json" 2>/dev/null && echo true || echo false)"
assert_eq "no api_key in config" "null" \
    "$(echo "$CONFIG" | jq -r '.agents[0].api_key // "null"')"
assert_eq "agent count (oauth)" "3" \
    "$(echo "$CONFIG" | jq '[.agents[].count] | add')"

# ============================================================
echo ""
echo "=== 9. Auth field in agent objects ==="

AGENT_APIKEY='{"count": 1, "model": "claude-opus-4-6", "auth": "apikey"}'
AGENT_OAUTH='{"count": 1, "model": "claude-opus-4-6", "auth": "oauth"}'
AGENT_DEFAULT='{"count": 1, "model": "claude-opus-4-6"}'
AGENTS=$(echo "[]" | jq --argjson a1 "$AGENT_APIKEY" --argjson a2 "$AGENT_OAUTH" --argjson a3 "$AGENT_DEFAULT" \
    '. + [$a1, $a2, $a3]')
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")

assert_eq "auth apikey" "apikey" "$(echo "$CONFIG" | jq -r '.agents[0].auth')"
assert_eq "auth oauth"  "oauth"  "$(echo "$CONFIG" | jq -r '.agents[1].auth')"
assert_eq "auth absent" "null"   "$(echo "$CONFIG" | jq -r '.agents[2].auth // "null"')"

echo "$CONFIG" > "$TMPDIR/auth-config.json"
assert_eq "auth config valid" "true" \
    "$(jq empty "$TMPDIR/auth-config.json" 2>/dev/null && echo true || echo false)"

# ============================================================
echo ""
echo "=== 10. Auto auth from single credential ==="

# Mirrors the agent-object auth logic from setup.sh lines 149-170:
#   custom endpoint  → base_url/api_key (no auth field)
#   both creds       → user picks (auto/apikey/oauth)
#   oauth only       → auth: oauth
#   apikey only      → auth: apikey
build_agent_obj() {
    local count="$1" model="$2" api_key="$3" oauth_token="$4"
    local custom_endpoint="${5:-}" base_url="${6:-}" group_key="${7:-}"
    local auth_choice="${8:-1}"

    local obj="{\"count\": ${count}, \"model\": \"${model}\""

    if [ "$custom_endpoint" = "yes" ]; then
        obj+=", \"base_url\": \"${base_url}\""
        if [ -n "$group_key" ]; then
            obj+=", \"api_key\": \"${group_key}\""
        fi
    elif [ -n "$api_key" ] && [ -n "$oauth_token" ]; then
        case "$auth_choice" in
            2) obj+=", \"auth\": \"apikey\"" ;;
            3) obj+=", \"auth\": \"oauth\"" ;;
        esac
    elif [ -n "$oauth_token" ]; then
        obj+=", \"auth\": \"oauth\""
    elif [ -n "$api_key" ]; then
        obj+=", \"auth\": \"apikey\""
    fi

    obj+="}"
    echo "$obj"
}

# OAuth only → auth must be "oauth"
OBJ=$(build_agent_obj 3 "claude-opus-4-6" "" "sk-oat-tok")
assert_eq "oauth-only sets auth"  "oauth"  "$(echo "$OBJ" | jq -r '.auth')"
assert_eq "oauth-only valid JSON" "true"   "$(echo "$OBJ" | jq empty 2>/dev/null && echo true || echo false)"

# API key only → auth must be "apikey"
OBJ=$(build_agent_obj 2 "claude-opus-4-6" "sk-key" "")
assert_eq "apikey-only sets auth" "apikey" "$(echo "$OBJ" | jq -r '.auth')"

# Both creds, default choice (1=auto) → no auth field
OBJ=$(build_agent_obj 1 "claude-opus-4-6" "sk-key" "sk-oat-tok" "" "" "" "1")
assert_eq "both/auto no auth" "null" "$(echo "$OBJ" | jq -r '.auth // "null"')"

# Both creds, choice 2 → apikey
OBJ=$(build_agent_obj 1 "claude-opus-4-6" "sk-key" "sk-oat-tok" "" "" "" "2")
assert_eq "both/choice=2 apikey" "apikey" "$(echo "$OBJ" | jq -r '.auth')"

# Both creds, choice 3 → oauth
OBJ=$(build_agent_obj 1 "claude-opus-4-6" "sk-key" "sk-oat-tok" "" "" "" "3")
assert_eq "both/choice=3 oauth" "oauth" "$(echo "$OBJ" | jq -r '.auth')"

# Custom endpoint → base_url + api_key, no auth field
OBJ=$(build_agent_obj 2 "custom" "" "sk-oat-tok" "yes" "https://example.com" "sk-ep-key")
assert_eq "custom ep base_url"  "https://example.com" "$(echo "$OBJ" | jq -r '.base_url')"
assert_eq "custom ep api_key"   "sk-ep-key"           "$(echo "$OBJ" | jq -r '.api_key')"
assert_eq "custom ep no auth"   "null"                 "$(echo "$OBJ" | jq -r '.auth // "null"')"

# Full round-trip: oauth-only agent in a config
AGENTS=$(echo "[]" | jq --argjson obj "$(build_agent_obj 3 "claude-opus-4-6" "" "sk-tok")" '. + [$obj]')
CONFIG=$(build_config "task.md" "" 3 "swarm-agent" "agent@claude-swarm.local" "$AGENTS")
assert_eq "config oauth auth"   "oauth"           "$(echo "$CONFIG" | jq -r '.agents[0].auth')"
assert_eq "config no api_key"   "null"             "$(echo "$CONFIG" | jq -r '.agents[0].api_key // "null"')"
assert_eq "config agent count"  "3"                "$(echo "$CONFIG" | jq '[.agents[].count] | add')"

echo "$CONFIG" > "$TMPDIR/oauth-auto.json"
assert_eq "config valid JSON" "true" \
    "$(jq empty "$TMPDIR/oauth-auto.json" 2>/dev/null && echo true || echo false)"

# ============================================================
echo ""
echo "=== 11. Effort field in agent objects ==="

# Mirrors the effort prompt logic from setup.sh.
build_agent_with_effort() {
    local count="$1" model="$2" effort="$3"
    local obj="{\"count\": ${count}, \"model\": \"${model}\""
    case "$effort" in
        low|medium|high) obj+=", \"effort\": \"${effort}\"" ;;
    esac
    obj+="}"
    echo "$obj"
}

OBJ=$(build_agent_with_effort 2 "claude-opus-4-6" "high")
assert_eq "effort high"       "high"  "$(echo "$OBJ" | jq -r '.effort')"
assert_eq "effort high JSON"  "true"  "$(echo "$OBJ" | jq empty 2>/dev/null && echo true || echo false)"

OBJ=$(build_agent_with_effort 1 "claude-sonnet-4-6" "medium")
assert_eq "effort medium"     "medium" "$(echo "$OBJ" | jq -r '.effort')"

OBJ=$(build_agent_with_effort 1 "claude-sonnet-4-6" "low")
assert_eq "effort low"        "low"    "$(echo "$OBJ" | jq -r '.effort')"

OBJ=$(build_agent_with_effort 3 "claude-opus-4-6" "")
assert_eq "effort blank"      "null"   "$(echo "$OBJ" | jq -r '.effort // "null"')"

OBJ=$(build_agent_with_effort 1 "m" "bogus")
assert_eq "effort invalid"    "null"   "$(echo "$OBJ" | jq -r '.effort // "null"')"

# Full round-trip: effort in config
AGENTS=$(echo "[]" \
    | jq --argjson a1 "$(build_agent_with_effort 2 "claude-opus-4-6" "high")" \
         --argjson a2 "$(build_agent_with_effort 1 "claude-sonnet-4-6" "")" \
    '. + [$a1, $a2]')
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")
assert_eq "config effort[0]"  "high"  "$(echo "$CONFIG" | jq -r '.agents[0].effort')"
assert_eq "config effort[1]"  "null"  "$(echo "$CONFIG" | jq -r '.agents[1].effort // "null"')"

# ============================================================
echo ""
echo "=== 12. Effort in post-processing ==="

# Mirrors the post-process effort logic from setup.sh.
add_post_process_with_effort() {
    local config="$1" pp_prompt="$2" pp_model="$3" pp_effort="$4"
    echo "$config" | jq \
        --arg pp_prompt "$pp_prompt" \
        --arg pp_model "$pp_model" \
        --arg pp_effort "$pp_effort" \
        '. + { post_process: { prompt: $pp_prompt, model: $pp_model } }
        | if $pp_effort != "" then .post_process.effort = $pp_effort else . end'
}

AGENTS=$(build_agents_json 1 "m")
CONFIG=$(build_config "p.md" "" 3 "sa" "a@a" "$AGENTS")

PP=$(add_post_process_with_effort "$CONFIG" "review.md" "claude-opus-4-6" "low")
assert_eq "pp effort low"     "low"    "$(echo "$PP" | jq -r '.post_process.effort')"

PP=$(add_post_process_with_effort "$CONFIG" "review.md" "claude-opus-4-6" "high")
assert_eq "pp effort high"    "high"   "$(echo "$PP" | jq -r '.post_process.effort')"

PP=$(add_post_process_with_effort "$CONFIG" "review.md" "claude-opus-4-6" "")
assert_eq "pp effort blank"   "null"   "$(echo "$PP" | jq -r '.post_process.effort // "null"')"

echo "$PP" > "$TMPDIR/pp-effort.json"
assert_eq "pp effort JSON"    "true"   "$(jq empty "$TMPDIR/pp-effort.json" 2>/dev/null && echo true || echo false)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
