#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_mirrors.sh
#
# Submodule mirrors under real Docker, with the fake driver: a checkout
# whose submodule has a submodule of its own, every URL in a
# .gitmodules one no network answers, and the containers started with
# --network none.  start mirrors both levels, and the agent's container
# checks both out from the read-only /mirrors before its setup hook
# runs (as root, through sudo -E), which reports what it sees.
# post-process and an interactive session, each in a new workspace, do
# the same.  Then stop, harvest.sh, retire and cleanup, which deletes
# the mirrors and keeps their manifest under a recovery ref.
#
# Requires Docker and python3 (the supervisor of the runs that could
# hang, and the interactive session's terminal).  No API key needed.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LAUNCH_SH="${REPO_ROOT}/launch.sh"

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
P="swarm-core-mirrors-$$-$(date +%s)"
ENGINE_IMAGE="${P}-agent"
PROBE_LABEL="swarm-core.runtime-mirrors"
WORKDIR=$(mktemp -d /tmp/swarm-core-mirrors-XXXXXX)
WORKDIR=$(cd -P "$WORKDIR" && pwd -P)
RT="$WORKDIR/runtime"
CHECKOUT="$WORKDIR/checkout"

# Everything of this run's project goes: containers of launch.sh,
# retire's and cleanup's helpers and the probes, then volumes, then the
# engine image and retire's snapshot images.  The shared base image
# stays, as the other runtime tests keep it.
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
    # Files a container wrote may belong to its user: remove them as
    # root with the base image, which needs no pull.
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
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
        -c protocol.file.allow=always "$@"
}
present() {
    if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi
}
run_launch() {
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        SWARM_SKIP_DEP_CHECK=1 "$BASH" "$LAUNCH_SH" "$@")
}

# The supervisor of a launch.sh run that could hang (as in
# runtime_target.sh): the command under a new pseudo-terminal, its
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
bounded_launch() {
    local secs="$1" log="$2" rc=0
    shift 2
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        SWARM_SKIP_DEP_CHECK=1 python3 "$SUPERVISOR" "$secs" "$log" \
        "$BASH" "$LAUNCH_SH" "$@") || rc=$?
    if [ "$rc" -eq 124 ]; then
        sweep >&2
    fi
    printf '%s' "$rc"
}
# Wait for container NAME to exit, until 300 seconds have passed; print
# its exit code, or "running" past that.
exited() {
    local end st
    end=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        st=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null \
            || echo gone)
        case "$st" in
            exited|dead)
                docker inspect -f '{{.State.ExitCode}}' "$1"
                return 0 ;;
            gone) echo gone; return 0 ;;
        esac
        sleep 2
    done
    echo running
}
# The /mirrors mounts of container NAME: "Type|Source|RW" per line.
mirror_mounts() {
    local f='{{range .Mounts}}{{if eq .Destination "/mirrors"}}'
    f="${f}"'{{.Type}}|{{.Source}}|{{.RW}}{{println}}{{end}}{{end}}'
    docker inspect -f "$f" "$1" | grep .
}
workspace_volume() {
    local f='{{range .Mounts}}{{if eq .Destination "/workspace"}}'
    docker inspect -f "${f}{{.Name}}{{end}}{{end}}" "$1"
}
report_of() {
    docker run --rm --label "${PROBE_LABEL}=${P}" \
        --mount "type=volume,src=$1,dst=/workspace" --entrypoint cat \
        "$BASE_IMAGE" /workspace/agent_logs/mirrors-check.txt 2>&1
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

echo "--- Building ${BASE_IMAGE} (fake driver only) ---"
docker build --quiet --tag "$BASE_IMAGE" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null || exit 1
echo "  image: $(docker run --rm --label "${PROBE_LABEL}=${P}" \
    --entrypoint git "$BASE_IMAGE" --version)"

# leaf <- mid <- the checkout, every .gitmodules URL unreachable; the
# host's checkouts come from the local repositories.
URLBASE="https://swarm-core-test.invalid"
S="$WORKDIR/src"
mkdir -p "$S"
git init -q -b main "$S/leaf"
echo leaf > "$S/leaf/leaf.txt"
gitc -C "$S/leaf" add leaf.txt
gitc -C "$S/leaf" commit -qm leaf
git init -q -b main "$S/mid"
echo mid > "$S/mid/mid.txt"
gitc -C "$S/mid" add mid.txt
gitc -C "$S/mid" submodule add -q --name "deep/le af" "$S/leaf" \
    "deep/le af" >/dev/null 2>&1
gitc -C "$S/mid" config -f .gitmodules "submodule.deep/le af.url" \
    "${URLBASE}/leaf.git"
gitc -C "$S/mid" add .gitmodules
gitc -C "$S/mid" commit -qm mid
LEAF_COMMIT=$(git -C "$S/mid" rev-parse "HEAD:deep/le af")

git init -q -b main "$CHECKOUT"
mkdir -p "$CHECKOUT/scripts"
echo "Prompt." > "$CHECKOUT/prompt.md"
cat > "$CHECKOUT/scripts/setup.sh" <<'EOF'
#!/bin/bash
set -u
mkdir -p /workspace/agent_logs
r=/workspace/agent_logs/mirrors-check.txt
{
    if touch /mirrors/probe 2>/dev/null; then
        echo "write=allowed"
    else
        echo "write=refused"
    fi
    echo "mid=$(cat /workspace/lib/mid/mid.txt 2>/dev/null)"
    echo "leaf=$(cat '/workspace/lib/mid/deep/le af/leaf.txt' 2>/dev/null)"
    echo "mid_origin=$(git -C /workspace/lib/mid remote get-url origin)"
    echo "leaf_origin=$(git -C '/workspace/lib/mid/deep/le af' remote \
        get-url origin)"
    echo "leaf_head=$(git -C '/workspace/lib/mid/deep/le af' rev-parse HEAD)"
    if [ -e /workspace/unused/.git ]; then
        echo "unused=initialized"
    else
        echo "unused=not"
    fi
    echo "network=$(git ls-remote https://github.com/git/git HEAD \
        >/dev/null 2>&1 && echo yes || echo no)"
} > "$r" 2>&1
EOF
chmod +x "$CHECKOUT/scripts/setup.sh"
cat > "$CHECKOUT/swarm.json" <<'EOF'
{ "prompt": "prompt.md", "driver": "fake", "max_idle": 1,
  "setup": "scripts/setup.sh",
  "docker_args": ["--network", "none"],
  "agents": [{ "count": 1, "model": "fake" }],
  "post_process": { "prompt": "prompt.md", "model": "fake" } }
EOF
gitc -C "$CHECKOUT" add -A
gitc -C "$CHECKOUT" submodule add -q --name lib/mid "$S/mid" lib/mid \
    >/dev/null 2>&1
gitc -C "$CHECKOUT" submodule add -q --name unused "$S/leaf" unused \
    >/dev/null 2>&1
gitc -C "$CHECKOUT" config -f .gitmodules submodule.lib/mid.url \
    "${URLBASE}/mid.git"
gitc -C "$CHECKOUT" config -f .gitmodules submodule.unused.url \
    "${URLBASE}/unused.git"
gitc -C "$CHECKOUT" add .gitmodules
gitc -C "$CHECKOUT" commit -qm init
# unused is not initialized on the host; lib/mid and its own are.
gitc -C "$CHECKOUT" submodule deinit -q -f -- unused >/dev/null 2>&1
gitc -C "$CHECKOUT/lib/mid" config "submodule.deep/le af.url" "$S/leaf"
gitc -C "$CHECKOUT/lib/mid" submodule update --init -q -- "deep/le af"

# What a container of this engagement must show; LABEL names it.
container_checks() {
    local label="$1" name="$2" rep
    check "$label: one read-only bind mount of mirrors/" \
        "$(mirror_mounts "$name")" "bind|${RT}/mirrors|false"
    rep=$(report_of "$(workspace_volume "$name")")
    check "$label: root could not write into it" "$(field "$rep" write)" \
        refused
    check "$label: lib/mid checked out" "$(field "$rep" mid)" mid
    check "$label: and the submodule inside it" "$(field "$rep" leaf)" leaf
    check "$label: each from its mirror" \
        "$(field "$rep" mid_origin) $(field "$rep" leaf_origin)" \
        "/mirrors/1.git /mirrors/2.git"
    check "$label: at the commit lib/mid records" \
        "$(field "$rep" leaf_head)" "$LEAF_COMMIT"
    check "$label: what is not mirrored stays uninitialized" \
        "$(field "$rep" unused)" not
    check "$label: and the container had no network" \
        "$(field "$rep" network)" no
}

echo "--- start ---"
rc=0
out=$(run_launch start 2>&1) || rc=$?
check "start succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "the manifest lists lib/mid and what is in it" \
    "$(jq -r '[.mirrors[] | "\(.id):\(.parent)"] | join(" ")' \
        "$RT/mirrors/manifest.json")" "1:0 2:1"
check "the agent ends by itself, status 0" "$(exited "${P}-agent-1")" 0
container_checks agent "${P}-agent-1"

echo "--- post-process, joining ---"
rc=$(bounded_launch 600 "$WORKDIR/post.log" post-process)
check "post-process succeeds" "$rc" 0
[ "$rc" = 0 ] || tail -8 "$WORKDIR/post.log" | sed 's/^/      /'
container_checks post-process "${P}-agent-post"

echo "--- an interactive session, joining ---"
rc=$(bounded_launch 600 "$WORKDIR/interactive.log" interactive \
    --agent-index 1)
check "the session runs and ends" "$rc" 0
[ "$rc" = 0 ] || tail -8 "$WORKDIR/interactive.log" | sed 's/^/      /'
session=$(docker ps -a --filter "label=${SWARM_PROJECT_LABEL}=${P}" \
    --format '{{.Names}}' | grep -- '-interactive-' | head -1)
check "(its container is there)" "$([ -n "$session" ] && echo yes)" yes
[ -z "$session" ] || container_checks interactive "$session"

echo "--- stop, harvest.sh, retire, cleanup ---"
run_launch stop >/dev/null 2>&1 || true
(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 "$BASH" "$REPO_ROOT/harvest.sh") \
    >/dev/null 2>&1 || true
rc=0
out=$(run_launch retire 2>&1) || rc=$?
check "retire succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
rc=0
out=$(run_launch cleanup 2>&1) || rc=$?
check "cleanup succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "mirrors/ is gone" "$(present "$RT/mirrors")" no
check "the manifest is kept under a recovery ref" \
    "$(git -C "$CHECKOUT" for-each-ref --format='%(refname)' \
        refs/swarm-recovery/ | grep '/mirrors-manifest$' | head -1 \
        | xargs -I{} git -C "$CHECKOUT" cat-file blob '{}:manifest.json' \
        | jq '.mirrors | length')" 2

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
