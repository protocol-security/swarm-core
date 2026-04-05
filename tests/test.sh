#!/bin/bash
set -euo pipefail

# Smoke test: launch agents with a counting prompt, verify results.
# Each agent N writes test-results/agent-N.txt with N*100..N*100+99.
#
# Usage: ./test.sh [OPTIONS]
#
# Options:
#   --unit          Run unit tests only (no Docker or API key needed).
#   --all           Run unit tests then full integration matrix.
#   --oauth         Integration test using OAuth token (needs Docker +
#                   CLAUDE_CODE_OAUTH_TOKEN).
#   --config FILE   Use a swarmfile for mixed-model testing.
#   --no-inject     Disable git rule injection; prompt includes
#                   explicit git commands (backward compat test).
#   -h, --help      Show this help message.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
REVIEW_DIR="/tmp/${PROJECT}-test-review"
INJECT_DIR="/tmp/${PROJECT}-test-inject"
TIMEOUT="${TIMEOUT:-600}"

# Docker containers may leave files owned by a different UID.
rm_docker_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local parent base
    parent="$(dirname "$dir")"
    base="$(basename "$dir")"
    docker run --rm -v "${parent}:${parent}" alpine \
        rm -rf "${parent}/${base}" 2>/dev/null \
        || rm -rf "$dir" 2>/dev/null || true
}

# ---- --all: full test suite runner ----

run_all_tests() {
    local total_start unit_fail=0 int_pass=0 int_fail=0
    total_start=$(date +%s)

    echo "============================================================"
    echo "  Full test suite"
    echo "============================================================"
    echo ""

    # Phase 1: unit tests.
    cmd_unit || unit_fail=1
    echo ""

    # Phase 2: integration tests (require ANTHROPIC_API_KEY).
    echo "=== Phase 2: Integration tests ==="
    echo ""
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "  SKIP  (ANTHROPIC_API_KEY not set)"
        echo ""
    else
        local cases=(
            "1-agent|1||"
            "2-agents|2||"
            "3-agents|3||"
            "2-agents-no-inject|2||--no-inject"
            "2-agents-sonnet|2|claude-sonnet-4-6|"
            "3-agents-mixed|3|config-mixed|"
            "1-agent-effort|1|config-effort-single|"
            "2-agents-effort|2|config-effort|"
            "2-agents-postprocess|2|config-pp|"
            "2-agents-context-bare|2|config-context-none|"
            "2-agents-context-slim|2|config-context-slim|"
            "2-agents-per-prompt|2|config-per-prompt|"
        )

        local int_total=${#cases[@]} int_idx=0
        for entry in "${cases[@]}"; do
            int_idx=$((int_idx + 1))
            IFS='|' read -r label num_agents model_or_cfg extra_flag <<< "$entry"
            local t_start t_elapsed
            t_start=$(date +%s)

            local rc=0
            run_integration_case "[${int_idx}/${int_total}] ${label}" \
                "$num_agents" "$model_or_cfg" "$extra_flag" || rc=$?

            t_elapsed=$(( $(date +%s) - t_start ))
            if [ "$rc" -eq 0 ]; then
                printf "  PASS  %-24s (%ds)\n" "$label" "$t_elapsed"
                int_pass=$((int_pass + 1))
            else
                printf "  FAIL  %-24s (%ds)\n" "$label" "$t_elapsed"
                int_fail=$((int_fail + 1))
            fi
        done
        echo ""
    fi

    # Phase 3: OAuth integration tests (require CLAUDE_CODE_OAUTH_TOKEN).
    local oauth_pass=0 oauth_fail=0
    echo "=== Phase 3: OAuth integration tests ==="
    echo ""
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        echo "  SKIP  (CLAUDE_CODE_OAUTH_TOKEN not set)"
        echo ""
    else
        local oauth_cases=(
            "1-agent-oauth|1|oauth-only|"
        )
        # Mixed-auth requires both API key and OAuth token.
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            oauth_cases+=("2-agents-mixed-auth|2|config-mixed-auth|")
        fi

        local oauth_total=${#oauth_cases[@]} oauth_idx=0
        for entry in "${oauth_cases[@]}"; do
            oauth_idx=$((oauth_idx + 1))
            IFS='|' read -r label num_agents model_or_cfg extra_flag <<< "$entry"
            local title="[${oauth_idx}/${oauth_total}] ${label}"
            local t_start t_elapsed
            t_start=$(date +%s)

            local rc=0
            if [ "$model_or_cfg" = "oauth-only" ]; then
                SWARM_TITLE="$title" cmd_oauth || rc=$?
            else
                run_integration_case "$title" "$num_agents" \
                    "$model_or_cfg" "$extra_flag" || rc=$?
            fi

            t_elapsed=$(( $(date +%s) - t_start ))
            if [ "$rc" -eq 0 ]; then
                printf "  PASS  %-24s (%ds)\n" "$label" "$t_elapsed"
                oauth_pass=$((oauth_pass + 1))
            else
                printf "  FAIL  %-24s (%ds)\n" "$label" "$t_elapsed"
                oauth_fail=$((oauth_fail + 1))
            fi
        done
        echo ""
    fi

    # Summary.
    local total_elapsed
    total_elapsed=$(( $(date +%s) - total_start ))
    local total_m=$((total_elapsed / 60))
    local total_s=$((total_elapsed % 60))

    echo "============================================================"
    if [ "$unit_fail" -eq 0 ]; then
        echo "  Unit:        PASS"
    else
        echo "  Unit:        FAIL"
    fi
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf "  Integration: %d/%d passed\n" \
            "$int_pass" $((int_pass + int_fail))
    else
        echo "  Integration: SKIP (ANTHROPIC_API_KEY not set)"
    fi
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        printf "  OAuth:       %d/%d passed\n" \
            "$oauth_pass" $((oauth_pass + oauth_fail))
    else
        echo "  OAuth:       SKIP (CLAUDE_CODE_OAUTH_TOKEN not set)"
    fi
    printf "  Total time:  %dm %02ds\n" "$total_m" "$total_s"
    echo "============================================================"

    [ "$unit_fail" -eq 0 ] && [ "$int_fail" -eq 0 ] && [ "$oauth_fail" -eq 0 ]
}

run_integration_case() {
    local label="$1" num_agents="$2" model_or_cfg="$3" extra_flag="$4"
    local cfg dm
    cfg=$(mktemp "/tmp/${PROJECT}-inttest.XXXXXX.json")
    dm="${SWARM_MODEL:-claude-opus-4-6}"

    case "$model_or_cfg" in
        config-mixed)
            jq -n --arg m1 "$dm" --arg m2 "claude-sonnet-4-6" \
                '{prompt: "unused", agents: [
                    {count: 2, model: $m1},
                    {count: 1, model: $m2}
                ]}' > "$cfg"
            ;;
        config-pp)
            local pp_prompt
            pp_prompt=$(mktemp "/tmp/${PROJECT}-pp-prompt.XXXXXX.md")
            cat > "$pp_prompt" <<'PPPROMPT'
List all files in test-results/ and write a summary to
test-results/summary.txt with the word DONE on the last line.
Commit and push.
PPPROMPT
            cp "$pp_prompt" "$REPO_ROOT/.claude-swarm-pp-prompt.md"
            jq -n --arg m "$dm" --arg pp ".claude-swarm-pp-prompt.md" \
                '{prompt: "unused",
                  agents: [{count: '"$num_agents"', model: $m}],
                  post_process: {prompt: $pp, model: $m}}' \
                > "$cfg"
            rm -f "$pp_prompt"
            ;;
        config-effort-single)
            jq -n --arg m "$dm" \
                '{prompt: "unused", agents: [{count: '"$num_agents"', model: $m, effort: "medium"}]}' \
                > "$cfg"
            ;;
        config-effort)
            jq -n --arg m1 "$dm" --arg m2 "claude-sonnet-4-6" \
                '{prompt: "unused", agents: [
                    {count: 1, model: $m1, effort: "high"},
                    {count: 1, model: $m2, effort: "high"}
                ]}' > "$cfg"
            ;;
        config-mixed-auth)
            jq -n --arg m "$dm" \
                '{prompt: "unused", agents: [
                    {count: 1, model: $m, auth: "apikey"},
                    {count: 1, model: $m, auth: "oauth"}
                ]}' > "$cfg"
            ;;
        config-context-none)
            jq -n --arg m "$dm" \
                '{prompt: "unused", agents: [
                    {count: 1, model: $m},
                    {count: 1, model: $m, context: "none"}
                ]}' > "$cfg"
            ;;
        config-context-slim)
            jq -n --arg m "$dm" \
                '{prompt: "unused", agents: [
                    {count: 1, model: $m},
                    {count: 1, model: $m, context: "slim"}
                ]}' > "$cfg"
            ;;
        config-per-prompt)
            jq -n --arg m "$dm" \
                --arg ap ".claude-swarm-smoke-alt.md" \
                '{prompt: "unused", agents: [
                    {count: 1, model: $m},
                    {count: 1, model: $m, prompt: $ap}
                ]}' > "$cfg"
            ;;
        "")
            jq -n --arg m "$dm" \
                '{prompt: "unused", agents: [{count: '"$num_agents"', model: $m}]}' \
                > "$cfg"
            ;;
        *)
            jq -n --arg m "$model_or_cfg" \
                '{prompt: "unused", agents: [{count: '"$num_agents"', model: $m}]}' \
                > "$cfg"
            ;;
    esac

    local args=(--config "$cfg")
    if [ -n "$extra_flag" ]; then
        # shellcheck disable=SC2206
        args+=($extra_flag)
    fi

    local rc=0
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
        SWARM_TITLE="$label" \
        TIMEOUT="${TIMEOUT}" \
        "$TESTS_DIR/test.sh" "${args[@]}" || rc=$?

    rm -f "/tmp/${PROJECT}-inttest."*.json
    rm -f "$REPO_ROOT/.claude-swarm-pp-prompt.md"

    return "$rc"
}

cmd_unit() {
    local pass=0 fail=0 total_tests=0
    echo "=== Unit tests ==="
    echo ""
    for f in "$TESTS_DIR"/test_*.sh; do
        local name rc output count
        name=$(basename "$f")
        rc=0
        output=$("$f" 2>&1) || rc=$?
        count=$(printf '%s' "$output" | grep -oE '[0-9]+ passed' | tail -1 || true)
        if [ "$rc" -eq 0 ]; then
            printf "  PASS  %-24s (%s)\n" "$name" "${count:-?}"
            pass=$((pass + 1))
            local n="${count%% *}"
            [ -n "$n" ] && total_tests=$((total_tests + n))
        else
            printf "  FAIL  %-24s\n" "$name"
            printf '%s\n' "$output" | tail -20 | sed 's/^/        /'
            fail=$((fail + 1))
        fi
    done
    echo ""
    echo "  ${pass} files passed (${total_tests} tests), ${fail} failed"
    [ "$fail" -eq 0 ]
}

cmd_oauth() {
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        echo "ERROR: CLAUDE_CODE_OAUTH_TOKEN is not set." >&2
        echo "       Generate one with: claude setup-token" >&2
        exit 1
    fi

    local cfg rc=0
    cfg=$(mktemp "/tmp/${PROJECT}-oauth.XXXXXX.json")
    jq -n --arg m "${SWARM_MODEL:-claude-opus-4-6}" \
        '{prompt: "unused", agents: [{count: 1, model: $m, auth: "oauth"}]}' \
        > "$cfg"
    env ANTHROPIC_API_KEY="" \
        CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}" \
        SWARM_TITLE="${SWARM_TITLE:-1-agent-oauth}" \
        TIMEOUT="${TIMEOUT}" \
        "$TESTS_DIR/test.sh" --config "$cfg" || rc=$?
    rm -f "$cfg"
    return "$rc"
}

cmd_help() {
    cat <<'HELP'
Usage: ./test.sh [OPTIONS]

Run claude-swarm tests.

Options:
  (no args)         Single integration smoke test (needs Docker + API key).
  --unit            Unit tests only (no Docker or API key needed).
  --all             Unit tests, then full integration matrix.
  --oauth           Integration test using CLAUDE_CODE_OAUTH_TOKEN
                    (needs Docker + OAuth token).
  --config FILE     Use a swarmfile for mixed-model testing.
  --no-inject       Explicit git commands in prompt (backward compat test).
  -h, --help        Show this help message.

Environment:
  ANTHROPIC_API_KEY        Required for integration tests.
  CLAUDE_CODE_OAUTH_TOKEN  Required for --oauth tests.
  TIMEOUT                  Seconds to wait for agents (default: 600).
  SWARM_MODEL              Override default model (default: claude-opus-4-6).
HELP
}

CONFIG_FILE=""
NO_INJECT=false
RUN_ALL=false
RUN_UNIT=false
RUN_OAUTH=false
_AUTO_CONFIG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            CONFIG_FILE="${2:-}"
            if [ -z "$CONFIG_FILE" ]; then
                echo "ERROR: --config requires a file path." >&2
                exit 1
            fi
            shift 2 ;;
        --no-inject) NO_INJECT=true; shift ;;
        --all) RUN_ALL=true; shift ;;
        --unit) RUN_UNIT=true; shift ;;
        --oauth) RUN_OAUTH=true; shift ;;
        -h|--help) cmd_help; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

if $RUN_UNIT; then
    cmd_unit
    exit $?
fi

if $RUN_OAUTH; then
    cmd_oauth
    exit $?
fi

if $RUN_ALL; then
    run_all_tests
    exit $?
fi

if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file ${CONFIG_FILE} not found." >&2
    exit 1
fi

if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(mktemp "/tmp/${PROJECT}-test-default.XXXXXX.json")
    _AUTO_CONFIG="$CONFIG_FILE"
    jq -n --arg m "${SWARM_MODEL:-claude-opus-4-6}" \
        '{prompt: "unused", agents: [{count: '"${SWARM_NUM_AGENTS:-2}"', model: $m}]}' \
        > "$CONFIG_FILE"
fi
NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")

# Two prompt variants: default relies on injected git rules,
# --no-inject uses explicit git commands for backward compat.
PROMPT_FILE=".claude-swarm-smoke-test.md"
SETUP_FILE=".claude-swarm-smoke-setup.sh"

write_prompt() {
    local dest="$1"

    if $NO_INJECT; then
        cat > "$dest/$PROMPT_FILE" <<'PROMPT'
# Smoke Test: Deterministic Counting

You are agent $AGENT_ID in an infrastructure smoke test.
You must create TWO files and make TWO separate commits.
The task is NOT complete until both files are committed and pushed.

## Steps

0. First, check whether your work already exists:

```bash
test -f "test-results/reasoning-${AGENT_ID}.txt" && echo "ALREADY DONE"
```

   If the file exists, your previous session already completed this task.
   Stop immediately — do not create, modify, or commit any files.

1. Read the AGENT_ID environment variable:

```bash
echo $AGENT_ID
```

2. Create the counting file. The file must be named
   `test-results/agent-{AGENT_ID}.txt` and contain numbers
   from `AGENT_ID * 100` to `AGENT_ID * 100 + 99`, one per
   line. For example, agent 1 writes 100..199, agent 2 writes
   200..299, agent 3 writes 300..399.

```bash
mkdir -p test-results
START=$((AGENT_ID * 100))
END=$((START + 99))
seq $START $END > test-results/agent-${AGENT_ID}.txt
```

3. Commit and push the counting file:

```bash
git add test-results/agent-${AGENT_ID}.txt
git commit -m "Smoke test: agent ${AGENT_ID} counting"
git pull --rebase origin agent-work
git push origin agent-work
```

4. IMPORTANT — you are not done yet. You must now create a second file.
   Compute the sum of all 100 numbers you just wrote. The formula
   for the sum of consecutive integers from a to b is:
   sum = (b - a + 1) * (a + b) / 2

   Write a second file `test-results/reasoning-{AGENT_ID}.txt`
   containing exactly two lines:
   - Line 1: the computed sum (a single integer)
   - Line 2: a one-sentence explanation of how you derived it

5. Commit and push the reasoning file:

```bash
git add test-results/reasoning-${AGENT_ID}.txt
git commit -m "Smoke test: agent ${AGENT_ID} reasoning"
git pull --rebase origin agent-work
git push origin agent-work
```

6. Now you are done. Stop. Do NOT loop, do NOT pick another task.

## Rules

- Do NOT modify any existing files.
- You must create BOTH test-results/agent-{AGENT_ID}.txt AND
  test-results/reasoning-{AGENT_ID}.txt. Both are required.
- The counting file must contain exactly 100 lines, one number per line.
- The reasoning file must contain exactly 2 lines.
- Use the exact bash commands above for steps 3 and 5. Do not improvise.
- Do NOT stop after step 3. You must continue to steps 4 and 5.
PROMPT
    else
        cat > "$dest/$PROMPT_FILE" <<'PROMPT'
# Smoke Test: Deterministic Counting

You are agent $AGENT_ID in an infrastructure smoke test.
You must create TWO files and make TWO separate commits.
The task is NOT complete until both files are committed and pushed.

## Steps

0. First, check whether your work already exists:

```bash
test -f "test-results/reasoning-${AGENT_ID}.txt" && echo "ALREADY DONE"
```

   If the file exists, your previous session already completed this task.
   Stop immediately — do not create, modify, or commit any files.

1. Read the AGENT_ID environment variable:

```bash
echo $AGENT_ID
```

2. Create the counting file. The file must be named
   `test-results/agent-{AGENT_ID}.txt` and contain numbers
   from `AGENT_ID * 100` to `AGENT_ID * 100 + 99`, one per
   line. For example, agent 1 writes 100..199, agent 2 writes
   200..299, agent 3 writes 300..399.

```bash
mkdir -p test-results
START=$((AGENT_ID * 100))
END=$((START + 99))
seq $START $END > test-results/agent-${AGENT_ID}.txt
```

3. Commit the counting file with message
   "Smoke test: agent ${AGENT_ID} counting".

4. IMPORTANT — you are not done yet. You must now create a second file.
   Compute the sum of all 100 numbers you just wrote. The formula
   for the sum of consecutive integers from a to b is:
   sum = (b - a + 1) * (a + b) / 2

   Write a second file `test-results/reasoning-{AGENT_ID}.txt`
   containing exactly two lines:
   - Line 1: the computed sum (a single integer)
   - Line 2: a one-sentence explanation of how you derived it

5. Commit the reasoning file with message
   "Smoke test: agent ${AGENT_ID} reasoning".

6. Now you are done. Stop. Do NOT loop, do NOT pick another task.

## Rules

- Do NOT modify any existing files.
- You must create BOTH test-results/agent-{AGENT_ID}.txt AND
  test-results/reasoning-{AGENT_ID}.txt. Both are required.
- The counting file must contain exactly 100 lines, one number per line.
- The reasoning file must contain exactly 2 lines.
- Do NOT stop after step 3. You must continue to steps 4 and 5.
PROMPT
    fi

    cat > "$dest/$SETUP_FILE" <<'SETUP'
#!/bin/bash
set -euo pipefail
apt-get update -qq > /dev/null
echo "Smoke test setup complete."
SETUP
}

# Write prompt to repo root (uncommitted) so launch.sh's file-exists
# check passes. Files are injected into the bare repo after launch.
write_prompt "$REPO_ROOT"

# Alt prompt for per-group prompt tests (same content, different name).
ALT_PROMPT_FILE=".claude-swarm-smoke-alt.md"
cp "$REPO_ROOT/$PROMPT_FILE" "$REPO_ROOT/$ALT_PROMPT_FILE"

TEMP_CONFIG=$(mktemp "/tmp/${PROJECT}-test-config.XXXXXX.json")
if $NO_INJECT; then
    jq --arg p "$PROMPT_FILE" --arg s "$SETUP_FILE" \
        '.prompt = $p | .setup = $s | .inject_git_rules = false' \
        "$CONFIG_FILE" > "$TEMP_CONFIG"
else
    jq --arg p "$PROMPT_FILE" --arg s "$SETUP_FILE" \
        '.prompt = $p | .setup = $s' \
        "$CONFIG_FILE" > "$TEMP_CONFIG"
fi

cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    cd "$REPO_ROOT"
    SWARM_CONFIG="$TEMP_CONFIG" \
        "$SWARM_DIR/launch.sh" stop 2>/dev/null || true
    rm -f "$TEMP_CONFIG" "$_AUTO_CONFIG"
    rm -rf "$REVIEW_DIR" "$INJECT_DIR"
    rm_docker_dir "/tmp/${PROJECT}-upstream.git"
    rm -f "$REPO_ROOT/$PROMPT_FILE" "$REPO_ROOT/$SETUP_FILE" \
        "$REPO_ROOT/$ALT_PROMPT_FILE"
}
trap cleanup EXIT

echo "=== Smoke test: ${NUM_AGENTS} agents ==="
if $NO_INJECT; then
    echo "  mode: --no-inject (explicit git in prompt)"
else
    echo "  mode: default (git rules injected via system prompt)"
fi
echo ""

SWARM_CONFIG="$TEMP_CONFIG" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    "$SWARM_DIR/launch.sh" start

# Inject prompt + setup into bare repo via a temp clone.
# Agents fetch at the start of each session so they pick this up
# before their first claude invocation.
echo ""
echo "--- Injecting test prompt into bare repo ---"
rm -rf "$INJECT_DIR"
git clone --quiet "$BARE_REPO" "$INJECT_DIR"
cd "$INJECT_DIR"
git checkout --quiet agent-work
write_prompt "$INJECT_DIR"
cp "$INJECT_DIR/$PROMPT_FILE" "$INJECT_DIR/$ALT_PROMPT_FILE"
git add "$PROMPT_FILE" "$SETUP_FILE" "$ALT_PROMPT_FILE"
git -c user.name="test" -c user.email="test@test" \
    commit --quiet -m "tmp: smoke test prompt"
git push --quiet origin agent-work
rm -rf "$INJECT_DIR"
cd "$REPO_ROOT"

# Clean uncommitted files from working tree.
rm -f "$REPO_ROOT/$PROMPT_FILE" "$REPO_ROOT/$SETUP_FILE" \
    "$REPO_ROOT/$ALT_PROMPT_FILE"

echo ""
echo "--- Waiting for agents (timeout ${TIMEOUT}s) ---"

elapsed=0
interval=15

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))

    rm -rf "$REVIEW_DIR"
    git clone --quiet "$BARE_REPO" "$REVIEW_DIR" 2>/dev/null
    cd "$REVIEW_DIR"
    git checkout --quiet agent-work 2>/dev/null || true

    found=0
    for i in $(seq 1 "$NUM_AGENTS"); do
        [ -f "test-results/reasoning-${i}.txt" ] && found=$((found + 1))
    done

    printf "  [%3ds] %d/%d agents fully completed\n" \
        "$elapsed" "$found" "$NUM_AGENTS"

    cd /

    if [ "$found" -eq "$NUM_AGENTS" ]; then
        break
    fi
done

echo ""
echo "--- Verifying results ---"

errors=0

rm -rf "$REVIEW_DIR"
git clone --quiet "$BARE_REPO" "$REVIEW_DIR"
cd "$REVIEW_DIR"
git checkout --quiet agent-work

PROMPT_COMMIT=$(git log --all --oneline --grep="tmp: smoke test prompt" \
    --format="%H" | head -1)

for i in $(seq 1 "$NUM_AGENTS"); do
    FILE="test-results/agent-${i}.txt"
    RFILE="test-results/reasoning-${i}.txt"

    if [ ! -f "$FILE" ]; then
        echo "  FAIL: ${FILE} missing"
        errors=$((errors + 1))
        continue
    fi

    START=$((i * 100))
    END=$((START + 99))
    EXPECTED=$(seq "$START" "$END")
    ACTUAL=$(cat "$FILE")

    if [ "$ACTUAL" = "$EXPECTED" ]; then
        echo "  PASS: agent ${i} counting (${START}..${END})"
    else
        echo "  FAIL: agent ${i} content mismatch"
        errors=$((errors + 1))
    fi

    EXPECTED_SUM=$(( (END - START + 1) * (START + END) / 2 ))
    if [ ! -f "$RFILE" ]; then
        echo "  FAIL: ${RFILE} missing"
        errors=$((errors + 1))
    else
        ACTUAL_SUM=$(head -1 "$RFILE" | tr -d '[:space:]')
        if [ "$ACTUAL_SUM" = "$EXPECTED_SUM" ]; then
            echo "  PASS: agent ${i} reasoning (sum=${EXPECTED_SUM})"
        else
            echo "  FAIL: agent ${i} reasoning (expected ${EXPECTED_SUM}, got ${ACTUAL_SUM})"
            errors=$((errors + 1))
        fi
    fi

    # Verify commit messages: each agent should have a "counting" and
    # a "reasoning" commit with distinct messages.
    COUNT_C=$(git log --all --oneline \
        --grep="Smoke test: agent ${i} counting" | wc -l)
    REASON_C=$(git log --all --oneline \
        --grep="Smoke test: agent ${i} reasoning" | wc -l)
    if [ "$COUNT_C" -lt 1 ]; then
        echo "  FAIL: agent ${i} missing counting commit"
        errors=$((errors + 1))
    fi
    if [ "$REASON_C" -lt 1 ]; then
        echo "  FAIL: agent ${i} missing reasoning commit"
        errors=$((errors + 1))
    fi
    TOTAL_C=$((COUNT_C + REASON_C))
    if [ "$TOTAL_C" -gt 2 ]; then
        echo "  WARN: agent ${i} has ${TOTAL_C} commits (expected 2)"
    fi
done

# Check for garbage files committed outside test-results/.
if [ -n "$PROMPT_COMMIT" ]; then
    GARBAGE=$(git diff --name-only "${PROMPT_COMMIT}..HEAD" -- \
        ':!test-results/' ':!.gemini/' ':!GEMINI.md' 2>/dev/null || true)
    if [ -n "$GARBAGE" ]; then
        echo ""
        echo "  FAIL: garbage files committed outside test-results/:"
        printf '        %s\n' $GARBAGE
        errors=$((errors + 1))
    fi
fi

echo ""
if [ "$errors" -eq 0 ]; then
    echo "=== ALL ${NUM_AGENTS} AGENTS PASSED ==="
    exit 0
else
    echo "=== ${errors} AGENT(S) FAILED ==="
    for i in $(seq 1 "$NUM_AGENTS"); do
        if [ ! -f "test-results/agent-${i}.txt" ]; then
            echo ""
            echo "--- ${PROJECT}-agent-${i} docker logs ---"
            docker logs "${PROJECT}-agent-${i}" 2>&1 | tail -20
        fi
    done
    exit 1
fi
