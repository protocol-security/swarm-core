#!/bin/bash
# shellcheck disable=SC2034
set -uo pipefail

# tests/runtime_signal_trap.sh
#
# Drive the harness's emergency-push paths under real Docker.
# The structural assertions in tests/test_session_end_push.sh §6
# and §7 pin the shape of `_session_end_push`, `_run_agent_session`,
# `_on_signal`, and the TERM/INT trap installation, but cannot
# prove the trap actually fires under a real container's signal
# delivery semantics.  This test runs the harness in a real
# container, drives each abnormal-exit path that previously lost
# commits, and asserts the commit lands on origin/agent-work.
#
# Scenarios:
#   3. Mid-session SIGTERM  -> exit 143, commit lands.
#   4. Mid-session SIGINT   -> exit 130, commit lands.
#   5. Fatal-error session  -> exit 1,   commit lands.
#   6. cmd_stop banner reads the active SWARM_STOP_TIMEOUT.
#
# Requires Docker.  No API key needed -- a synthetic
# test-committer driver mounts in via `-v` and bypasses every
# real agent CLI.  Wall-clock: ~30 s after the image is cached.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LAUNCH_SH="${REPO_ROOT}/launch.sh"

# Docker-gated: skip cleanly when the host has no daemon (CI lanes
# that only run --unit, dev laptops without Docker, etc.).
if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not found"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not running"
    exit 0
fi

IMAGE_TAG="claude-swarm-runtime-test"
WORKDIR=$(mktemp -d /tmp/claude-swarm-runtime-XXXXXX)
NAMES=(
    claude-swarm-runtime-test-1
    claude-swarm-runtime-test-2
    claude-swarm-runtime-test-3
)

cleanup() {
    docker rm -f "${NAMES[@]}" 2>/dev/null >/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

check() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "    PASS: ${label}  (${actual})"
        PASS=$((PASS + 1))
    else
        echo "    FAIL: ${label}  expected=${expected} got=${actual}"
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local label="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "    PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "    FAIL: ${label}  missing '${needle}'"
        printf '%s\n' "$haystack" | tail -8 | sed 's/^/          /'
        FAIL=$((FAIL + 1))
    fi
}

# Build the test image (cached after first run).  SWARM_AGENTS=fake
# skips the claude-code / codex / gemini CLI install layers since
# the synthetic driver below replaces every real agent.
echo "--- Building ${IMAGE_TAG} (fake driver only) ---"
docker build --quiet --tag "$IMAGE_TAG" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null

# Seed a bare repo on the host that each container will mount as
# /upstream.  The container's harness clones from /upstream into
# /workspace, runs a session, and pushes back.
git init -q --bare --initial-branch=agent-work "$WORKDIR/upstream.git"
git clone -q "$WORKDIR/upstream.git" "$WORKDIR/seed"
(
    cd "$WORKDIR/seed" || exit 1
    git config user.email t@t
    git config user.name t
    mkdir -p prompts
    echo "test prompt for runtime check" > prompts/test.md
    git add prompts/test.md
    git commit -qm seed
    git push -q origin agent-work
)
rm -rf "$WORKDIR/seed"

# Synthetic driver mounted at /drivers/test-committer.sh.  agent_run
# commits a file in /workspace, then either sleeps so we can
# interrupt it (items 3, 4) or returns non-zero so the harness's
# FATAL_MSG path triggers (item 5).  TC_TAG marks each scenario's
# commit so we can grep for it on origin/agent-work afterwards.
cat > "$WORKDIR/test-committer.sh" <<'DRIVER'
#!/bin/bash
# shellcheck disable=SC2034
agent_default_model() { echo "test-committer"; }
agent_name()    { echo "Test Committer"; }
agent_cmd()     { echo "test-committer"; }
agent_version() { echo "0.0.0-test"; }
agent_run() {
    local model="$1" prompt_text="$2" logfile="$3"
    cd /workspace || return 1
    local tag="${TC_TAG:-tc-$$-$RANDOM}"
    echo "$(date -u +%s) ${tag}" >> committed-by-fake.txt
    git -c commit.gpgsign=false add committed-by-fake.txt
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        commit -qm "test commit [${tag}]" >/dev/null 2>&1
    {
        printf '{"type":"system","subtype":"init","session_id":"tc","model":"%s"}\n' "$model"
        printf '{"type":"result","subtype":"success","session_id":"tc","total_cost_usd":0.0001,"is_error":false,"duration_ms":100,"duration_api_ms":80,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
    } | tee "$logfile" >/dev/null
    if [ "${TC_FATAL:-0}" = "1" ]; then
        return 42
    fi
    sleep 600
}
agent_settings() { :; }
agent_detect_fatal() {
    local logfile="$1" exit_code="$2"
    if [ "${TC_FATAL:-0}" = "1" ] && [ "$exit_code" -ne 0 ]; then
        echo "test-committer: simulated non-retriable fatal"
    fi
}
agent_is_retriable() { :; }
agent_extract_stats() {
    printf '0.0001\t10\t5\t0\t0\t100\t80\t1\n'
}
agent_activity_jq() { echo 'fromjson? // empty | empty'; }
agent_docker_env() { :; }
agent_docker_auth() { printf -- '-e\nSWARM_AUTH_MODE=\n'; }
agent_install_cmd() { :; }
DRIVER
chmod +x "$WORKDIR/test-committer.sh"

start_container() {
    local name="$1"
    shift
    docker run -d --name "$name" \
        -v "$WORKDIR/upstream.git:/upstream:rw" \
        -v "$WORKDIR/test-committer.sh:/drivers/test-committer.sh:ro" \
        -e SWARM_DRIVER=test-committer \
        -e SWARM_MODEL=test-committer \
        -e SWARM_PROMPT=prompts/test.md \
        -e AGENT_ID=1 \
        -e GIT_USER_NAME=tc \
        -e GIT_USER_EMAIL=tc@tc \
        -e INJECT_GIT_RULES=false \
        "$@" \
        "$IMAGE_TAG" >/dev/null
}

wait_for_session() {
    local name="$1" timeout="${2:-30}"
    local i
    for i in $(seq 1 "$timeout"); do
        if docker logs "$name" 2>&1 | grep -q "session start at="; then
            return 0
        fi
        sleep 1
    done
    echo "    timed out waiting for 'session start' in ${name}"
    docker logs "$name" 2>&1 | tail -15 | sed 's/^/      /'
    return 1
}

await_exit() {
    local name="$1" timeout="${2:-90}"
    local i status
    for i in $(seq 1 "$timeout"); do
        status=$(docker inspect --format '{{.State.Status}}' \
            "$name" 2>/dev/null || true)
        if [ "$status" = "exited" ]; then
            docker inspect --format '{{.State.ExitCode}}' "$name"
            return 0
        fi
        sleep 1
    done
    echo "    timed out waiting for ${name} to exit"
    return 1
}

count_landed() {
    local tag="$1"
    git -C "$WORKDIR/upstream.git" log --oneline agent-work \
        2>/dev/null | grep -cF -- "[$tag]" || true
}

echo
echo "=== Item 3: SIGTERM mid-session ==="
start_container "${NAMES[0]}" -e TC_TAG=sigterm-tag
wait_for_session "${NAMES[0]}" || exit 1
sleep 2
echo "  sending docker stop -t 60..."
docker stop -t 60 "${NAMES[0]}" >/dev/null
EXIT_3=$(await_exit "${NAMES[0]}")
LOGS_3=$(docker logs "${NAMES[0]}" 2>&1)
check          "exit code"                      "$EXIT_3" "143"
check_contains "log: received SIGTERM"          "$LOGS_3" "received SIGTERM"
check_contains "log: attempting emergency push" "$LOGS_3" "attempting emergency push"
check_contains "log: emergency shutdown complete" \
    "$LOGS_3" "emergency shutdown complete"
check          "commit landed on agent-work"    "$(count_landed sigterm-tag)" "1"
echo

echo "=== Item 4: SIGINT mid-session ==="
start_container "${NAMES[1]}" -e TC_TAG=sigint-tag
wait_for_session "${NAMES[1]}" || exit 1
sleep 2
echo "  sending docker kill --signal=SIGINT..."
docker kill --signal=SIGINT "${NAMES[1]}" >/dev/null
EXIT_4=$(await_exit "${NAMES[1]}")
LOGS_4=$(docker logs "${NAMES[1]}" 2>&1)
check          "exit code"                      "$EXIT_4" "130"
check_contains "log: received SIGINT"           "$LOGS_4" "received SIGINT"
check_contains "log: attempting emergency push" "$LOGS_4" "attempting emergency push"
check_contains "log: emergency shutdown complete" \
    "$LOGS_4" "emergency shutdown complete"
check          "commit landed on agent-work"    "$(count_landed sigint-tag)" "1"
echo

echo "=== Item 5: Fatal-error mid-session ==="
start_container "${NAMES[2]}" -e TC_TAG=fatal-tag -e TC_FATAL=1
wait_for_session "${NAMES[2]}" || exit 1
EXIT_5=$(await_exit "${NAMES[2]}")
LOGS_5=$(docker logs "${NAMES[2]}" 2>&1)
check          "exit code"                      "$EXIT_5" "1"
check_contains "log: fatal: test-committer"     "$LOGS_5" "fatal: test-committer"
check_contains "log: exiting due to unrecoverable error" \
    "$LOGS_5" "exiting due to unrecoverable error"
check          "commit landed on agent-work"    "$(count_landed fatal-tag)" "1"
echo

echo "=== Item 6: SWARM_STOP_TIMEOUT banner ==="
FAKE_DIR="$WORKDIR/fake-bin"
mkdir -p "$FAKE_DIR"
cat > "$FAKE_DIR/docker" <<'FD'
#!/bin/bash
exit 0
FD
chmod +x "$FAKE_DIR/docker"

CMD_STOP_BODY=$(awk '/^cmd_stop\(\) \{/,/^\}$/' "$LAUNCH_SH")

BANNER_DEFAULT=$(
    eval "$CMD_STOP_BODY"
    NUM_AGENTS=2 IMAGE_NAME=fake PROJECT=fake \
        PATH="$FAKE_DIR:$PATH" cmd_stop 2>&1 | head -1
)
check "default banner" \
    "$BANNER_DEFAULT" "--- Stopping agents (grace 60s) ---"

BANNER_120=$(
    eval "$CMD_STOP_BODY"
    NUM_AGENTS=2 IMAGE_NAME=fake PROJECT=fake \
        PATH="$FAKE_DIR:$PATH" SWARM_STOP_TIMEOUT=120 cmd_stop 2>&1 \
        | head -1
)
check "SWARM_STOP_TIMEOUT=120 banner" \
    "$BANNER_120" "--- Stopping agents (grace 120s) ---"
echo

echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
