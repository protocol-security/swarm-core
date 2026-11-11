#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_target.sh
#
# An engagement's target under real Docker, with the fake driver: start
# resolves it on the host into target.git, every container mounts that
# snapshot read-only at /target-upstream, and a setup hook (run as root
# by the harness, through sudo -E) checks it out with the image's
# swarm-target-checkout.  The source then moves on and goes away:
# post-process and an interactive session, each in a new workspace,
# still check out the recorded commit.  Probe containers run the helper
# as the agent, as root with umask 022 for the agent to read without a
# chown, and as root against a hostile system Git configuration.  Then
# stop, swarm harvest, retire and cleanup, which deletes the snapshot.
#
# Requires Docker, Git 2.42 or later and python3 (the supervisor of the
# runs that could hang, and the interactive session's terminal).  No API
# key needed.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LAUNCH_SH="${REPO_ROOT}/bin/swarm"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not found"
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not running"
    exit 0
fi
if ! git var GIT_CONFIG_SYSTEM >/dev/null 2>&1; then
    echo "SKIP: needs Git 2.42 or later (git var)"
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
P="swarm-core-target-$$-$(date +%s)"
ENGINE_IMAGE="${P}-agent"
PROBE_LABEL="swarm-core.runtime-target"
WORKDIR=$(mktemp -d /tmp/swarm-core-target-XXXXXX)
WORKDIR=$(cd -P "$WORKDIR" && pwd -P)
RT="$WORKDIR/runtime"
CHECKOUT="$WORKDIR/checkout"

# Everything of this run's project goes: containers of swarm,
# retire's and cleanup's helpers and the probes, then volumes, then the
# engine image and retire's snapshot images.  The shared base image
# stays, as the other runtime tests keep it.
# The sweep says what it could not list or remove.
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
        left=$(docker ps -aq --filter "label=${key}=${P}" 2>&1)
        [ -z "$left" ] || echo "  WARNING: containers labelled" \
            "${key}=${P} are left: $(printf '%s' "$left" | tr '\n' ' ')"
    done
    if left=$(docker volume ls -q \
            --filter "label=${SWARM_PROJECT_LABEL}=${P}"); then
        for c in $left; do
            docker volume rm "$c" >/dev/null 2>&1 || true
        done
        left=$(docker volume ls -q \
            --filter "label=${SWARM_PROJECT_LABEL}=${P}" 2>&1)
        [ -z "$left" ] || echo "  WARNING: volumes are left: ${left}"
    else
        echo "  WARNING: cannot list the volumes of ${P}"
    fi
    for i in $(docker images --format '{{.Repository}}:{{.Tag}}' \
            "${ENGINE_IMAGE}-retire" 2>/dev/null) "$ENGINE_IMAGE"; do
        docker rmi "$i" >/dev/null 2>&1 || true
    done
    left=$(docker images -q "$ENGINE_IMAGE" 2>&1; docker images -q \
        "${ENGINE_IMAGE}-retire" 2>&1)
    [ -z "$left" ] || echo "  WARNING: images of ${P} are left: ${left}"
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
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
present() {
    if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi
}
# Run swarm in the checkout (environment assignments first, then
# its arguments, separated by --).
run_launch() {
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        envs+=("$1")
        shift
    done
    shift
    (cd "$CHECKOUT" && env "${envs[@]+"${envs[@]}"}" \
        SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" SWARM_SKIP_DEP_CHECK=1 \
        "$BASH" "$LAUNCH_SH" "$@")
}

# The supervisor of a swarm run that could hang: the command under
# a new pseudo-terminal (its own session, so one process group), its
# output drained into LOG, at most SECS seconds; then SIGTERM to the
# group, 10 seconds, SIGKILL, the child reaped, status 124.  Otherwise
# the child's status (128+N for a signal).
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

def drain(wait):
    # Copy what the terminal holds; False once it is closed (an empty
    # read, or EIO on Linux).
    ready, _, _ = select.select([fd], [], [], wait)
    if not ready:
        return True
    try:
        data = os.read(fd, 65536)
    except OSError:
        return False
    if not data:
        return False
    log.write(data)
    log.flush()
    return True

def reap(seconds):
    # The child's status within SECONDS, or None.  The terminal is read
    # meanwhile: a process that exits with output still unread on its
    # terminal waits for it to be read (macOS).
    global terminal
    end = time.time() + seconds
    while True:
        done, st = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            return st
        left = end - time.time()
        if left <= 0:
            return None
        if terminal:
            terminal = drain(min(0.2, left))
        else:
            time.sleep(min(0.2, left))

def group_alive():
    try:
        os.killpg(pid, 0)
    except OSError:
        return False
    return True

status = reap(secs)
if status is None:
    # The child's process group: the launcher and what stays in its
    # group (containers are the daemon's: the test sweeps them).  TERM,
    # a grace of 10 seconds while any of the group lives, then KILL to
    # the group whatever became of the launcher, which is reaped apart.
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        pass
    end = time.time() + 10
    while time.time() < end:
        if status is None:
            status = reap(0.2)
        elif not group_alive():
            break
        else:
            time.sleep(0.2)
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    if status is None:
        status = reap(10)
    if status is None:
        # Hang the terminal up, so that a child stuck on it can end.
        os.close(fd)
        terminal = False
        os.waitpid(pid, 0)
    log.write(b"\ntimed out\n")
    log.close()
    sys.exit(124)
# What the terminal still holds, for two seconds at most (something the
# launcher started may keep it open), never past the deadline.
end = min(deadline, time.time() + 2)
while terminal and time.time() < end:
    terminal = drain(max(0.0, min(0.2, end - time.time())))
log.close()
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + os.WTERMSIG(status))
EOF
# Run swarm as run_launch does, through the supervisor, bounded to
# SECS seconds, output in LOG; print the status.  A timeout sweeps the
# project's containers at once.
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
# Wait for container NAME to exit, until 300 seconds have passed by the
# clock; print its exit code, or "running" past that.
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
# The /target-upstream mounts of container NAME: "Type|Source|RW" per
# line, from the top-level Mounts.
target_mounts() {
    local f='{{range .Mounts}}{{if eq .Destination "/target-upstream"}}'
    f="${f}"'{{.Type}}|{{.Source}}|{{.RW}}{{println}}{{end}}{{end}}'
    docker inspect -f "$f" "$1" | grep .
}
# The workspace volume of container NAME.
workspace_volume() {
    local f='{{range .Mounts}}{{if eq .Destination "/workspace"}}'
    docker inspect -f "${f}{{.Name}}{{end}}{{end}}" "$1"
}
# The setup hook's report in volume VOL, and the owner uid of the
# checkout as the container sees it.
report_of() {
    docker run --rm --label "${PROBE_LABEL}=${P}" \
        --mount "type=volume,src=$1,dst=/workspace" --entrypoint bash \
        "$BASE_IMAGE" -c 'cat /workspace/agent_logs/target-check.txt
            echo "checkout_owner=$(stat -c %u /workspace/target)"' 2>&1
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

echo "--- Building ${BASE_IMAGE} (fake driver only) ---"
docker build --quiet --tag "$BASE_IMAGE" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null || exit 1
echo "  image: $(docker run --rm --label "${PROBE_LABEL}=${P}" \
    --entrypoint git "$BASE_IMAGE" --version)"
AGENT_UID=$(docker run --rm --label "${PROBE_LABEL}=${P}" \
    --entrypoint id "$BASE_IMAGE" -u)
HOST_UID=$(id -u)
NATIVE=false
if [ "$(uname)" = Linux ] \
        && ! docker info --format '{{json .SecurityOptions}}' \
        | grep -qE 'name=(userns|rootless)'; then
    NATIVE=true
fi

# The target: main (two commits; f under a filter attribute), base at
# the first.
SRC="$WORKDIR/src"
git init -q -b main "$SRC"
echo one > "$SRC/f"
printf 'f filter=evil\n' > "$SRC/.gitattributes"
gitc -C "$SRC" add f .gitattributes
gitc -C "$SRC" commit -qm one
BASEC=$(git -C "$SRC" rev-parse HEAD)
gitc -C "$SRC" branch base
echo two > "$SRC/f"
gitc -C "$SRC" commit -qam two
X=$(git -C "$SRC" rev-parse HEAD)

# The project: the fake driver, one agent that ends after one idle
# session, a post-process, and a setup hook that checks the target out.
# Its report goes to agent_logs, which the workspace scan exempts in the
# workspace's own checkout (the harness makes the directory only after
# setup).
git init -q -b main "$CHECKOUT"
mkdir -p "$CHECKOUT/scripts"
echo "Prompt." > "$CHECKOUT/prompt.md"
cat > "$CHECKOUT/scripts/setup.sh" <<'EOF'
#!/bin/bash
set -u
mkdir -p /workspace/agent_logs
r=/workspace/agent_logs/target-check.txt
if touch /target-upstream/probe 2>/dev/null; then
    echo "write=allowed" > "$r"
else
    echo "write=refused" > "$r"
fi
swarm-target-checkout /workspace/target \
    > /workspace/agent_logs/target-checkout.log 2>&1
echo "checkout=$?" >> "$r"
{
    echo "uid=$(id -u)"
    echo "upstream_owner=$(stat -c %u /target-upstream)"
    echo "upstream_group=$(stat -c %g /target-upstream)"
    echo "config_owner=$(stat -c %u /target-upstream/config)"
    echo "config_group=$(stat -c %g /target-upstream/config)"
    echo "head=$(git -C /workspace/target rev-parse HEAD)"
    echo "base=$(git -C /workspace/target rev-parse refs/swarm/target-base)"
} >> "$r" 2>&1
EOF
cat > "$CHECKOUT/swarm.json" <<'EOF'
{ "prompt": "prompt.md", "driver": "fake", "max_idle": 1,
  "setup": "scripts/setup.sh",
  "agents": [{ "count": 1, "model": "fake" }],
  "post_process": { "prompt": "prompt.md", "model": "fake" } }
EOF
gitc -C "$CHECKOUT" add -A
gitc -C "$CHECKOUT" commit -qm init

# What a container of this engagement must show, from its report in
# volume VOL and its mount (container NAME); LABEL names it.
container_checks() {
    local label="$1" name="$2" rep
    check "$label: one read-only bind mount of target.git" \
        "$(target_mounts "$name")" "bind|${RT}/target.git|false"
    rep=$(report_of "$(workspace_volume "$name")")
    check "$label: root could not write into it" "$(field "$rep" write)" \
        refused
    check "$label: the setup ran as root" "$(field "$rep" uid)" 0
    check "$label: the helper succeeded" "$(field "$rep" checkout)" 0
    check "$label: the checkout at the recorded commit" \
        "$(field "$rep" head)" "$X"
    check "$label: the base pin" "$(field "$rep" base)" "$BASEC"
    check "$label: the checkout belongs to the agent after the chown" \
        "$(field "$rep" checkout_owner)" "$AGENT_UID"
    if $NATIVE && [ "$HOST_UID" != 0 ] && [ "$HOST_UID" != "$AGENT_UID" ]
    then
        check "$label: the snapshot's owner in the container: this user's" \
            "$(field "$rep" upstream_owner) $(field "$rep" config_owner)" \
            "$HOST_UID $HOST_UID"
    else
        echo "    NOTE: $label: snapshot owner" \
             "$(field "$rep" upstream_owner):$(field "$rep" upstream_group)" \
             "(config $(field "$rep" config_owner):$(field "$rep" \
                 config_group)), host uid $HOST_UID," \
             "agent $AGENT_UID: a snapshot of another owner is not shown" \
             "by this run"
    fi
}

echo "--- start with a target ---"
rc=0
out=$(run_launch TARGET_REPO="$SRC" TARGET_REV=main TARGET_REV_BASE=base \
    SWARM_WAIT_POLL=2 -- start 2>&1) || rc=$?
check "start succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "the target recorded" \
    "$(jq -r '.target.commit + " " + .target.base_commit' "$RT/state.json")" \
    "$X $BASEC"
check "the agent ends by itself, status 0" "$(exited "${P}-agent-1")" 0
container_checks agent "${P}-agent-1"

echo "--- the source moves on, then goes away ---"
echo three > "$SRC/f"
gitc -C "$SRC" commit -qam three
Y=$(git -C "$SRC" rev-parse HEAD)
mv "$SRC" "$SRC.gone"
check "(main has moved)" "$([ "$Y" != "$X" ] && echo yes)" yes
rc=$(bounded_launch 600 "$WORKDIR/post.log" post-process)
check "post-process succeeds" "$rc" 0
[ "$rc" = 0 ] || tail -8 "$WORKDIR/post.log" | sed 's/^/      /'
container_checks post-process "${P}-agent-post"

echo "--- an interactive session ---"
rc=$(bounded_launch 600 "$WORKDIR/interactive.log" interactive \
    --agent-index 1)
check "the session runs and ends" "$rc" 0
[ "$rc" = 0 ] || tail -8 "$WORKDIR/interactive.log" | sed 's/^/      /'
session=$(docker ps -a --filter "label=${SWARM_PROJECT_LABEL}=${P}" \
    --format '{{.Names}}' | grep -- '-interactive-' | head -1)
check "(its container is there)" "$([ -n "$session" ] && echo yes)" yes
[ -z "$session" ] || container_checks interactive "$session"

echo "--- the helper in probe containers ---"
PROBES="$WORKDIR/probes"
mkdir -p "$PROBES"
# The five variables swarm gives a container, from the record.
T_REPO=$(jq -r .target.repo "$RT/state.json")
T_BASE_REPO=$(jq -r .target.base_repo "$RT/state.json")
cat > "$PROBES/agent.sh" <<'EOF'
swarm-target-checkout /tmp/co > /dev/null 2>&1; echo "rc1=$?"
echo "head=$(git -C /tmp/co rev-parse HEAD)"
echo "base=$(git -C /tmp/co rev-parse refs/swarm/target-base)"
swarm-target-checkout /tmp/co > /dev/null 2>&1; echo "rc2=$?"
echo "uid=$(id -u)"
EOF
cat > "$PROBES/rootumask.sh" <<'EOF'
umask 022
swarm-target-checkout /opt/target > /dev/null 2>&1; echo "rc=$?"
echo "head=$(sudo -u agent git -C /opt/target rev-parse HEAD 2>&1)"
echo "f=$(sudo -u agent cat /opt/target/f 2>&1)"
EOF
cat > "$PROBES/system.sh" <<'EOF'
mkdir -p /tmp/hooks /tmp/marks
printf '#!/bin/sh\necho hook >> /tmp/marks/hook\n' > /tmp/hooks/post-checkout
chmod +x /tmp/hooks/post-checkout
cat > /etc/gitconfig <<'CFG'
[core]
    hooksPath = /tmp/hooks
[filter "evil"]
    smudge = "sh -c 'echo smudge >> /tmp/marks/smudge; cat'"
CFG
git init -q /tmp/plain
git -C /tmp/plain fetch -q \
    --upload-pack='git -c safe.directory=/target-upstream upload-pack' \
    /target-upstream refs/swarm/target:refs/swarm/target
git -C /tmp/plain checkout -q --detach "$TARGET_REV"
echo "control=$(ls /tmp/marks | tr '\n' ' ')"
rm -f /tmp/marks/*
swarm-target-checkout /tmp/sys > /dev/null 2>&1; echo "helper=$?"
echo "after=$(ls /tmp/marks | tr '\n' ' ')"
echo "head=$(git -C /tmp/sys rev-parse HEAD)"
EOF
cat > "$PROBES/rewrite.sh" <<'EOF'
cat > /etc/gitconfig <<'CFG'
[url "/elsewhere"]
    insteadOf = /target-upstream
CFG
git init -q /tmp/plain
git -C /tmp/plain fetch -q \
    --upload-pack='git -c safe.directory=/target-upstream upload-pack' \
    /target-upstream refs/swarm/target 2>&1 | grep -c /elsewhere \
    | sed 's/^/control=/'
swarm-target-checkout /tmp/rw > /dev/null 2>&1; echo "helper=$?"
echo "head=$(git -C /tmp/rw rev-parse HEAD)"
EOF
# The scripts must be readable by any container user, whatever this
# host user's umask.
chmod 755 "$PROBES"
chmod 644 "$PROBES"/*.sh
probe() {   # SCRIPT [docker run options]
    local s="$1"
    shift
    docker run --rm --label "${PROBE_LABEL}=${P}" "$@" \
        --mount \
        "type=bind,src=${RT}/target.git,dst=/target-upstream,readonly" \
        -e SWARM_TARGET_MIRROR=/target-upstream -e TARGET_REPO="$T_REPO" \
        -e TARGET_REV="$X" -e TARGET_REV_BASE="$BASEC" \
        -e TARGET_REV_BASE_REPO="$T_BASE_REPO" -v "$PROBES:/probes:ro" \
        --entrypoint bash "$BASE_IMAGE" "/probes/$s" 2>&1
}
out=$(probe agent.sh)
check "as the agent: the helper works" "$(field "$out" rc1)" 0
check "  at the recorded commit" "$(field "$out" head)" "$X"
check "  with the base pin" "$(field "$out" base)" "$BASEC"
check "  a second run refuses" "$(field "$out" rc2)" 1
check "  (it ran as the agent)" "$(field "$out" uid)" "$AGENT_UID"
out=$(probe rootumask.sh --user 0)
check "as root with umask 022: the helper works" "$(field "$out" rc)" 0
check "  the agent reads its checkout with no chown" \
    "$(field "$out" head) $(field "$out" f)" "$X two"
out=$(probe system.sh --user 0)
check "a hostile system config: plain git runs its hook and filter" \
    "$(field "$out" control)" "hook smudge "
check "  the helper works" "$(field "$out" helper)" 0
check "  and runs neither" "$(field "$out" after)" ""
check "  at the recorded commit" "$(field "$out" head)" "$X"
out=$(probe rewrite.sh --user 0)
check "a system rewrite: plain git fetches from the rewritten path" \
    "$(field "$out" control)" 1
check "  the helper does not" \
    "$(field "$out" helper) $(field "$out" head)" "0 $X"

echo "--- stop, swarm harvest, retire, cleanup ---"
run_launch -- stop >/dev/null 2>&1 || true
(cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    SWARM_SKIP_DEP_CHECK=1 "$BASH" "$REPO_ROOT/libexec/harvest") \
    >/dev/null 2>&1 || true
rc=0
out=$(run_launch -- retire 2>&1) || rc=$?
check "retire succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
rc=0
out=$(run_launch -- cleanup 2>&1) || rc=$?
check "cleanup succeeds" "$rc" 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "target.git is gone" "$(present "$RT/target.git")" no

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
