#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_cleanup.sh
#
# swarm cleanup under real Docker: a bare repo a container wrote
# into as its own user (on Linux another UID than this host user's, so
# only the Docker helper can delete those files), a mirror, and a real
# workspace volume of this checkout.  Cleanup refuses while a container
# of the project remains that retire refuses (one without its workspace
# volume, as an earlier release made them), then copies all three into
# the checkout as recovery refs and deletes them.  Then one whole
# engagement through swarm: start, wait, retire, cleanup, and a
# second start on the cleaned runtime directory.
#
# Requires Docker.  No API key needed.

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

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"

BASE_IMAGE="swarm-core-runtime-test"
P="swarm-core-cleanup-test"
# The engagement swarm starts, under a project id of its own.
P2="swarm-core-cycle-test"
# Cleanup's helpers run the engine image, <project>-agent.
ENGINE_IMAGE="${P}-agent"
NAME="${P}-agent-1"
VOL="${NAME}-ws-00000000"
WORKDIR=$(mktemp -d /tmp/swarm-core-cleanup-XXXXXX)

drop_all() {
    local c p
    for p in "$P" "$P2"; do
        for c in $(docker ps -aq \
                --filter "label=${SWARM_PROJECT_LABEL}=${p}"); do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
        for c in $(docker ps -aq --filter "label=swarm-core.cleanup=${p}"); do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
        for c in $(docker volume ls -q \
                --filter "label=${SWARM_PROJECT_LABEL}=${p}"); do
            docker volume rm "$c" >/dev/null 2>&1 || true
        done
    done
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}
cleanup_test() {
    drop_all
    # Files the container wrote may belong to its user: remove them as
    # root with the test image, which needs no pull.
    docker run --rm --user 0 --entrypoint rm \
        -v "$WORKDIR:/workdir" "$BASE_IMAGE" -rf /workdir/runtime \
        /workdir/runtime2 >/dev/null 2>&1 || true
    docker rmi "$ENGINE_IMAGE" "${P2}-agent" >/dev/null 2>&1 || true
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
present() {
    if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi
}
gitc() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
run_cleanup() {
    (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
        "$BASH" "$LAUNCH_SH" cleanup)
}

drop_all
echo "--- Building ${BASE_IMAGE} (fake driver only) ---"
docker build --quiet --tag "$BASE_IMAGE" \
    --build-arg SWARM_AGENTS=fake "$REPO_ROOT" >/dev/null || exit 1
docker tag "$BASE_IMAGE" "$ENGINE_IMAGE" || exit 1

# The checkout, its runtime directory and engagement on this daemon.
CHECKOUT="$WORKDIR/checkout"
git init -q "$CHECKOUT"
echo a > "$CHECKOUT/a"
gitc -C "$CHECKOUT" add a
gitc -C "$CHECKOUT" commit -qm init
CK=$(swarm_checkout_path "$CHECKOUT")
RT="$WORKDIR/runtime"
mkdir -m 700 "$RT"
swarm_runtime_claim "$RT" "$CHECKOUT" "$P" || exit 1
DAEMON=$(swarm_docker_daemon_id) || exit 1
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e1" | .docker_daemon = $d' --arg d "$DAEMON" || exit 1

# The bare repo, shared as start shares it, and a commit a container
# pushes into it as its own user.
git clone -q --bare --no-hardlinks "$CHECKOUT" "$RT/upstream.git"
git -C "$RT/upstream.git" update-ref refs/heads/agent-work \
    "$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$RT/upstream.git" config core.sharedRepository world
chmod -R a+rwX "$RT/upstream.git"
if ! docker run --rm -v "$RT/upstream.git:/upstream:rw" \
        --entrypoint bash "$BASE_IMAGE" -c '
            set -e
            git clone -q /upstream /tmp/w
            cd /tmp/w
            git checkout -q agent-work
            echo by-agent > agent.txt
            git add agent.txt
            git -c user.name=agent -c user.email=a@a commit -qm by-agent
            git push -q origin agent-work
            # A directory only its owner may change: on Linux, when this
            # host user is someone else, only the Docker helper can
            # delete what is in it.
            mkdir -m 755 /upstream/agent-dir
            echo notes > /upstream/agent-dir/notes
        ' > "$WORKDIR/push.out" 2>&1; then
    echo "FAIL: the container could not push"; tail -5 "$WORKDIR/push.out"
    exit 1
fi
AGENT_COMMIT=$(git -C "$RT/upstream.git" rev-parse agent-work)
# Harvest: the checkout has the agent's work.
git -C "$CHECKOUT" fetch -q "$RT/upstream.git" agent-work
gitc -C "$CHECKOUT" merge -q --ff-only FETCH_HEAD
# A mirror.
mkdir -p "$RT/mirrors"
git init -q --bare "$RT/mirrors/sub.git"
gitc -C "$CHECKOUT" push -q "$RT/mirrors/sub.git" HEAD:refs/heads/main
# A workspace volume of this checkout with a committed repository.
docker volume create \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --label "${SWARM_CONTAINER_LABEL}=${NAME}" \
    --label "${SWARM_KIND_LABEL}=agent" \
    --label "${SWARM_CONTEXT_LABEL}=full" \
    --label "${SWARM_ENGAGEMENT_LABEL}=e1" "$VOL" >/dev/null || exit 1
docker run --rm --mount "type=volume,src=${VOL},dst=/workspace" \
    --entrypoint bash "$BASE_IMAGE" -c '
        set -e
        cd /workspace
        git init -q
        echo w > w
        git add w
        git -c user.name=t -c user.email=t@t commit -qm volume-work
    ' >/dev/null 2>&1 || { echo "FAIL: cannot fill the volume"; exit 1; }

echo "--- a stopped container of the project ---"
docker run --name "$NAME" \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --entrypoint true "$BASE_IMAGE" >/dev/null 2>&1
rc=0
out=$(run_cleanup 2>&1) || rc=$?
check "cleanup refuses while it remains" "$rc" "1"
check "because retire refuses it" \
    "$(printf '%s\n' "$out" | grep -c 'every container must be retired' \
        | awk '{ print ($1 > 0) }')" "1"
check "the bare repo stays" "$(present "$RT/upstream.git")" "yes"
check "the volume stays" \
    "$(docker volume inspect "$VOL" >/dev/null 2>&1 && echo yes || echo no)" \
    "yes"
docker rm "$NAME" >/dev/null 2>&1

# Whether this user could delete what the container wrote (on macOS
# Docker maps the container's user to this one; on Linux it may not).
if [ -w "$RT/upstream.git/agent-dir" ]; then
    echo "--- this user may delete the container's files itself ---"
else
    echo "--- only the Docker helper can delete the container's files ---"
fi

echo "--- cleanup ---"
rc=0
out=$(run_cleanup 2>&1) || rc=$?
check "cleanup succeeds" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "the bare repo is gone" "$(present "$RT/upstream.git")" "no"
check "no remnant is left" \
    "$(find "$RT" -name '*.removing' | grep -c . || true)" "0"
check "the mirrors are gone" "$(present "$RT/mirrors")" "no"
check "the volume is gone" \
    "$(docker volume inspect "$VOL" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "the lock and the runtime directory stay" \
    "$(present "$RT/engagement.lock")$(present "$RT")" "yesyes"
check "the state keeps only the claim" \
    "$(jq -c 'keys' "$RT/state.json")" '["project","repo_root","schema"]'
check "the agent's commit is in the recovery refs" \
    "$(git -C "$CHECKOUT" for-each-ref --contains "$AGENT_COMMIT" \
        --format='%(refname)' refs/swarm-recovery/ | grep -c . \
        | awk '{ print ($1 > 0) }')" "1"
check "the volume's work is in the recovery refs" \
    "$(git -C "$CHECKOUT" log --all --format=%s | grep -c '^volume-work$' \
        | awk '{ print ($1 > 0) }')" "1"
check "no helper container is left" \
    "$(docker ps -aq --filter "label=swarm-core.cleanup=${P}" | grep -c . \
        || true)" "0"

echo "--- a linked worktree of a volume's repository in a container's layer ---"
# A second engagement whose container left a linked worktree of its
# workspace repository in /tmp, with a file outside Git's history:
# cleanup's own scans leave the registration to retire, which refuses
# the file until --discard-uncommitted drops it.
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e2" | .docker_daemon = $d' --arg d "$DAEMON" || exit 1
VOLW="${VOL}-wt"
docker volume create \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --label "${SWARM_CONTAINER_LABEL}=${NAME}" \
    --label "${SWARM_KIND_LABEL}=agent" \
    --label "${SWARM_CONTEXT_LABEL}=full" \
    --label "${SWARM_ENGAGEMENT_LABEL}=e2" "$VOLW" >/dev/null || exit 1
docker run --name "$NAME" \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --mount "type=volume,src=${VOLW},dst=/workspace" \
    --entrypoint bash "$BASE_IMAGE" -c '
        set -e
        cd /workspace
        git init -q
        echo w > w
        git add w
        git -c user.name=t -c user.email=t@t commit -qm wt-work
        git worktree add -q --detach /tmp/wt HEAD
        echo notes > /tmp/wt/notes.txt
    ' >/dev/null 2>&1 || { echo "FAIL: cannot make the worktree"; exit 1; }
rc=0
out=$(run_cleanup 2>&1) || rc=$?
check "cleanup stops at the file in the worktree" "$rc" "1"
check "  naming it" \
    "$(printf '%s\n' "$out" | grep -c 'notes.txt' | awk '{ print ($1 > 0) }')" \
    "1"
check "  the volume stays" \
    "$(docker volume inspect "$VOLW" >/dev/null 2>&1 && echo yes || echo no)" \
    "yes"
rc=0
out=$( (cd "$CHECKOUT" && SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    "$BASH" "$LAUNCH_SH" cleanup --discard-uncommitted) 2>&1) || rc=$?
check "--discard-uncommitted lets cleanup end it" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "  the container is gone" \
    "$(docker container inspect "$NAME" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume is gone" \
    "$(docker volume inspect "$VOLW" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume's work is in the recovery refs" \
    "$(git -C "$CHECKOUT" log --all --format=%s | grep -c '^wt-work$' \
        | awk '{ print ($1 > 0) }')" "1"

echo "--- a linked worktree rooted at /tmp, a directory the image has too ---"
# The image cleanup scans from has /tmp but no .git there naming the
# repository back, so cleanup leaves the registration to retire, which
# checks the worktree in the container's layer.
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e3" | .docker_daemon = $d' --arg d "$DAEMON" || exit 1
VOLT="${VOL}-tmp"
docker volume create \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --label "${SWARM_CONTAINER_LABEL}=${NAME}" \
    --label "${SWARM_KIND_LABEL}=agent" \
    --label "${SWARM_CONTEXT_LABEL}=full" \
    --label "${SWARM_ENGAGEMENT_LABEL}=e3" "$VOLT" >/dev/null || exit 1
docker run --name "$NAME" \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --mount "type=volume,src=${VOLT},dst=/workspace" \
    --entrypoint bash "$BASE_IMAGE" -c '
        set -e
        cd /workspace
        git init -q
        echo w > w
        git add w
        git -c user.name=t -c user.email=t@t commit -qm tmp-work
        git worktree add -q --detach /tmp HEAD
    ' >/dev/null 2>&1 || { echo "FAIL: cannot make the worktree"; exit 1; }
rc=0
out=$(run_cleanup 2>&1) || rc=$?
check "cleanup ends it" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "  the container is gone" \
    "$(docker container inspect "$NAME" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume is gone" \
    "$(docker volume inspect "$VOLT" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume's work is in the recovery refs" \
    "$(git -C "$CHECKOUT" log --all --format=%s | grep -c '^tmp-work$' \
        | awk '{ print ($1 > 0) }')" "1"

echo "--- a second-pass failure after retire keeps the engagement's sources ---"
# A clean linked worktree in /tmp: retire, inside cleanup, takes the
# container; then cleanup's second scan of the volume fails (a docker
# wrapper on PATH fails the second cleanup-scan run), and nothing of the
# engagement is deleted.  A cleanup without the wrapper then ends it.
swarm_state_update "$RT/state.json" \
    '.engagement_id = "e4" | .docker_daemon = $d' --arg d "$DAEMON" || exit 1
VOLF="${VOL}-pass2"
docker volume create \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --label "${SWARM_CONTAINER_LABEL}=${NAME}" \
    --label "${SWARM_KIND_LABEL}=agent" \
    --label "${SWARM_CONTEXT_LABEL}=full" \
    --label "${SWARM_ENGAGEMENT_LABEL}=e4" "$VOLF" >/dev/null || exit 1
docker run --name "$NAME" \
    --label "${SWARM_PROJECT_LABEL}=${P}" \
    --label "${SWARM_CHECKOUT_LABEL}=${CK}" \
    --mount "type=volume,src=${VOLF},dst=/workspace" \
    --entrypoint bash "$BASE_IMAGE" -c '
        set -e
        cd /workspace
        git init -q
        echo w > w
        git add w
        git -c user.name=t -c user.email=t@t commit -qm pass2-work
        git worktree add -q --detach /tmp/wt HEAD
    ' >/dev/null 2>&1 || { echo "FAIL: cannot make the worktree"; exit 1; }
mkdir -p "$WORKDIR/shim"
: > "$WORKDIR/shim-count"
cat > "$WORKDIR/shim/docker" <<EOF
#!/bin/bash
case "\$*" in
    *"-cleanup-scan-"*"src=${VOLF},"*)
        n=\$(grep -c . "$WORKDIR/shim-count")
        echo x >> "$WORKDIR/shim-count"
        if [ "\$n" = 1 ]; then
            cat > /dev/null
            exit 3
        fi ;;
esac
exec $(command -v docker) "\$@"
EOF
chmod +x "$WORKDIR/shim/docker"
rc=0
out=$( (cd "$CHECKOUT" && PATH="$WORKDIR/shim:$PATH" \
    SWARM_RUNTIME_DIR="$RT" SWARM_PROJECT="$P" \
    "$BASH" "$LAUNCH_SH" cleanup) 2>&1) || rc=$?
check "cleanup stops at the failed second scan" "$rc" "1"
check "  after retire took the container" \
    "$(docker container inspect "$NAME" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume stays" \
    "$(docker volume inspect "$VOLF" >/dev/null 2>&1 && echo yes || echo no)" \
    "yes"
check "  the engagement is still recorded" \
    "$(jq -r '.engagement_id // empty' "$RT/state.json")" "e4"
rc=0
out=$(run_cleanup 2>&1) || rc=$?
check "a cleanup without the failure ends it" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "  the volume is gone" \
    "$(docker volume inspect "$VOLF" >/dev/null 2>&1 && echo yes || echo no)" \
    "no"
check "  the volume's work is in the recovery refs" \
    "$(git -C "$CHECKOUT" log --all --format=%s | grep -c '^pass2-work$' \
        | awk '{ print ($1 > 0) }')" "1"

echo "--- a whole engagement: start, wait, retire, cleanup, start ---"
# The fake driver makes no commits, so with max_idle 1 each agent exits
# after one session.  docker_args ask for auto-remove, a restart policy
# and another name; what the engine sets comes after and wins.
C2="$WORKDIR/cycle"
RT2="$WORKDIR/runtime2"
git init -q "$C2"
echo "Prompt." > "$C2/prompt.md"
cat > "$C2/swarm.json" <<'EOF'
{ "prompt": "prompt.md", "driver": "fake", "max_idle": 1,
  "docker_args": ["--rm", "--restart", "always", "--name", "other"],
  "agents": [{ "count": 2, "model": "fake" }] }
EOF
gitc -C "$C2" add -A
gitc -C "$C2" commit -qm init
run2() {
    (cd "$C2" && SWARM_RUNTIME_DIR="$RT2" SWARM_PROJECT="$P2" \
        SWARM_SKIP_DEP_CHECK=1 SWARM_WAIT_POLL=2 "$BASH" "$LAUNCH_SH" "$@")
}
vols2() {
    docker volume ls -q --filter "label=${SWARM_PROJECT_LABEL}=${P2}" \
        | grep -c . || true
}
rc=0
out=$(run2 start 2>&1) || rc=$?
check "start succeeds" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
TOKEN1=$(jq -r '.engagement_token // empty' "$RT2/state.json")
check "one volume per agent" "$(vols2)" "2"
for i in 1 2; do
    check "agent $i: its own name, no restart policy, no auto-remove" \
        "$(docker inspect -f \
            '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.AutoRemove}}' \
            "${P2}-agent-${i}" 2>/dev/null)" "/${P2}-agent-${i} no false"
    check "agent $i: /workspace is its volume" \
        "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Type}} {{.Name}}{{end}}{{end}}' \
            "${P2}-agent-${i}" 2>/dev/null | grep -cE "^volume ${P2}-agent-${i}-ws-[0-9a-f]{8}$")" "1"
done
rc=0
out=$(run2 wait 2>&1) || rc=$?
check "wait sees both agents finish and harvests" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
rc=0
run2 start >/dev/null 2>&1 || rc=$?
check "a second start before cleanup is refused" "$rc" "1"
rc=0
out=$(run2 retire 2>&1) || rc=$?
check "retire takes the stopped agents" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "no container of the engagement is left" \
    "$(docker ps -aq --filter "label=${SWARM_PROJECT_LABEL}=${P2}" \
        | grep -c . || true)" "0"
check "their volumes stay" "$(vols2)" "2"
rc=0
out=$(run2 cleanup 2>&1) || rc=$?
check "cleanup succeeds" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "the volumes are gone" "$(vols2)" "0"
check "so is the bare repo" "$(present "$RT2/upstream.git")" "no"
check "the volumes' history is in the recovery refs" \
    "$(git -C "$C2" for-each-ref refs/swarm-recovery/ | grep -c . \
        | awk '{ print ($1 > 0) }')" "1"
rc=0
out=$(run2 start 2>&1) || rc=$?
check "start on the cleaned runtime succeeds" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
check "as a new engagement" \
    "$(jq -r '.engagement_token // empty' "$RT2/state.json" \
        | grep -cvx "${TOKEN1:-none}" || true)" "1"
check "with new volumes" "$(vols2)" "2"
run2 wait >/dev/null 2>&1 || true
run2 retire >/dev/null 2>&1 || true
rc=0
run2 cleanup >/dev/null 2>&1 || rc=$?
check "and cleans up again" "$rc" "0"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
