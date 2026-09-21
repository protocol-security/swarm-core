#!/bin/bash
set -euo pipefail

# Real Pi CLI + Docker + Git E2E against a local, deterministic test API.
# No credentials or paid model calls. Does not claim live-provider coverage.
# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/project.sh
source "$ROOT/lib/project.sh"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: Docker unavailable"
    exit 0
fi

WORK=$(mktemp -d /tmp/swarm-pi-e2e.XXXXXX)
PROJECT=$(swarm_project_id "$(basename "$WORK")")
IMAGE="${PROJECT}-agent"
NETWORK="${PROJECT}-network"
API="${PROJECT}-api"
BARE="/tmp/${PROJECT}-upstream.git"
VERSION="${PI_TEST_VERSION:-0.86.1}"
NAMES=("$API" "$IMAGE-1" "$IMAGE-post" "$IMAGE-error")
cleanup() {
    local rc=$? name
    while IFS= read -r name; do
        [ -n "$name" ] && NAMES+=("$name")
    done < <(docker ps -a --format '{{.Names}}' \
        --filter "name=^/${IMAGE}-interactive-" 2>/dev/null || true)
    if [ "$rc" -ne 0 ]; then
        for name in "${NAMES[@]}"; do
            echo "--- ${name} ---"
            docker logs --tail 40 "$name" 2>&1 || true
        done
    fi
    docker rm -f "${NAMES[@]}" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$WORK" "$BARE"
    rm -f "/tmp/${PROJECT}-swarm.env"
}
trap cleanup EXIT

wait_container() {
    local name="$1" expected="$2" state i
    for ((i = 0; i < 120; i++)); do
        state=$(docker inspect -f '{{.State.Status}}' "$name")
        if [ "$state" = exited ]; then
            test "$(docker inspect -f '{{.State.ExitCode}}' "$name")" \
                = "$expected"
            return
        fi
        sleep 1
    done
    echo "FAIL: timeout waiting for $name" >&2
    return 1
}

# Explicit dummy credentials prevent ambient host credentials being used.
cd "$WORK"
git init -q -b main
git config user.name test
git config user.email test@example.test
mkdir prompts
printf 'SWARM_PI_MAIN: complete the tool fixture.\n' > prompts/main.md
printf 'SWARM_PI_POST: complete the post-process fixture.\n' > prompts/post.md
printf 'SWARM_PI_ERROR: reject this request.\n' > prompts/error.md
jq -n --arg network "$NETWORK" --arg api "http://${API}:8080" \
    --arg version "$VERSION" '{
    driver: "pi", pi_version: $version,
    prompt: "prompts/main.md", max_idle: 1,
    docker_args: ["--network", $network],
    agents: [{count: 1, model: "anthropic/claude-sonnet-4-6",
        effort: "none", api_key: "pi-fixture-key", base_url: $api},
        {name: "pi-ui", count: 0, model: "claude-sonnet-4-6",
        api_key: "pi-fixture-key", base_url: $api}],
    post_process: {prompt: "prompts/post.md", model: "claude-sonnet-4-6",
        effort: "off", api_key: "pi-fixture-key", base_url: $api}
}' > swarm.json
git add .
git commit -qm 'Seed Pi E2E fixture'
SEED=$(git rev-parse HEAD)

# Build before starting the API; launch.sh reuses these cached layers.
docker build --quiet -t "$IMAGE" --build-arg SWARM_AGENTS=pi \
    --build-arg "PI_VERSION=$VERSION" "$ROOT" >/dev/null
docker network create "$NETWORK" >/dev/null
docker run -d --name "$API" --network "$NETWORK" \
    -v "$ROOT/tests/fixtures/pi-api-server.js:/test-api.js:ro" \
    --entrypoint node "$IMAGE" /test-api.js >/dev/null
for ((i = 0; i < 30; i++)); do
    if docker exec "$API" curl -fsS http://localhost:8080/health \
            >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$API" curl -fsS http://localhost:8080/health >/dev/null

"$ROOT/launch.sh" start
wait_container "$IMAGE-1" 0
"$ROOT/launch.sh" post-process
wait_container "$IMAGE-post" 0

test "$(< test-results/pi.txt)" = PI_MAIN_DONE
test "$(< test-results/pi-post.txt)" = PI_POST_DONE
test "$(git rev-list --count "$SEED..HEAD")" -eq 2
git log --format=%B "$SEED..HEAD" | grep -q "Tools: swarm .* Pi $VERSION"
test -n "$(git tag -l 'swarm-harvest-*')"
test -z "$(git status --porcelain)"
printf 'PASS: Pi tools, commits, idle exit, post-process, and harvest\n'

for name in "$IMAGE-1" "$IMAGE-post"; do
    docker logs "$name" > "$WORK/activity.log" 2>&1
    for label in 'Read test-results/' 'Write test-results/' \
            'Edit test-results/' 'Shell: git add'; do
        grep -qF "$label" "$WORK/activity.log"
    done
    docker cp "$name:/workspace/agent_logs" "$WORK/logs" >/dev/null
    stats=$(find "$WORK/logs" -name 'stats_agent_*.tsv' -print -quit)
    awk -F '\t' '
        NF != 9 { exit 1 }
        { count++; if ($2 <= 0 || $3 <= 0 || $4 <= 0 || $9 <= 0) exit 1 }
        END { if (count == 0) exit 1 }
    ' "$stats"
    rm -rf "$WORK/logs"
done
"$ROOT/costs.sh" --json > "$WORK/costs.json"
jq -e '.total.cost_usd > 0 and .total.input_tokens > 0' \
    "$WORK/costs.json" >/dev/null
printf 'PASS: activity stream and cost/token/turn accounting\n'

# Pi exits zero for structured JSON errors; the harness must still fail.
docker run -d --name "$IMAGE-error" --network "$NETWORK" \
    -v "$BARE:/upstream:rw" \
    -e SWARM_DRIVER=pi -e SWARM_MODEL=claude-sonnet-4-6 \
    -e SWARM_PROMPT=prompts/error.md -e AGENT_ID=error \
    -e PI_API_KEY=pi-fixture-key -e "PI_BASE_URL=http://${API}:8080" \
    -e MAX_IDLE=1 "$IMAGE" >/dev/null
wait_container "$IMAGE-error" 1
docker logs "$IMAGE-error" > "$WORK/error.log" 2>&1
grep -q 'Pi fixture rejected the credential' "$WORK/error.log"
printf 'PASS: zero-exit Pi API error becomes a failed container\n'

# Docker's interactive launcher requires a host PTY. Python is optional
# and used only for this native-UI check, never for the driver itself.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$ROOT/launch.sh" <<'PY'
import os
import pty
import re
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
proc = subprocess.Popen(
    [sys.argv[1], "interactive", "pi-ui"],
    stdin=slave, stdout=slave, stderr=slave,
    env={**os.environ, "TERM": "xterm-256color"},
)
os.close(slave)
output = b""
sent = False
deadline = time.monotonic() + 90
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", output)
            if not sent and b"pi v" in plain:
                os.write(master, b"/quit\r")
                sent = True
        if proc.poll() is not None:
            break
    if not sent or proc.wait(timeout=5) != 0:
        raise RuntimeError("Pi native UI did not exit cleanly")
except Exception:
    sys.stderr.buffer.write(output)
    raise
finally:
    if proc.poll() is None:
        proc.kill()
    proc.wait()
    os.close(master)
PY
    ui_name=$(docker ps -a --format '{{.Names}}' \
        --filter "name=^/${IMAGE}-interactive-pi-ui-")
    wait_container "$ui_name" 0
    test -n "$(git -C "$BARE" for-each-ref --format='%(refname)' \
        'refs/heads/swarm/*/interactive-pi-ui-*')"
    printf 'PASS: native Pi UI startup, /quit, and interactive branch push\n'
    printf '  4 passed, 0 failed (real Pi, local test API)\n'
else
    echo 'SKIP: native Pi UI check needs Python 3 for a host PTY'
    printf '  3 passed, 0 failed (real Pi, local test API)\n'
fi
