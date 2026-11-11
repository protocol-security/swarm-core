#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_control.sh
#
# The control interface under real Docker, with the fake driver: one
# engagement driven through control.sh only (start, wait, an
# interactive session, retire, cleanup), and observe after each step:
# the engagement, every container with its role, profile, number, state
# and exit code, the workspace volumes, and the labels on the real
# containers.  On macOS, observe also runs with every write denied, and
# leaves Docker's configuration directory as it was.
#
# Requires Docker and python3 (the interactive session's terminal).  No
# API key needed.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CONTROL="${REPO_ROOT}/bin/control.sh"
IFACE="swarm-core.control/v1"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not found"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not running"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: needs python3"
    exit 0
fi

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"

BASE_IMAGE="swarm-core-runtime-test"
# A project id of this run's own, so that two runs never sweep each
# other's containers.
P="swarm-core-control-$$-$(date +%s)"
ENGINE_IMAGE="${P}-agent"
PROBE_LABEL="swarm-core.runtime-control"
WORKDIR=$(mktemp -d /tmp/swarm-core-control-XXXXXX)
WORKDIR=$(cd -P "$WORKDIR" && pwd -P)
RT="$WORKDIR/runtime"
CHECKOUT="$WORKDIR/checkout"

sweep() {
    local key c i left
    for key in "$SWARM_PROJECT_LABEL" swarm-core.retire swarm-core.cleanup \
            "$PROBE_LABEL"; do
        if ! left=$(docker ps -aq --filter "label=${key}=${P}"); then
            echo "  WARNING: cannot list the containers labelled ${key}=${P}"
            continue
        fi
        for c in $left; do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
    done
    if left=$(docker volume ls -q \
            --filter "label=${SWARM_PROJECT_LABEL}=${P}"); then
        for c in $left; do
            docker volume rm "$c" >/dev/null 2>&1 || true
        done
    fi
    for i in $(docker images --format '{{.Repository}}:{{.Tag}}' \
            "${ENGINE_IMAGE}-retire" 2>/dev/null) "$ENGINE_IMAGE"; do
        docker rmi "$i" >/dev/null 2>&1 || true
    done
}
cleanup_test() {
    sweep
    docker run --rm --label "${PROBE_LABEL}=${P}" --user 0 \
        --entrypoint rm -v "$WORKDIR:/workdir" "$BASE_IMAGE" -rf \
        /workdir/runtime /workdir/checkout >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup_test EXIT

PASS=0
FAIL=0
check() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "    PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "    FAIL: ${label}  expected=${expected} got=${actual}"
        FAIL=$((FAIL + 1))
    fi
}
gitc() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
# control.sh with the interface and ARGS, in the checkout; output to
# $WORKDIR/out and $WORKDIR/err; prints the status.
ctl() {
    local rc=0
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        SWARM_SKIP_DEP_CHECK=1 "$BASH" "$CONTROL" --interface "$IFACE" \
        "$@" > "$WORKDIR/out" 2> "$WORKDIR/err") || rc=$?
    printf '%s' "$rc"
}
# observe, with the document in $WORKDIR/obs.json; prints the status.
observe() {
    local rc
    rc=$(ctl observe)
    cp "$WORKDIR/out" "$WORKDIR/obs.json"
    printf '%s' "$rc"
}
q() { jq -c "$1" "$WORKDIR/obs.json" 2>/dev/null; }
show_err() {
    [ "$1" = 0 ] || tail -8 "$WORKDIR/err" | sed 's/^/      /'
}

# The supervisor of a run that needs a terminal (as in
# runtime_mirrors.sh): the command under a new pseudo-terminal, its
# output in LOG, at most SECS seconds, then the process group killed and
# status 124.
SUPERVISOR="$WORKDIR/supervise.py"
cat > "$SUPERVISOR" <<'EOF'
import os, pty, select, signal, sys, time

secs, logname, cmd = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
deadline = time.time() + secs
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(cmd[0], cmd)
    finally:
        os._exit(127)
log = open(logname, "ab")
terminal = True
status = None
while True:
    done, st = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        status = st
        break
    if time.time() > deadline:
        break
    if terminal:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if data:
                log.write(data)
                log.flush()
            else:
                terminal = False
    else:
        time.sleep(0.2)
if status is None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    os.waitpid(pid, 0)
    log.write(b"\ntimed out\n")
    log.close()
    sys.exit(124)
log.close()
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + os.WTERMSIG(status))
EOF

echo "--- Building ${BASE_IMAGE} (fake driver only) ---"
docker build --quiet --tag "$BASE_IMAGE" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null || exit 1

# Three numbered agents from two profiles (a profile of none between
# them), and post-process.
git init -q -b main "$CHECKOUT"
echo "Prompt." > "$CHECKOUT/prompt.md"
cat > "$CHECKOUT/swarm.json" <<'EOF'
{ "prompt": "prompt.md", "driver": "fake", "max_idle": 1,
  "agents": [{ "name": "a", "count": 2, "model": "fake" },
             { "name": "z", "count": 0, "model": "fake" },
             { "name": "b", "count": 1, "model": "fake" }],
  "post_process": { "prompt": "prompt.md", "model": "fake" } }
EOF
gitc -C "$CHECKOUT" add -A
gitc -C "$CHECKOUT" commit -qm init
CK=$(cd -P "$CHECKOUT" && pwd -P)

echo "--- version, and observe before anything ---"
rc=0
(cd / && "$BASH" "$CONTROL" version > "$WORKDIR/out") || rc=$?
check "version" "$rc|$(jq -r '.interfaces | join(",")' "$WORKDIR/out")" \
    "0|$IFACE"
rc=$(observe)
check "observe: exits 0" "$rc" 0
show_err "$rc"
check "observe: this checkout, no engagement, nothing in Docker" \
    "$(q '[.project, .checkout, .engagement, .containers, .workspaces,
        .conditions]')" "[\"$P\",\"$CK\",null,[],[],[]]"
check "observe: the daemon Docker talks to" "$(q .docker.daemon)" \
    "\"$(docker info -f '{{.ID}}')\""
check "observe: made nothing" "$([ -e "$RT" ] && echo yes || echo no)" no

echo "--- start ---"
rc=$(ctl start)
check "start succeeds" "$rc" 0
show_err "$rc"
rc=$(observe)
check "observe after start" "$rc" 0
TOKEN=$(jq -r .engagement_token "$RT/state.json")
check "the engagement, complete, with the recorded token" \
    "$(q '[.engagement.complete, .engagement.token,
        .engagement.docker_daemon == .docker.daemon]')" \
    "[true,\"$TOKEN\",true]"
check "three agents: role, profile, number" \
    "$(jq -c --arg t "$TOKEN" '[.containers[] | [.name, .role,
        .profile_index, .agent_number, .engagement_token == $t]]' \
        "$WORKDIR/obs.json")" \
    "[[\"${P}-agent-1\",\"agent\",1,1,true],[\"${P}-agent-2\",\"agent\",1,2,true],[\"${P}-agent-3\",\"agent\",3,3,true]]"
check "their full ids" \
    "$(q '[.containers[].id | test("^[0-9a-f]{64}$")] | all')" true
check "a workspace each, kind agent" \
    "$(q '[.workspaces[] | [.container, .kind]]')" \
    "[[\"${P}-agent-1\",\"agent\"],[\"${P}-agent-2\",\"agent\"],[\"${P}-agent-3\",\"agent\"]]"
check "the labels on the real containers" \
    "$(docker inspect -f '{{index .Config.Labels "swarm-core.role"}}|{{index .Config.Labels "swarm-core.profile-index"}}|{{index .Config.Labels "swarm-core.agent-number"}}' "${P}-agent-3")" \
    "agent|3|3"

echo "--- the agents end by themselves ---"
end=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$end" ]; do
    observe >/dev/null
    [ "$(q '[.containers[] | .state == "exited"] | all')" = true ] && break
    sleep 3
done
check "observe: every agent exited 0, with its times" \
    "$(q '[.containers[] | [.state, .exit_code, .error,
        .started_at != null, .finished_at != null]] | unique')" \
    '[["exited",0,null,true,true]]'

# On macOS: observe with every write denied, and Docker's configuration
# directory (a copy of the user's) as it was.
if command -v sandbox-exec >/dev/null 2>&1 \
        && sandbox-exec -p '(version 1)(allow default)' true 2>/dev/null; then
    DCFG="$WORKDIR/docker-config"
    mkdir -p "$DCFG"
    cp -Rp "${DOCKER_CONFIG:-$HOME/.docker}/." "$DCFG/" 2>/dev/null || true
    dsnap() {
        (cd "$DCFG" && find . -print0 | LC_ALL=C sort -z \
            | xargs -0 stat -f '%Sp %z %m %N')
    }
    before=$(dsnap)
    jq -S 'del(.observed_at)' "$WORKDIR/obs.json" > "$WORKDIR/obs.plain"
    prof='(version 1)(allow default)(deny file-write* (require-not
        (require-any (literal "/dev/null") (literal "/dev/tty")
        (subpath "/dev/fd"))))'
    rc=0
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        DOCKER_CONFIG="$DCFG" sandbox-exec -p "$prof" "$BASH" "$CONTROL" \
        --interface "$IFACE" observe > "$WORKDIR/out" 2> "$WORKDIR/err") \
        || rc=$?
    check "observe with every write denied" "$rc|$(cat "$WORKDIR/err")" "0|"
    check "  the same document" \
        "$(jq -S 'del(.observed_at)' "$WORKDIR/out" | cmp -s - \
            "$WORKDIR/obs.plain" && echo same || echo different)" same
    check "  Docker's configuration directory as it was" "$(dsnap)" \
        "$before"
else
    echo "    SKIP: no sandbox-exec here"
fi

echo "--- wait: post-process and harvest ---"
rc=$(ctl wait)
check "wait succeeds" "$rc" 0
show_err "$rc"
rc=$(observe)
check "observe after wait" "$rc" 0
check "post-process: no profile, no number, exited 0" \
    "$(q ".containers[] | select(.name == \"${P}-agent-post\")
        | [.role, .profile_index, .agent_number, .state, .exit_code]")" \
    '["post-process",null,null,"exited",0]'
check "its workspace" \
    "$(q "[.workspaces[] | select(.container == \"${P}-agent-post\")
        | .kind]")" '["agent"]'
check "its labels on the real container, empty where they do not apply" \
    "$(docker inspect -f '{{json .Config.Labels}}' "${P}-agent-post" \
        | jq -c '[.["swarm-core.role"], .["swarm-core.profile-index"],
            .["swarm-core.agent-number"]]')" '["post-process","",""]'

echo "--- an interactive session of profile b ---"
rc=0
(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 python3 "$SUPERVISOR" 600 \
    "$WORKDIR/interactive.log" "$BASH" "$CONTROL" --interface "$IFACE" \
    interactive --agent b) || rc=$?
check "the session runs and ends" "$rc" 0
[ "$rc" = 0 ] || tail -8 "$WORKDIR/interactive.log" | sed 's/^/      /'
rc=$(observe)
check "observe: the session, role interactive, profile 3, no number" \
    "$(q '[.containers[] | select(.name | contains("-interactive-"))
        | [.role, .profile_index, .agent_number, .state]]')" \
    '[["interactive",3,null,"exited"]]'
check "its workspace, kind interactive" \
    "$(q '[.workspaces[] | select(.kind == "interactive")] | length')" 1

echo "--- retire and cleanup ---"
rc=$(ctl retire)
check "retire succeeds" "$rc" 0
show_err "$rc"
rc=$(observe)
check "observe after retire: no container, the workspaces kept" \
    "$rc|$(q '.containers | length')|$(q '.workspaces | length')" "0|0|5"
rc=$(ctl cleanup)
check "cleanup succeeds" "$rc" 0
show_err "$rc"
rc=$(observe)
check "observe after cleanup: nothing left, no condition" \
    "$rc|$(q '[.engagement, .containers, .workspaces, .conditions]')" \
    "0|[null,[],[],[]]"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
