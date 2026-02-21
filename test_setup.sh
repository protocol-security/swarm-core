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

# --- Helpers: same jq pipeline used in setup.sh ---

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
    local base="[]"
    shift_args() {
        local count="$1" model="$2"
        local obj="{\"count\": ${count}, \"model\": \"${model}\"}"
        echo "$obj"
    }
    # Build from arguments: count1 model1 count2 model2 ...
    local result="[]"
    while [ $# -ge 2 ]; do
        local obj="{\"count\": $1, \"model\": \"$2\"}"
        result=$(echo "$result" | jq --argjson obj "$obj" '. + [$obj]')
        shift 2
    done
    echo "$result"
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
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
