#!/bin/bash
set -euo pipefail

# Smoke test: launch agents with a counting prompt, verify results.
# Each agent N writes test-results/agent-N.txt with N*100..N*100+99.
#
# Usage: ./test.sh [--config FILE] [--no-inject]
#   --config FILE   Use a swarm.json for mixed-model testing.
#   --no-inject     Disable git rule injection; prompt includes
#                   explicit git commands (backward compat test).

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
REVIEW_DIR="/tmp/${PROJECT}-test-review"
INJECT_DIR="/tmp/${PROJECT}-test-inject"
TIMEOUT="${TIMEOUT:-600}"

CONFIG_FILE=""
NO_INJECT=false
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
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file ${CONFIG_FILE} not found." >&2
    exit 1
fi

if [ -n "$CONFIG_FILE" ]; then
    NUM_AGENTS=$(jq '[.agents[].count] | add' "$CONFIG_FILE")
else
    NUM_AGENTS="${SWARM_NUM_AGENTS:-2}"
fi

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
Your ONLY task is to create one file and push it.

## Steps

1. Read the AGENT_ID environment variable:

```bash
echo $AGENT_ID
```

2. Create the output file. The file must be named
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

3. Commit and push:

```bash
git add test-results/
git commit -m "Smoke test: agent ${AGENT_ID} counting"
git pull --rebase origin agent-work
git push origin agent-work
```

4. Stop. Do NOT loop, do NOT pick another task. Exit after
   the push succeeds.

## Rules

- Do NOT modify any existing files.
- Do NOT create any files other than test-results/agent-{AGENT_ID}.txt.
- The file must contain exactly 100 lines, one number per line.
- Use the exact bash commands above. Do not improvise.
PROMPT
    else
        cat > "$dest/$PROMPT_FILE" <<'PROMPT'
# Smoke Test: Deterministic Counting

You are agent $AGENT_ID in an infrastructure smoke test.
Your ONLY task is to create one file and commit it.

## Steps

1. Read the AGENT_ID environment variable:

```bash
echo $AGENT_ID
```

2. Create the output file. The file must be named
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

3. Commit your work with message "Smoke test: agent ${AGENT_ID} counting".

4. Stop. Do NOT loop, do NOT pick another task.

## Rules

- Do NOT modify any existing files.
- Do NOT create any files other than test-results/agent-{AGENT_ID}.txt.
- The file must contain exactly 100 lines, one number per line.
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

TEMP_CONFIG=""
if [ -n "$CONFIG_FILE" ]; then
    TEMP_CONFIG=$(mktemp /tmp/${PROJECT}-test-config.XXXXXX.json)
    if $NO_INJECT; then
        jq --arg p "$PROMPT_FILE" --arg s "$SETUP_FILE" \
            '.prompt = $p | .setup = $s | .inject_git_rules = false' \
            "$CONFIG_FILE" > "$TEMP_CONFIG"
    else
        jq --arg p "$PROMPT_FILE" --arg s "$SETUP_FILE" \
            '.prompt = $p | .setup = $s' \
            "$CONFIG_FILE" > "$TEMP_CONFIG"
    fi
fi

cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    cd "$REPO_ROOT"
    if [ -n "$TEMP_CONFIG" ]; then
        SWARM_CONFIG="$TEMP_CONFIG" \
            "$SWARM_DIR/launch.sh" stop 2>/dev/null || true
        rm -f "$TEMP_CONFIG"
    else
        SWARM_PROMPT="$PROMPT_FILE" \
            SWARM_SETUP="$SETUP_FILE" \
            ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
            SWARM_NUM_AGENTS="${NUM_AGENTS}" \
            "$SWARM_DIR/launch.sh" stop 2>/dev/null || true
    fi
    rm -rf "$REVIEW_DIR" "$INJECT_DIR" /tmp/${PROJECT}-upstream.git
    rm -f "$REPO_ROOT/$PROMPT_FILE" "$REPO_ROOT/$SETUP_FILE"
}
trap cleanup EXIT

INJECT_ENV="true"
if $NO_INJECT; then INJECT_ENV="false"; fi

echo "=== Smoke test: ${NUM_AGENTS} agents ==="
if $NO_INJECT; then
    echo "  mode: --no-inject (explicit git in prompt)"
else
    echo "  mode: default (git rules injected via system prompt)"
fi
echo ""

if [ -n "$TEMP_CONFIG" ]; then
    SWARM_CONFIG="$TEMP_CONFIG" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        "$SWARM_DIR/launch.sh" start
else
    SWARM_PROMPT="$PROMPT_FILE" \
        SWARM_SETUP="$SETUP_FILE" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        SWARM_NUM_AGENTS="${NUM_AGENTS}" \
        SWARM_INJECT_GIT_RULES="${INJECT_ENV}" \
        "$SWARM_DIR/launch.sh" start
fi

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
git add "$PROMPT_FILE" "$SETUP_FILE"
git -c user.name="test" -c user.email="test@test" \
    commit --quiet -m "tmp: smoke test prompt"
git push --quiet origin agent-work
rm -rf "$INJECT_DIR"
cd "$REPO_ROOT"

# Clean uncommitted files from working tree.
rm -f "$REPO_ROOT/$PROMPT_FILE" "$REPO_ROOT/$SETUP_FILE"

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
        [ -f "test-results/agent-${i}.txt" ] && found=$((found + 1))
    done

    printf "  [%3ds] %d/%d agents pushed results\n" \
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

for i in $(seq 1 "$NUM_AGENTS"); do
    FILE="test-results/agent-${i}.txt"

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
        echo "  PASS: agent ${i} (${START}..${END})"
    else
        echo "  FAIL: agent ${i} content mismatch"
        errors=$((errors + 1))
    fi
done

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
