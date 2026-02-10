#!/bin/bash
set -euo pipefail

# Smoke test: launch agents with a counting prompt, verify results.
# Each agent N writes test-results/agent-N.txt with N*100..N*100+99.

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$(basename "$REPO_ROOT")"
BARE_REPO="/tmp/${PROJECT}-upstream.git"
REVIEW_DIR="/tmp/${PROJECT}-test-review"
NUM_AGENTS="${NUM_AGENTS:-2}"
TIMEOUT="${TIMEOUT:-600}"

# Write the smoke test prompt as a temp file and commit it.
PROMPT_FILE=".claude-swarm-smoke-test.md"
cat > "$REPO_ROOT/$PROMPT_FILE" <<'PROMPT'
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

cd "$REPO_ROOT"
git add "$PROMPT_FILE"
git commit --quiet -m "tmp: smoke test prompt"

cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    AGENT_PROMPT="$PROMPT_FILE" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
        NUM_AGENTS="${NUM_AGENTS}" \
        "$SWARM_DIR/launch.sh" stop 2>/dev/null || true
    rm -rf "$REVIEW_DIR"

    # Remove the temp prompt commit.
    cd "$REPO_ROOT"
    git rm --quiet -f "$PROMPT_FILE" 2>/dev/null || true
    git commit --quiet --allow-empty -m "tmp: remove smoke test prompt" 2>/dev/null || true
    git reset --quiet --soft HEAD~2
}
trap cleanup EXIT

echo "=== Smoke test: ${NUM_AGENTS} agents ==="
echo ""

AGENT_PROMPT="$PROMPT_FILE" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    NUM_AGENTS="${NUM_AGENTS}" \
    "$SWARM_DIR/launch.sh" start

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
            echo "--- ${IMAGE_NAME}-${i} docker logs ---"
            docker logs "${PROJECT}-agent-${i}" 2>&1 | tail -20
        fi
    done
    exit 1
fi
