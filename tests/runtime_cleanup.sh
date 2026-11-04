#!/bin/bash
set -uo pipefail

# shellcheck source=_test_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_test_env.sh"

# tests/runtime_cleanup.sh
#
# launch.sh cleanup under real Docker: a bare repo a container wrote
# into as its own user (on Linux another UID than this host user's, so
# only the Docker helper can delete those files), a mirror, and a real
# workspace volume of this checkout.  Cleanup refuses while a container
# of the project remains (before workspace volumes, retire refuses
# every container), then copies all three into the checkout as recovery
# refs and deletes them.
#
# Requires Docker.  No API key needed.

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
if ! git var GIT_CONFIG_SYSTEM >/dev/null 2>&1; then
    echo "SKIP: needs Git 2.42 or later (git var)"
    exit 0
fi

# shellcheck source=../lib/project.sh
source "$REPO_ROOT/lib/project.sh"

BASE_IMAGE="swarm-core-runtime-test"
P="swarm-core-cleanup-test"
# Cleanup's helpers run the engine image, <project>-agent.
ENGINE_IMAGE="${P}-agent"
NAME="${P}-agent-1"
VOL="${NAME}-ws-00000000"
WORKDIR=$(mktemp -d /tmp/swarm-core-cleanup-XXXXXX)

drop_all() {
    local c
    for c in $(docker ps -aq --filter "label=${SWARM_PROJECT_LABEL}=${P}"); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    for c in $(docker ps -aq --filter "label=swarm-core.cleanup=${P}"); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}
cleanup_test() {
    drop_all
    # Files the container wrote may belong to its user: remove them as
    # root with the test image, which needs no pull.
    docker run --rm --user 0 --entrypoint rm \
        -v "$WORKDIR:/workdir" "$BASE_IMAGE" -rf /workdir/runtime \
        >/dev/null 2>&1 || true
    docker rmi "$ENGINE_IMAGE" >/dev/null 2>&1 || true
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

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
